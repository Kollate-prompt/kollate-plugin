#!/usr/bin/env bash
# The twin of tests/codex_capture.sh, for the tool this plugin started life in. The two are
# deliberately the same shape: the same fixtures in each tool's own format, the same
# assertions, the same real hook run against a loopback endpoint. Where they disagree, the
# difference is a real difference between the tools, not an accident of how they were tested.
# Needs no database and no network beyond loopback.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import json, os, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, "plugins/kollate/hooks")
import kollate

passed = failed = 0
def check(name, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed += 1
        print(f"  FAIL {name}\n       got:  {got!r}\n       want: {want!r}")

def turn(role, text, uuid):
    return json.dumps({"type": role, "uuid": uuid, "timestamp": "2026-09-08T09:00:00.000Z",
                       "cwd": "/tmp/somewhere",
                       "message": {"role": role, "content": [{"type": "text", "text": text}]}})

SESSION = "8de42568-7030-4061-99d4-540422523c85"
FIXTURE = "\n".join([
    turn("user", "how do I rotate the key?", "u1"),
    json.dumps({"type": "assistant", "uuid": "a1", "timestamp": "2026-09-08T09:00:01.000Z",
                "cwd": "/tmp/somewhere",
                "message": {"role": "assistant", "id": "a1-resp", "model": "claude-opus-5-5",
                            "usage": {"input_tokens": 4, "output_tokens": 6, "cache_read_input_tokens": 50, "cache_creation_input_tokens": 0},
                            "content": [
                    {"type": "thinking", "thinking": "never stored"},
                    {"type": "tool_use", "name": "Bash", "input": {}},
                    {"type": "text", "text": "Run the rotate command."}]}}),
    json.dumps({"type": "ai-title", "aiTitle": "Rotating the key"}),
    json.dumps({"type": "mode", "mode": "default"}),
]) + "\n"

home = tempfile.mkdtemp()
project = os.path.join(home, ".claude", "projects", "-tmp-somewhere")
os.makedirs(project)
transcript = os.path.join(project, f"{SESSION}.jsonl")
with open(transcript, "w") as handle:
    handle.write(FIXTURE)

print("parser")
turns, end, title, chosen = kollate.turns_from(transcript, 0)
check("only the person's turns survive", [t["role"] for t in turns], ["user", "assistant"])
check("the question is stored verbatim", turns[0]["content"], "how do I rotate the key?")
check("the answer is stored without its thinking or tool calls",
      turns[1]["content"], "Run the rotate command.")
check("the tool's own name for the session is used", title, "Rotating the key")
check("but it is not a name a person chose", chosen, False)
check("the record's uuid is its identity", turns[0]["uuid"], "u1")
check("the whole file was consumed", end, len(FIXTURE.encode()))

print("a person's name for a session outranks the tool's")
named = transcript + ".named.jsonl"
with open(named, "w") as handle:
    handle.write(FIXTURE + json.dumps({"type": "custom-title", "customTitle": "Key rotation"}) + "\n")
_t, _e, chosen_title, was_chosen = kollate.turns_from(named, 0)
check("the typed name wins", chosen_title, "Key rotation")
check("and says so, so a later automatic one cannot undo it", was_chosen, True)

print("deltas and marks")
later, later_end, _, _ = kollate.turns_from(transcript, turns[0]["_offset"])
check("a second read returns only what is new", [t["role"] for t in later], ["assistant"])
check("and reaches the same end", later_end, end)
check("Claude Code's marks keep their bare key",
      kollate.watermark_key(SESSION, "claude_code"), SESSION)
check("a Claude Code transcript is not mistaken for a Codex one",
      kollate.source_of(transcript), "claude_code")

print("usage, one record at a time")
def assistant(msg_id, usage, blocks, model="claude-opus-5-5"):
    return {"type": "assistant", "message": {"id": msg_id, "model": model, "role": "assistant",
            "usage": usage, "content": blocks}}
U = {"input_tokens": 2, "cache_creation_input_tokens": 500, "cache_read_input_tokens": 9000,
     "output_tokens": 80, "output_tokens_details": {"thinking_tokens": 10}}
tokens, model, cursor = kollate.usage_of(assistant("m1", U, [{"type": "text", "text": "x"}]), None)
check("claude usage normalised", tokens,
      {"input_tokens": 2, "output_tokens": 80, "cache_read_tokens": 9000,
       "cache_write_tokens": 500, "api_calls": 1})
check("claude model read", model, "claude-opus-5-5")
check("claude cursor is the response id", cursor, "m1")
again = kollate.usage_of(assistant("m1", U, [{"type": "tool_use", "name": "Bash", "input": {}}]), cursor)
check("a second block of the same response is not counted twice", again[0], None)
check("and the cursor stays put", again[2], "m1")
synthetic = kollate.usage_of(assistant("m2", {"input_tokens": 0, "output_tokens": 0},
                                       [{"type": "text", "text": "No response requested."}],
                                       model="<synthetic>"), "m1")
check("Claude Code's synthetic messages carry no usage", synthetic[0], None)
check("and are not a model", synthetic[1], None)
check("a user record carries no usage",
      kollate.usage_of({"type": "user", "message": {"role": "user", "content": "hi"}}, None),
      (None, None, None))
check("merge sums counts", kollate._merge_usage(tokens, tokens)["cache_read_tokens"], 18000)
check("merge sums calls", kollate._merge_usage(tokens, tokens)["api_calls"], 2)
check("merge of nothing is nothing", kollate._merge_usage(None, None), None)

print("usage, across a transcript")
def u(inp, out, read=0, write=0):
    return {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": read,
            "cache_creation_input_tokens": write}
LOOP = [
    {"type": "user", "uuid": "q1", "message": {"role": "user", "content": "fix the test"}},
    # One response, three block records, identical usage on each: counted once.
    assistant("r1", u(10, 5, 100), [{"type": "thinking", "thinking": "..."}]),
    assistant("r1", u(10, 5, 100), [{"type": "text", "text": "Looking."}]),
    assistant("r1", u(10, 5, 100), [{"type": "tool_use", "name": "Read", "input": {}}]),
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}},
    # A tool-only response: never a stored turn, but its usage belongs to "Looking."
    assistant("r2", u(3, 7, 200), [{"type": "tool_use", "name": "Edit", "input": {}}]),
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}},
    assistant("r3", u(1, 9, 300, 40), [{"type": "text", "text": "Fixed."}]),
]
loop_path = os.path.join(tempfile.mkdtemp(), "loop.jsonl")  # outside the scanned tree
with open(loop_path, "w") as handle:
    handle.write("\n".join(json.dumps(r) for r in LOOP) + "\n")
