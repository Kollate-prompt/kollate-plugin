"""What has to be true on Windows, checked on Windows.

Every Windows failure this plugin has had was invisible from a Mac: a stdin read that only
works on sockets, a console codepage that cannot encode the mark we print, an interpreter
that exits 0 while doing nothing, a `claude` binary nobody can find. So this runs on the
machine itself and reports what it finds rather than what it expects.

    py -3 tests\\windows_acceptance.py

It needs no database and no network beyond loopback. It does not install anything.
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(HERE, "plugins", "kollate", "hooks", "kollate.py")
sys.path.insert(0, os.path.dirname(HOOK))
import kollate  # noqa: E402

passed = failed = 0


def check(name, ok, detail="", on_failure=""):
    """`detail` is shown either way; `on_failure` only when it went wrong."""
    global passed, failed
    if ok:
        passed += 1
        print(f"  ok  {name}" + (f" - {detail}" if detail else ""))
    else:
        failed += 1
        note = " - ".join(part for part in (detail, on_failure) if part)
        print(f"  FAIL {name}" + (f" - {note}" if note else ""))


def report(name, value):
    print(f"  ..  {name}: {value}")


def which(*command):
    try:
        done = subprocess.run(list(command), capture_output=True, text=True, timeout=20)
        return (done.stdout or done.stderr or "").strip().splitlines()[:1]
    except Exception as problem:
        return [f"<{type(problem).__name__}>"]


print("the machine")
report("platform", f"{sys.platform} {os.environ.get('PROCESSOR_ARCHITECTURE', '?')}")
report("python", sys.version.split()[0] + " at " + sys.executable)
report("USERPROFILE", os.environ.get("USERPROFILE", "<unset>"))
report("home expands to", os.path.expanduser("~"))
report("CODEX_HOME", os.environ.get("CODEX_HOME", "<unset>"))
report("stdout encoding", getattr(sys.stdout, "encoding", "?"))
for label, command in (("py -3", ("py", "-3", "-c", "import sys;print(sys.executable)")),
                       ("python3", ("python3", "-c", "import sys;print(sys.executable)")),
                       ("python", ("python", "-c", "import sys;print(sys.executable)")),
                       ("codex", ("codex", "--version")),
                       ("claude", ("claude", "--version")),
                       ("git", ("git", "--version")),
                       ("curl", ("curl", "--version"))):
    report(label, which(*command))

print("\nthe home directory is not somewhere surprising")
home = os.path.expanduser("~")
check("the home directory exists", os.path.isdir(home), home)
onedrive = "onedrive" in home.lower() or bool(os.environ.get("OneDrive"))
check("the home directory is not inside OneDrive", "onedrive" not in home.lower(),
      "OneDrive is present on this machine but home is outside it" if onedrive else "")
if onedrive:
    print("  ..  OneDrive is configured here; a redirected Documents folder is the known hazard")

print("\ncurl is present, because every delivery goes through it")
check("curl resolves", which("curl", "--version")[0].startswith("curl"), which("curl", "--version")[0])

print("\nthe console can print what the plugin prints")
# 0.4.31 fixed a crash here: the mark we print is not encodable in cp1252/cp1255, and every
# hook died on it. The plugin reconfigures its own streams; this proves that still works.
fresh = tempfile.mkdtemp()
env = dict(os.environ, HOME=fresh, USERPROFILE=fresh,
           CLAUDE_PLUGIN_DATA=os.path.join(fresh, "d"),
           CLAUDE_PLUGIN_ROOT=os.path.join(fresh, ".codex", "plugins", "cache", "kollate"))
done = subprocess.run([sys.executable, HOOK, "status"], env=env, capture_output=True, text=True)
check("status runs without an encoding crash", done.returncode == 0 and "Traceback" not in done.stderr,
      (done.stderr.strip().splitlines() or [""])[-1][:120])
check("and prints the mark it is supposed to print", "Kollate plugin" in done.stdout,
      repr(done.stdout.splitlines()[0][:60]) if done.stdout else "no output")
check("and names Codex's commands when it is running under Codex",
      "kollate:connect" in done.stdout and "/kollate:connect" not in done.stdout)
check("and says the hooks have never run, rather than looking healthy",
      "NEVER RUN" in done.stdout)

print("\nthe hook reads its event on a platform where select() cannot")
# The bug that made every Windows hook a silent no-op for a week: select() on Windows only
# accepts sockets, so reading the event raised and the hook returned having done nothing.
received = []


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        received.append((dict(self.headers), json.loads(body)))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_a):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

work = tempfile.mkdtemp()
data = os.path.join(work, "data")
os.makedirs(data)
with open(os.path.join(data, "credentials.json"), "w") as handle:
    json.dump({"capture_token": "win-test", "hook_secret": "win-test",
               "api_base": f"http://127.0.0.1:{port}", "endpoint": f"http://127.0.0.1:{port}"},
              handle)
with open(os.path.join(data, "enrolled_at"), "w") as handle:
    handle.write("0")


def record(role, text, ordinal, kind):
    return json.dumps({"timestamp": "2026-09-09T09:00:00.000Z", "ordinal": ordinal,
                       "type": "response_item",
                       "payload": {"type": "message", "role": role,
                                   "content": [{"type": kind, "text": text}]}})


SESSION = "01a08295-28d5-7282-8ffc-a1170c59cd7f"
day = os.path.join(work, ".codex", "sessions", "2026", "09", "09")
os.makedirs(day)
transcript = os.path.join(day, f"rollout-2026-09-09T09-00-00-{SESSION}.jsonl")
with open(transcript, "w", encoding="utf-8") as handle:
    handle.write("\n".join([
        json.dumps({"timestamp": "2026-09-09T09:00:00.000Z", "type": "session_meta",
                    "payload": {"id": SESSION, "cwd": os.getcwd(), "cli_version": "0.152.0"}}),
        record("user", "<environment_context>\n  <cwd>x</cwd>\n</environment_context>", 1, "input_text"),
        record("user", "does this work on Windows?", 2, "input_text"),
        record("assistant", "It does, and here is the proof.", 3, "output_text"),
    ]) + "\n")

check("a Codex transcript is recognised on this platform too",
      kollate.source_of(transcript), "codex")

event = json.dumps({"session_id": SESSION, "transcript_path": transcript,
                    "cwd": os.getcwd(), "hook_event_name": "Stop"})
hook_env = dict(os.environ, HOME=work, USERPROFILE=work, CLAUDE_PLUGIN_DATA=data)
start = time.time()
done = subprocess.run([sys.executable, HOOK, "capture"], input=event, text=True,
                      env=hook_env, capture_output=True, timeout=60)
returned = (time.time() - start) * 1000
check("the hook returns without an error", done.returncode == 0,
      (done.stderr.strip().splitlines() or [""])[-1][:160])
check("and returns fast enough to sit on a keystroke", returned < 1500, f"{returned:.0f} ms")

for _ in range(120):
    if received:
        break
    time.sleep(0.25)
check("the detached worker delivered", bool(received),
      on_failure="nothing arrived - this is the shape of the bug that made every Windows "
                 "hook a silent no-op")

if received:
    headers, body = received[0]
    lower = {k.lower(): v for k, v in headers.items()}
    check("as the connected machine", lower.get("authorization"), "Bearer win-test")
    check("signed", bool(lower.get("x-kollate-signature")), True)
    check("carrying the conversation and not Codex's own context",
          [m["role"] for m in body["messages"]], ["user", "assistant"])
    check("named from the first real question", body.get("title"), "does this work on Windows?")
    mark_file = os.path.join(data, "delivered.json")
    for _ in range(40):
        if os.path.exists(mark_file):
            break
        time.sleep(0.25)
    marks = json.load(open(mark_file)) if os.path.exists(mark_file) else {}
    check("and the mark was written under this source's key, with a lock this platform has",
          list(marks), [f"codex:{SESSION}"])

    before = len(received)
    subprocess.run([sys.executable, HOOK, "capture"], input=event, text=True,
                   env=hook_env, capture_output=True, timeout=60)
    time.sleep(3)
    check("firing the same hook again sends nothing", len(received) == before,
          on_failure=f"{len(received) - before} extra deliver(y|ies)")

server.shutdown()

print("\nwhat Codex itself says, if it is installed here")
version = which("codex", "--version")[0]
if not version.startswith("codex"):
    print("  --  Codex is not on PATH; the plugin-registration half was not checked")
else:
    report("codex", version)
    report("plugin list", which("codex", "plugin", "list"))
    config = os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "config.toml")
    if os.path.isfile(config):
        with open(config, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        trusted = [line for line in text.splitlines() if "hooks.state" in line and "kollate" in line]
        report("hook trust entries for Kollate", trusted or "none - the hooks will not run")
    else:
        report("config.toml", f"not found at {config}")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
