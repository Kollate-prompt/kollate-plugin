#!/usr/bin/env bash
# A hook is on somebody's keystroke path, and Codex clamps SessionEnd to three seconds and
# kills whatever has not finished. Two things therefore have to be true, in both tools: the
# hook returns in milliseconds, and the work it left behind survives being cut off.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import glob, json, os, statistics, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, "plugins/kollate/hooks")
import kollate

MEDIAN_MS, WORST_MS, ROUNDS = 50, 150, 12
SERVER_HOLDS_SECONDS = 4          # longer than the 3 s Codex allows a hook

passed = failed = skipped = 0
def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  ok  {name}" + (f" - {detail}" if detail else ""))
    else:
        failed += 1
        print(f"  FAIL {name}" + (f" - {detail}" if detail else ""))

def newest(pattern):
    files = [p for p in glob.glob(os.path.expanduser(pattern), recursive=True)
             if os.path.isfile(p) and os.path.getsize(p) > 0]
    return max(files, key=os.path.getmtime) if files else None

for label, pattern in (("Claude Code", "~/.claude/projects/**/*.jsonl"),
                       ("Codex", "~/.codex/sessions/**/*.jsonl")):
    print(f"\n{label}")
    transcript = newest(pattern)
    if not transcript:
        print(f"  -- no {label} transcript on this machine; skipped")
        skipped += 1
        continue

    arrived = []
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("content-length", 0)))
            arrived.append(time.time())
            time.sleep(SERVER_HOLDS_SECONDS)
            self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
        def log_message(self, *_a):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    home = tempfile.mkdtemp()
    data = os.path.join(home, "d")
    os.makedirs(data)
    with open(os.path.join(data, "credentials.json"), "w") as handle:
        json.dump({"capture_token": "budget", "hook_secret": "budget",
                   "api_base": f"http://127.0.0.1:{server.server_address[1]}",
                   "endpoint": f"http://127.0.0.1:{server.server_address[1]}"}, handle)
    with open(os.path.join(data, "enrolled_at"), "w") as handle:
        handle.write("0")

    source = kollate.source_of(transcript)
    session_id = (os.path.basename(transcript)[:-6][-36:] if source == "codex"
                  else os.path.basename(transcript)[:-6])
    event = json.dumps({"session_id": session_id, "transcript_path": transcript,
                        "cwd": os.getcwd(), "hook_event_name": "Stop"})
    env = dict(os.environ, HOME=home, CLAUDE_PLUGIN_DATA=data)

    times, codes = [], set()
    for _ in range(ROUNDS):
        start = time.time()
        ran = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "capture"],
                             input=event, text=True, env=env, capture_output=True, timeout=30)
        times.append((time.time() - start) * 1000)
        codes.add(ran.returncode)
    median, worst = statistics.median(times), max(times)
    check("the hook is off the keystroke path", median < MEDIAN_MS,
          f"median {median:.0f} ms (budget {MEDIAN_MS})")
    check("even on its worst round", worst < WORST_MS, f"worst {worst:.0f} ms (budget {WORST_MS})")
    check("and never reports a failure to the tool it is embedded in", codes == {0},
          f"exit codes {sorted(codes)}")

    mark_file = os.path.join(data, "delivered.json")
    for path in (mark_file, mark_file + ".lock"):
        try:
            os.remove(path)
        except OSError:
            pass
    arrived.clear()
    start = time.time()
    subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "capture"],
                   input=event, text=True, env=env, capture_output=True, timeout=30)
    returned = time.time() - start
    landed = None
    deadline = time.time() + SERVER_HOLDS_SECONDS + 20
    while time.time() < deadline:
        if os.path.exists(mark_file):
            landed = time.time() - start
            break
        time.sleep(0.1)
    check("the work outlives the hook", landed is not None and landed > 3.0,
          f"hook returned at {returned*1000:.0f} ms, the server held the request for "
          f"{SERVER_HOLDS_SECONDS} s, and the detached child still finished at "
          f"{landed:.1f} s" if landed else "the detached child never finished")
    server.shutdown()

print(f"\n{passed} passed, {failed} failed, {skipped} skipped")
sys.exit(1 if failed else 0)
PY