lt, lend, _, _ = kollate.turns_from(loop_path, 0)
check("three stored turns", [t["content"] for t in lt], ["fix the test", "Looking.", "Fixed."])
check("a person's turn has no usage", "usage" in lt[0], False)
check("a turn carries its own response and the tool calls after it", lt[1]["usage"],
      {"input_tokens": 13, "output_tokens": 12, "cache_read_tokens": 300,
       "cache_write_tokens": 0, "api_calls": 2, "model": "claude-opus-5-5"})
check("the last turn carries only its own", lt[2]["usage"]["api_calls"], 1)
check("and its cache writes", lt[2]["usage"]["cache_write_tokens"], 40)
check("absorbed usage moves the turn's end past it", lt[1]["_offset"] > lt[0]["_offset"], True)

# Resume from after "Looking." with its cursor: the tail must not count r1 again.
tail, _, _, _ = kollate.turns_from(loop_path, lt[1]["_offset"], lt[1]["_cursor"])
check("a resumed read counts nothing twice", [t["usage"]["api_calls"] for t in tail], [1])

# A response interrupted before any assistant text: its usage must land on the interrupt
# turn itself, not ride forward past it - otherwise the watermark could pass this turn's
# offset with that usage never sent.
INTERRUPT = [
    {"type": "user", "uuid": "q1", "message": {"role": "user", "content": "run the tests"}},
    assistant("r1", u(4, 2, 50), [{"type": "tool_use", "name": "Bash", "input": {}}]),
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}},
    {"type": "user", "uuid": "i1",
     "message": {"role": "user", "content": "[Request interrupted by user for tool use]"}},
    {"type": "user", "uuid": "q2", "message": {"role": "user", "content": "never mind, try again"}},
    assistant("r2", u(6, 3, 70), [{"type": "text", "text": "Retrying."}]),
]
interrupt_path = os.path.join(tempfile.mkdtemp(), "interrupt.jsonl")
with open(interrupt_path, "w") as handle:
    handle.write("\n".join(json.dumps(r) for r in INTERRUPT) + "\n")
it, _, _, _ = kollate.turns_from(interrupt_path, 0)
check("q1, the interrupt, q2 and the retry are the four stored turns",
      [t["content"] for t in it],
      ["run the tests", "[Request interrupted by user for tool use]", "never mind, try again",
       "Retrying."])
check("the interrupted turn takes the tool call's usage", it[1]["usage"]["api_calls"], 1)
check("the retry carries its own usage", it[3]["usage"]["api_calls"], 1)
r1_end = len(("\n".join(json.dumps(r) for r in INTERRUPT[:2]) + "\n").encode())
check("the interrupted turn's offset moved past the tool call it absorbed",
      it[1]["_offset"] > r1_end, True)

