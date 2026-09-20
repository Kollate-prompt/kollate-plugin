#!/usr/bin/env python3
"""The profile gate through the real hook launcher: a Stop event on stdin, a real transcript,
a real HTTP endpoint. The company profile delivers; a personal profile on the same machine
delivers nothing and its watermark still moves (dropped, not held). Runs on every OS.
    python3 tests/profile_gate_e2e.py
"""
import http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HOOKS = os.path.join(ROOT, "plugins", "kollate", "hooks")
LAUNCHER = os.path.join(HOOKS, "kollate-hook.cmd")
COMPANY, PERSONAL, ACCOUNT = "org-company", "org-personal", "acct-1"
results = []


def check(name, expected, got):
    ok = expected == got
    results.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {name:60} {got!r}" + ("" if ok else f"  (expected {expected!r})"))


received = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        received.append(json.loads(body))
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"

home = tempfile.mkdtemp()
data = os.path.join(home, "plugin-data")
os.makedirs(data)


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as h:
        json.dump(value, h)


def login(org):
    write(os.path.join(home, ".claude.json"), {"oauthAccount": {"organizationUuid": org, "accountUuid": ACCOUNT,
                                                                "emailAddress": "p@x", "organizationName": org}})


def transcript(session):
    path = os.path.join(home, f"{session}.jsonl")
    with open(path, "w", encoding="utf-8") as h:
        for role, text in (("user", "hello from " + session), ("assistant", "hi")):
            h.write(json.dumps({"type": role, "uuid": f"{session}-{role}", "sessionId": session,
                                "cwd": home, "timestamp": "2026-09-20T10:00:00Z",
                                "message": {"role": role, "content": [{"type": "text", "text": text}]}}) + "\n")
    return path


def fire(session):
    env = dict(os.environ, HOME=home, USERPROFILE=home, CLAUDE_PLUGIN_DATA=data,
               APPDATA=os.path.join(home, "AppData", "Roaming"), LOCALAPPDATA=os.path.join(home, "AppData", "Local"))
    env.pop("CLAUDE_CONFIG_DIR", None); env.pop("CLAUDE_PLUGIN_ROOT", None); env.pop("CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN", None)
    event = json.dumps({"session_id": session, "transcript_path": transcript(session), "cwd": home, "hook_event_name": "Stop"})
    cmd = ["cmd", "/c", LAUNCHER, "capture"] if os.name == "nt" else ["/bin/sh", LAUNCHER, "capture"]
    ran = subprocess.run(cmd, input=event, text=True, env=env, capture_output=True, timeout=60, cwd=ROOT)
    if ran.stderr.strip():
        print("    hook stderr:", ran.stderr.strip()[:300])
    before = len(received)
    for _ in range(40):  # the worker is detached; give it a moment either way
        if len(received) > before:
            break
        time.sleep(0.25)
    time.sleep(1.0)
    marks = json.load(open(os.path.join(data, "delivered.json"))) if os.path.exists(os.path.join(data, "delivered.json")) else {}
    return len(received) - before, marks.get(session) or {}


# connected under the company profile, the way connect writes it
write(os.path.join(data, "credentials.json"),
      {"capture_token": "t0ken", "hook_secret": "s3cret", "api_base": BASE, "endpoint": BASE,
       "claude_profile": {"org": COMPANY, "account": ACCOUNT, "email": "p@x", "name": COMPANY}})
with open(os.path.join(data, "enrolled_at"), "w") as h:
    h.write("0")

print(f"profile gate, end to end via {os.path.basename(LAUNCHER)} on {sys.platform}")
login(COMPANY)
delivered, mark = fire("sess-company")
check("company profile: the hook delivered", 1, delivered)
check("and the watermark records what was sent", True, int(mark.get("next_seq", 0)) > 0)

login(PERSONAL)
delivered, mark = fire("sess-personal")
check("personal profile: nothing delivered", 0, delivered)
check("but the watermark moved past it (dropped, not held)", True, int(mark.get("offset", 0)) > 0)
check("and nothing was numbered for sending", 0, int(mark.get("next_seq", 0)))

# switching back captures again - and the dropped turns never follow
login(COMPANY)
delivered, _ = fire("sess-company-2")
check("back on the company profile: delivered again", 1, delivered)
check("the personal session was never sent", False, any("sess-personal" in json.dumps(r) for r in received))

# desktop app: its store names the profile, whatever .claude.json says
appdata = os.path.join(home, "Library", "Application Support", "Claude") if sys.platform == "darwin" else \
    os.path.join(home, "AppData", "Roaming", "Claude") if os.name == "nt" else os.path.join(home, ".config", "Claude")
write(os.path.join(appdata, "claude-code-sessions", ACCOUNT, PERSONAL, "local_x.json"), {"cliSessionId": "sess-desk-personal"})
delivered, mark = fire("sess-desk-personal")
check("desktop session under the personal org: nothing delivered", 0, delivered)
check("even though .claude.json says company", COMPANY, json.load(open(os.path.join(home, ".claude.json")))["oauthAccount"]["organizationUuid"])

server.shutdown()
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
