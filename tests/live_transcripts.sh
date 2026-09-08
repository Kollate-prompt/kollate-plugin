#!/usr/bin/env bash
# The fixture suites prove the logic. This proves the logic meets reality: it runs the real
# hook over transcripts THIS machine actually wrote - one from each tool - and shows what
# would have been delivered. Nothing leaves the machine: the endpoint is a loopback server
# this script starts, and the credentials are throwaway.
#
# Skips, rather than fails, whichever tool has no transcripts here. A machine that has never
# run Codex is not a broken machine.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import glob, json, os, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, "plugins/kollate/hooks")
import kollate

received = []
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        received.append(json.loads(body))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *_a):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

home = tempfile.mkdtemp()          # no pause file, no consent file: this machine's own state
data = os.path.join(home, "data")  # must not decide whether the test passes
os.makedirs(data)
with open(os.path.join(data, "credentials.json"), "w") as handle:
    json.dump({"capture_token": "live-test", "hook_secret": "live-test",
               "api_base": f"http://127.0.0.1:{port}", "endpoint": f"http://127.0.0.1:{port}"},
              handle)
with open(os.path.join(data, "enrolled_at"), "w") as handle:
    handle.write("0")

def newest(pattern, want_source):
    best = None
    for path in glob.glob(os.path.expanduser(pattern), recursive=True):
        if os.path.isfile(path) and os.path.getsize(path) > 0:
            turns, _e, _t, _c = kollate.turns_from(path, 0)
            if any(t["role"] == "assistant" for t in turns):
                stamp = os.path.getmtime(path)
                if best is None or stamp > best[0]:
                    best = (stamp, path)
    return best

passed = failed = skipped = 0
for label, pattern, source in (
        ("Claude Code", "~/.claude/projects/**/*.jsonl", "claude_code"),
        ("Codex", "~/.codex/sessions/**/*.jsonl", "codex")):
    print(f"\n{label}")
    found = newest(pattern, source)
    if not found:
        print(f"  -- no {label} transcript with a reply on this machine; skipped")
        skipped += 1
        continue
    _stamp, path = found
    session_id = (os.path.basename(path)[:-6][-36:] if source == "codex"
                  else os.path.basename(path)[:-6])
    print(f"  transcript: {path}")
    print(f"  session:    {session_id}")
    print(f"  source:     {kollate.source_of(path)}")
    assert kollate.source_of(path) == source, "source detection disagrees with the tree"

    before = len(received)
    event = json.dumps({"session_id": session_id, "transcript_path": path,
                        "cwd": os.getcwd(), "hook_event_name": "Stop"})
    ran = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "capture"],
                         input=event, text=True, capture_output=True, timeout=60,
                         env=dict(os.environ, HOME=home, CLAUDE_PLUGIN_DATA=data))
    if ran.stderr.strip():
        print("  hook stderr:", ran.stderr.strip()[:300])
    for _ in range(120):
        if len(received) > before:
            break
        time.sleep(0.25)

    delivered = received[before:]
    if not delivered:
        print("  FAIL nothing was delivered")
        failed += 1
        continue
    turns = [m for batch in delivered for m in batch["messages"]]
    roles = [m["role"] for m in turns]
    print(f"  delivered:  {len(delivered)} batch(es), {len(turns)} turn(s)")
    print(f"  title:      {delivered[0].get('title')!r}")
    for m in turns[:4]:
        print(f"    [{m['seq']}] {m['role']}: {m['content'][:72]!r}")
    if len(turns) > 4:
        print(f"    ... {len(turns) - 4} more")

    problems = []
    if "user" not in roles or "assistant" not in roles:
        problems.append("both sides of the conversation should be present")
    if any(m["seq"] != i for i, m in enumerate(turns)):
        problems.append("sequence numbers should run 0..n without a gap")
    if any(not m["content"].strip() for m in turns):
        problems.append("an empty turn was delivered")
    if source == "codex" and any(m["content"].strip().startswith("<environment_context>")
                                 for m in turns):
        problems.append("Codex's own context was delivered as a person's turn")
    # The mark is written by the detached child after the POST this test is already holding.
    key = kollate.watermark_key(session_id, source)
    marks = {}
    for _ in range(40):
        try:
            marks = json.load(open(os.path.join(data, "delivered.json")))
        except (OSError, ValueError):
            marks = {}
        if key in marks:
            break
        time.sleep(0.25)
    if key not in marks:
        problems.append("the watermark was not written under this source's key")

    if problems:
        for problem in problems:
            print("  FAIL " + problem)
        failed += 1
    else:
        print("  ok   both sides present, sequence unbroken, watermark keyed by source")
        passed += 1

    again = len(received)
    subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "capture"],
                   input=event, text=True, capture_output=True, timeout=60,
                   env=dict(os.environ, HOME=home, CLAUDE_PLUGIN_DATA=data))
    time.sleep(2)
    if len(received) == again:
        print("  ok   firing the same hook again sends nothing")
        passed += 1
    else:
        print("  FAIL the same conversation was sent twice")
        failed += 1

server.shutdown()
print(f"\n{passed} passed, {failed} failed, {skipped} skipped")
sys.exit(1 if failed else 0)
PY