# Resume from the interrupt turn: only the retry's usage should still be out there.
tail2, _, _, _ = kollate.turns_from(interrupt_path, it[1]["_offset"], it[1]["_cursor"])
tail2_calls = sum(t.get("usage", {}).get("api_calls", 0) for t in tail2)
check("a resumed read counts only the retry", tail2_calls, 1)
check("both calls are accounted for across the two reads",
      it[1]["usage"]["api_calls"] + tail2_calls, 2)

# A response whose first content block is NOT its text: the carry from that first block must
# stay pending through the response's own later blocks, not settle onto the previous answer.
SAMEID = [
    {"type": "user", "uuid": "q1", "message": {"role": "user", "content": "first question"}},
    assistant("ra", u(1, 10), [{"type": "text", "text": "A"}]),
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}},
    assistant("rb", u(2, 99), [{"type": "thinking", "thinking": "..."}]),
    assistant("rb", u(2, 99), [{"type": "text", "text": "B"}]),
]
sameid_path = os.path.join(tempfile.mkdtemp(), "sameid.jsonl")
with open(sameid_path, "w") as handle:
    handle.write("\n".join(json.dumps(r) for r in SAMEID) + "\n")
at, _, _, _ = kollate.turns_from(sameid_path, 0)
check("A and B are the two stored answers",
      [t["content"] for t in at if t["role"] == "assistant"], ["A", "B"])
a_turn = next(t for t in at if t["content"] == "A")
b_turn = next(t for t in at if t["content"] == "B")
check("A keeps only its own usage, not rb's leading thinking block",
      a_turn["usage"]["output_tokens"], 10)
check("A's call count", a_turn["usage"]["api_calls"], 1)
check("B gets its own response's usage even though thinking came before its text",
      b_turn["usage"]["output_tokens"], 99)
check("B's call count", b_turn["usage"]["api_calls"], 1)

# Resumed from A: rb's usage must still be out there exactly once, not lost and not doubled.
tail3, _, _, _ = kollate.turns_from(sameid_path, a_turn["_offset"], a_turn["_cursor"])
tail3_calls = sum(t.get("usage", {}).get("api_calls", 0) for t in tail3)
check("a resumed read from A counts rb exactly once", tail3_calls, 1)

# A tool-only response (never becomes a turn) whose first block is also not its only block:
# it must still land on the answer before it, same as the existing tool-only rule.
TOOLONLY = [
    {"type": "user", "uuid": "q1", "message": {"role": "user", "content": "question"}},
    assistant("ta", u(1, 10), [{"type": "text", "text": "Answer"}]),
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}},
    assistant("tb", u(3, 20), [{"type": "thinking", "thinking": "..."}]),
    assistant("tb", u(3, 20), [{"type": "tool_use", "name": "Bash", "input": {}}]),
]
toolonly_path = os.path.join(tempfile.mkdtemp(), "toolonly.jsonl")
with open(toolonly_path, "w") as handle:
    handle.write("\n".join(json.dumps(r) for r in TOOLONLY) + "\n")
ct, _, _, _ = kollate.turns_from(toolonly_path, 0)
check("only the answer is stored - the tool-only response never becomes a turn",
      [t["content"] for t in ct], ["question", "Answer"])
check("the tool-only response's usage still lands on the answer before it",
      ct[1]["usage"],
      {"input_tokens": 4, "output_tokens": 30, "cache_read_tokens": 0,
       "cache_write_tokens": 0, "api_calls": 2, "model": "claude-opus-5-5"})

print("the cursor rides with the batch and the mark")
out = list(kollate.batches(lt, 0))
check("batches yield the cursor", out[-1][2], lt[-1]["_cursor"])
check("underscore keys never leave the machine",
      [k for m in out[-1][0] for k in m if k.startswith("_")], [])
os.environ["CLAUDE_PLUGIN_DATA"] = tempfile.mkdtemp()
kollate.advance_watermark("cursor-check", 10, 1, "r3")
check("the mark keeps the cursor",
      kollate.read_json(kollate.watermark_path(), {})["cursor-check"],
      {"offset": 10, "next_seq": 1, "usage_cursor": "r3"})
del os.environ["CLAUDE_PLUGIN_DATA"]

print("discovery")
CODE = ("import sys; sys.path.insert(0,'plugins/kollate/hooks'); import kollate, json; "
        "print(json.dumps([(s, src) for _p, s, src in kollate.session_files()]))")
found = json.loads(subprocess.run([sys.executable, "-c", CODE], env=dict(os.environ, HOME=home),
                                  capture_output=True, text=True).stdout or "[]")
check("the Claude Code tree is scanned", [f for f in found if f[0] == SESSION],
      [[SESSION, "claude_code"]])

subagents = os.path.join(project, "subagents")
os.makedirs(subagents)
with open(os.path.join(subagents, "11111111-2222-3333-4444-555555555555.jsonl"), "w") as handle:
    handle.write(FIXTURE)
