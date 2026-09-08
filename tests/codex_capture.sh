#!/usr/bin/env bash
# Codex writes a different record shape into a different tree. Everything downstream - offsets,
# batching, watermarks, delivery - is shared, so this guards the seam: does a Codex transcript
# become the same turns a Claude Code one would, and does a real hook run deliver them?
# Needs no database and no network beyond loopback, which is the point.
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

def record(role, text, ordinal, kind="input_text"):
    return json.dumps({"timestamp": "2026-09-07T09:00:00.000Z", "ordinal": ordinal,
                       "type": "response_item",
                       "payload": {"type": "message", "role": role,
                                   "content": [{"type": kind, "text": text}]}})

FIXTURE = "\n".join([
    json.dumps({"timestamp": "2026-09-07T09:00:00.000Z", "type": "session_meta",
                "payload": {"id": "01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee",
                            "cwd": "/tmp/somewhere", "cli_version": "0.152.0"}}),
    record("user", "<environment_context>\n  <cwd>/tmp/somewhere</cwd>\n</environment_context>", 1),
    record("developer", "<skills_instructions>\nnot a person\n</skills_instructions>", 2),
    record("user", "how do I rotate the key?", 3),
    record("assistant", "Run the rotate command.", 4, "output_text"),
    json.dumps({"timestamp": "x", "type": "response_item",
                "payload": {"type": "reasoning", "summary": []}}),
]) + "\n"

home = tempfile.mkdtemp()
day = os.path.join(home, ".codex", "sessions", "2026", "09", "07")
os.makedirs(day)
transcript = os.path.join(
    day, "rollout-2026-09-07T09-00-00-01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee.jsonl")
with open(transcript, "w") as handle:
    handle.write(FIXTURE)

print("parser")
turns, end, title, chosen = kollate.turns_from(transcript, 0)
check("only the person's turns survive", [t["role"] for t in turns], ["user", "assistant"])
check("the question is stored verbatim", turns[0]["content"], "how do I rotate the key?")
check("the answer is stored verbatim", turns[1]["content"], "Run the rotate command.")
check("Codex's own context is not a turn",
      any("environment_context" in t["content"] for t in turns), False)
check("the developer role is not a turn",
      any("skills_instructions" in t["content"] for t in turns), False)
check("the title is the first real question", title, "how do I rotate the key?")
check("no name was chosen by a person", chosen, False)
check("the ordinal becomes the record's identity", turns[0]["uuid"], "3")
check("the whole file was consumed", end, len(FIXTURE.encode()))

print("scaffolding detection")
check("a wrapped block is scaffolding",
      kollate._codex_scaffolding([{"type": "input_text", "text": "<user_instructions>\nx\n</user_instructions>"}]), True)
check("prose mentioning a tag is not",
      kollate._codex_scaffolding([{"type": "input_text", "text": "why does <div> break here?"}]), False)
check("an empty message is not", kollate._codex_scaffolding([]), False)

print("deltas and marks")
half = turns[0]["_offset"]
later, later_end, _, _ = kollate.turns_from(transcript, half)
check("a second read returns only what is new", [t["role"] for t in later], ["assistant"])
check("and reaches the same end", later_end, end)
check("Claude Code's marks keep their bare key",
      kollate.watermark_key("abc", "claude_code"), "abc")
check("Codex's marks are namespaced", kollate.watermark_key("abc", "codex"), "codex:abc")
kollate.CODEX_SESSIONS_ROOT = os.path.join(home, ".codex", "sessions")
check("a file in the Codex tree is a Codex session",
      kollate.source_of(transcript), "codex")
check("anything else is still Claude Code's",
      kollate.source_of("/tmp/whatever.jsonl"), "claude_code")

print("discovery")
CODE = ("import sys; sys.path.insert(0,'plugins/kollate/hooks'); import kollate, json; "
        "print(json.dumps([(s, src) for _p, s, src in kollate.session_files()]))")
found = json.loads(subprocess.run([sys.executable, "-c", CODE], env=dict(os.environ, HOME=home),
                                  capture_output=True, text=True).stdout or "[]")
check("the Codex tree is scanned",
      found, [["01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee", "codex"]])

print("the hook command string is frozen")
# Codex pins its hook trust to a hash of this string. Changing it revokes the trust every
# installed machine has already granted - silently: no prompt, no error, the hook simply
# stops running and capture stops with it (measured 2026-09-07). If this test fails, the
# change is not a refactor, it is a release note and a re-approval for every user.
FROZEN = {
    "stop": 'py -3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture || python3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture || python -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture',
    "session_end": 'py -3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture || python3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture || python -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" capture',
    "session_start": 'py -3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" reconcile || python3 -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" reconcile || python -S -E "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" reconcile',
}
manifest = json.load(open("plugins/kollate/hooks/hooks-codex.json"))["hooks"]
for event, want in (("Stop", "stop"), ("SessionEnd", "session_end"), ("SessionStart", "session_start")):
    got = manifest[event][0]["hooks"][0]["command"]
    check(f"{event} still runs exactly what Codex trusted", got, FROZEN[want])
check("SessionStart only fires for a real session start",
      manifest["SessionStart"][0].get("matcher"), "startup|resume|clear")
check("every hook declares the timeout Codex would clamp it to anyway",
      sorted({g[0]["timeout"] for e in manifest.values() for g in [e[0]["hooks"]]}), [3])

print("the two manifests agree")
codex = json.load(open("plugins/kollate/.codex-plugin/plugin.json"))
claude = json.load(open("plugins/kollate/.claude-plugin/plugin.json"))
check("same plugin", codex["name"], claude["name"])
check("same version - the update nudge reads one of them", codex["version"], claude["version"])

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
    handle.write("0")  # everything on disk counts as after enrolment
os.utime(transcript, (time.time(), time.time()))

env = dict(os.environ, HOME=home, CLAUDE_PLUGIN_DATA=data)
env.pop("CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN", None)
event = json.dumps({"session_id": "01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee",
                    "transcript_path": transcript, "cwd": "/tmp/somewhere",
                    "hook_event_name": "SessionEnd", "reason": "other"})
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
    check("to the capture function", path, "/functions/v1/capture")
    check("signed", bool(headers.get("x-kollate-signature")), True)
    lower = {k.lower(): v for k, v in headers.items()}
    check("as the connected machine", lower.get("authorization"), "Bearer t0ken")
    check("carrying both turns", [m["role"] for m in body["messages"]], ["user", "assistant"])
    check("numbered from zero", [m["seq"] for m in body["messages"]], [0, 1])
    check("named", body.get("title"), "how do I rotate the key?")
    check("and nothing Codex wrote itself",
          any("environment_context" in m["content"] for m in body["messages"]), False)
    marks = json.load(open(os.path.join(data, "delivered.json")))
    check("the mark is namespaced by source",
          list(marks), ["codex:01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee"])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
