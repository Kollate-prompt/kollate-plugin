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
                "message": {"role": "assistant", "content": [
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