found = json.loads(subprocess.run([sys.executable, "-c", CODE], env=dict(os.environ, HOME=home),
                                  capture_output=True, text=True).stdout or "[]")
check("a subagent's transcript is machinery, not a conversation",
      any(f[0].startswith("11111111") for f in found), False)

print("the hook manifest")
manifest = json.load(open("plugins/kollate/hooks/hooks.json"))["hooks"]
check("capture runs when the turn ends and when the session does",
      sorted(manifest), ["SessionEnd", "SessionStart", "Stop"])
for event in ("Stop", "SessionEnd"):
    check(f"{event} captures", "capture" in manifest[event][0]["hooks"][0]["command"], True)
check("SessionStart reconciles",
      "reconcile" in manifest["SessionStart"][0]["hooks"][0]["command"], True)
check("every command asks for py -3 before python3",
      all(g["hooks"][0]["command"].startswith("py -3 ") for e in manifest.values() for g in e), True)
check("backfill is never hooked - it reaches into history and must be asked for",
      any("backfill" in g["hooks"][0]["command"] for e in manifest.values() for g in e), False)

print("end to end, through the real hook")
received = []
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        received.append((self.path, dict(self.headers), json.loads(body)))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *_a):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

data = os.path.join(home, "plugin-data")
os.makedirs(data)
with open(os.path.join(data, "credentials.json"), "w") as handle:
    json.dump({"capture_token": "t0ken", "hook_secret": "s3cret",
               "api_base": f"http://127.0.0.1:{port}", "endpoint": f"http://127.0.0.1:{port}"},
              handle)
with open(os.path.join(data, "enrolled_at"), "w") as handle:
    handle.write("0")
os.utime(transcript, (time.time(), time.time()))

env = dict(os.environ, HOME=home, CLAUDE_PLUGIN_DATA=data,
           CLAUDE_PLUGIN_ROOT=os.path.join(home, ".claude", "plugins", "cache", "kollate"))
env.pop("CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN", None)
event = json.dumps({"session_id": SESSION, "transcript_path": transcript,
                    "cwd": "/tmp/somewhere", "hook_event_name": "Stop"})
ran = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "capture"],
                     input=event, text=True, env=env, capture_output=True, timeout=30)
if ran.stderr.strip():
    print("    hook stderr:", ran.stderr.strip()[:400])
for _ in range(60):
    if received:
        break
    time.sleep(0.25)
server.shutdown()

check("the hook delivered", bool(received), True)
check("and left a heartbeat, so a silent hook is visible",
      os.path.exists(os.path.join(data, "hook-seen")), True)
if received:
    path, headers, body = received[0]
    lower = {k.lower(): v for k, v in headers.items()}
    check("to the capture function", path, "/functions/v1/capture")
    check("signed", bool(lower.get("x-kollate-signature")), True)
    check("with the timestamp that was signed with it", bool(lower.get("x-kollate-timestamp")), True)
    check("as the connected machine", lower.get("authorization"), "Bearer t0ken")
    check("carrying both turns", [m["role"] for m in body["messages"]], ["user", "assistant"])
    check("numbered from zero", [m["seq"] for m in body["messages"]], [0, 1])
    check("named", body.get("title"), "Rotating the key")
    # The workspace cannot tell the two tools apart on shape alone, so the tool says which
    # it is - and this one must keep saying it even though it is the older surface.
    check("and says which tool it came from", body.get("source"), "claude_code")
    check("with the answer's usage",
          body["messages"][-1].get("usage"),
          {"input_tokens": 4, "output_tokens": 6, "cache_read_tokens": 50,
           "cache_write_tokens": 0, "api_calls": 1, "model": "claude-opus-5-5"})
    check("and no internal keys", [k for m in body["messages"] for k in m if k.startswith("_")], [])
    check("and no thinking left in it",
          any("never stored" in m["content"] for m in body["messages"]), False)
    mark_file = os.path.join(data, "delivered.json")
    for _ in range(40):
        if os.path.exists(mark_file):
            break
        time.sleep(0.25)
    marks = json.load(open(mark_file)) if os.path.exists(mark_file) else {}
    check("the mark keeps the bare key every installed machine already uses",
          list(marks), [SESSION])

print("what a person is told, in this tool")
fresh = tempfile.mkdtemp()
env_status = dict(env, HOME=fresh, CLAUDE_PLUGIN_DATA=os.path.join(fresh, "d"))
out = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "status"],
                     env=env_status, capture_output=True, text=True).stdout
check("the commands named are the ones this tool has", "/kollate:connect" in out, True)
check("and not the other tool's", "kollate:connect" in out.replace("/kollate:connect", ""), False)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
