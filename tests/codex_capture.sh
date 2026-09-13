#!/usr/bin/env bash
# Codex writes a different record shape into a different tree. Everything downstream - offsets,
# batching, watermarks, delivery - is shared, so this guards the seam: does a Codex transcript
# become the same turns a Claude Code one would, and does a real hook run deliver them?
# Needs no database and no network beyond loopback, which is the point.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import glob, json, os, subprocess, sys, tempfile, threading, time
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
check("a Codex transcript is recognised by what is in it, not where it sits",
      kollate.source_of(transcript), "codex")
moved = os.path.join(tempfile.mkdtemp(), "somewhere-else.jsonl")
open(moved, "w").write(FIXTURE)
check("so it is still a Codex session after somebody moves it",
      kollate.source_of(moved), "codex")
check("and a file that says nothing is treated as Claude Code's, as it always was",
      kollate.source_of("/tmp/does-not-exist.jsonl"), "claude_code")

print("discovery")
CODE = ("import sys; sys.path.insert(0,'plugins/kollate/hooks'); import kollate, json; "
        "print(json.dumps([(s, src) for _p, s, src in kollate.session_files()]))")
found = json.loads(subprocess.run([sys.executable, "-c", CODE], env=dict(os.environ, HOME=home),
                                  capture_output=True, text=True).stdout or "[]")
check("the Codex tree is scanned",
      found, [["01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee", "codex"]])

print("the hook command strings are frozen")
# Codex pins its hook trust to a hash of each hook definition. Changing one revokes the trust
# every installed machine has already granted - silently: no prompt, no error, no `hook:` line
# at all, and capture stops with it (measured 2026-09-07, re-confirmed 2026-09-11). If this
# test fails, the change is not a refactor, it is a release note and a re-approval for every
# user, done with /hooks.
#
# One command per event, the same bytes on every operating system. Codex has no per-OS field
# (command_windows and a per-OS manifest object were both ignored, 2026-09-11), runs hooks
# through a shell on POSIX and not on Windows, and re-syncs the marketplace from git whenever
# it changes - so a per-OS file chosen by an installer was reverted by the next push (13.09).
# The command names kollate-hook.cmd: a batch file to Windows, a shell script to the rest.
# Unquoted on purpose: Codex runs the hook without a shell on Windows, and a quoted .cmd path
# is exec'd as a program literally named with the quotes and reported Failed (bench, 13.09).
H = '${CLAUDE_PLUGIN_ROOT}/hooks/kollate-hook.cmd'
CROSS = {
    "Stop": "capture", "SessionEnd": "capture", "SessionStart": "reconcile",
}
manifest = json.load(open("plugins/kollate/hooks/hooks-codex.json"))["hooks"]
check("the manifest names exactly these events", sorted(manifest), sorted(CROSS))
for event, verb in CROSS.items():
    got = [h["command"] for h in manifest[event][0]["hooks"]]
    check(f"{event} runs the one file", got, [f"{H} {verb}"])
check("no entry needs a shell",
      [c for e in manifest.values() for g in e for h in g["hooks"] for c in [h["command"]]
       if any(op in c for op in ("||", "&&", "|", ";", ">", "<", "&"))], [])
check("SessionStart only fires for a real session start",
      manifest["SessionStart"][0].get("matcher"), "startup|resume|clear")
check("every hook declares the timeout Codex would clamp it to anyway",
      sorted({h["timeout"] for e in manifest.values() for g in e for h in g["hooks"]}), [3])
check("the per-OS files are gone, so nothing can point at them",
      [n for n in os.listdir("plugins/kollate/hooks") if n.startswith("hooks-codex-")], [])

print("kollate-hook.cmd is one file for both systems")
# sh: line 1 is the shebang, line 2 starts with ':' (a no-op) and execs Python, so line 3 is
# never reached. cmd: line 1 fails harmlessly ('#!' is not a command), line 2 is a label
# (leading ':'), line 3 runs. Verified by Codex itself on the Windows bench, 13.09.
_cmd = "plugins/kollate/hooks/kollate-hook.cmd"
_lines = open(_cmd, newline="").read().split("\n")
check("executable bit, kept by git and by Codex's copies", os.access(_cmd, os.X_OK), True)
check("shebang first", _lines[0], "#!/bin/sh")
check("the shell line is a cmd label", _lines[1].startswith(": ;"), True)
check("the shell line hands over to Python and never returns", "exec python" in _lines[1], True)
check("the cmd line is silent and finds the script beside itself",
      _lines[2].startswith("@py -3") and "%~dp0kollate.py" in _lines[2] and "%*" in _lines[2], True)
check("LF endings only - CRLF would put a \\r in the sh line", any("\r" in l for l in _lines), False)
if os.name != "nt":
    with tempfile.TemporaryDirectory() as _d:
        _p = os.path.join(_d, "hooks"); os.makedirs(_p)
        import shutil as _sh
        _sh.copy(_cmd, _p); _sh.copymode(_cmd, os.path.join(_p, "kollate-hook.cmd"))
        open(os.path.join(_p, "kollate.py"), "w").write("import sys; print('ARGS', sys.argv[1:])")
        _r = subprocess.run([os.path.join(_p, "kollate-hook.cmd"), "capture"],
                            capture_output=True, text=True, input="{}")
        check("run directly, no shell in front, it reaches Python with the verb",
              (_r.returncode, _r.stdout.strip()), (0, "ARGS ['capture']"))

print("status tells the truth about hooks and about versions")
# Both from Eyal's 12.09 session: status told him to approve hooks he had already approved,
# and reported "Newest version released: 0.4.27" while he was running 0.4.48.
STATUS_CODE = """
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("k", %r)
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
print(json.dumps({
    "trusted": k.codex_hooks_trusted(),
    "stale_is_hidden": k._version_tuple("0.4.27") < k._version_tuple("0.4.48"),
}))
""" % os.path.abspath("plugins/kollate/hooks/kollate.py")

def trust_seen(config_body):
    home = tempfile.mkdtemp()
    codex = os.path.join(home, ".codex"); os.makedirs(codex)
    with open(os.path.join(codex, "config.toml"), "w") as h:
        h.write(config_body)
    env = dict(os.environ, HOME=home, CODEX_HOME=codex)
    out = subprocess.run([sys.executable, "-c", STATUS_CODE], env=env,
                         capture_output=True, text=True).stdout
    return json.loads(out or "{}")

check("an approved hook is recognised as approved",
      trust_seen('[hooks.state."kollate@kollate:hooks/hooks-codex.json:stop:0:0"]\n'
                 'trusted_hash = "sha256:abc"\n').get("trusted"), True)
check("and somebody else's approval is not mistaken for ours",
      trust_seen('[hooks.state."other@other:hooks/x.json:stop:0:0"]\n'
                 'trusted_hash = "sha256:abc"\n').get("trusted"), False)
check("a cached version older than the installed one is treated as stale",
      trust_seen("").get("stale_is_hidden"), True)
check("status asks the repository itself rather than trusting the cache",
      "refresh_update_cache()" in open("plugins/kollate/hooks/kollate.py").read(), True)
# The python.org build of Python on macOS has no CA bundle wired into OpenSSL, so urllib
# raises CERTIFICATE_VERIFY_FAILED against GitHub while curl succeeds. The update check was
# the only network call in the file still using urllib, and it had been silently dead.
_src = open("plugins/kollate/hooks/kollate.py").read()
check("the update check goes over curl, like every other network call here",
      "urllib" in _src.split("def fetch_latest_version")[1].split("def ")[1], False)
check("and there is no urllib left anywhere in the update path",
      [l.strip() for l in _src.splitlines()
       if "urllib.request" in l and "webbrowser" not in l], [])

print("each installer prunes the version directories Codex would otherwise index")
for _installer in ("install.sh", "install.ps1"):
    check(f"{_installer} prunes stale plugin caches",
          "cache" in open(_installer).read() and "kollate" in open(_installer).read(), True)

print("Codex skills do not lean on a variable Codex never sets")
# 13.09: every skill ran py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" - Codex leaves that
# empty, so the command was "/hooks/kollate.py" and the model went hunting for the file.
for _f in sorted(glob.glob("plugins/kollate/codex-skills/*/SKILL.md")):
    _t = open(_f).read()
    check(f"{_f.split('/')[-2]}: no ${{CLAUDE_PLUGIN_ROOT}} command",
          'py -3 "${CLAUDE_PLUGIN_ROOT}' in _t or 'python3 "${CLAUDE_PLUGIN_ROOT}' in _t, False)
    check(f"{_f.split('/')[-2]}: says where the script really is", "two folders up" in _t, True)

print("update on Codex prunes the way the installers do")
with tempfile.TemporaryDirectory(prefix="kollate-") as _home:
    _cache = os.path.join(_home, "plugins", "cache", "kollate", "kollate")
    for _ver in ("0.4.9", "0.4.10"):
        os.makedirs(os.path.join(_cache, _ver, ".codex-plugin"))
    os.environ["CODEX_HOME"] = _home
    try:
        _pruned = kollate.tidy_codex_install()
    finally:
        del os.environ["CODEX_HOME"]
    check("removes the older version (numeric sort, 0.4.10 > 0.4.9)", sorted(os.listdir(_cache)), ["0.4.10"])
    check("and says how many", _pruned, 1)

print("the two manifests agree")
codex = json.load(open("plugins/kollate/.codex-plugin/plugin.json"))
claude = json.load(open("plugins/kollate/.claude-plugin/plugin.json"))
check("same plugin", codex["name"], claude["name"])
check("same version - the update nudge reads one of them", codex["version"], claude["version"])

print("one plugin directory, two tools, no duplicated surface")
# Codex supplements its own discovery with whatever the manifest names, and it treats a
# directory called `commands/` as skills - which minted a second, identical copy of all eight
# under `source-command-*`, eating the skills budget for nothing. Claude Code's `commands`
# field REPLACES its default scan, so pointing it at a differently-named directory is what
# lets the two tools share one plugin folder without either seeing the other's surface.
check("Claude Code is pointed at a directory Codex will not claim",
      claude.get("commands"), "./claude-commands/")
check("and Codex at one Claude Code will not scan", codex.get("skills"), "./codex-skills/")
# Both tools scan a plugin for `commands/` and `skills/` on their own, and both surface what
# they find alongside whatever the manifest names - so a directory with either of those names
# is served twice. Measured 2026-09-09: with the verbs in `skills/`, Claude Code reported
# sixteen skills, each of the eight listed once from its own scan and once from the manifest.
for claimed in ("commands", "skills"):
    check(f"no {claimed}/ is left for either tool to find on its own",
          os.path.isdir(f"plugins/kollate/{claimed}"), False)
verbs = sorted(n[:-3] for n in os.listdir("plugins/kollate/claude-commands"))
check("both tools offer the same eight",
      sorted(os.listdir("plugins/kollate/codex-skills")), verbs)

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
# The hook wrote that heartbeat where CLAUDE_PLUGIN_DATA pointed. The person running status
# from a plain shell has no such variable - status has to go and find it, like the watermarks.
_status_env = dict(os.environ, HOME=home, CLAUDE_CONFIG_DIR=os.path.join(home, ".claude"))
_status_env.pop("CLAUDE_PLUGIN_DATA", None)
_seen_dir = os.path.join(home, ".claude", "plugins", "data", "kollate-kollate")
os.makedirs(_seen_dir)
os.rename(os.path.join(data, "hook-seen"), os.path.join(_seen_dir, "hook-seen"))
_status = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "status"],
                         env=_status_env, capture_output=True, text=True, timeout=30).stdout
check("and status finds it even from a shell without CLAUDE_PLUGIN_DATA",
      "Hooks last ran: " in _status, True)
check("rather than claiming the hooks never ran", "NEVER RUN" in _status, False)
if received:
    path, headers, body = received[0]
    check("to the capture function", path, "/functions/v1/capture")
    check("signed", bool(headers.get("x-kollate-signature")), True)
    lower = {k.lower(): v for k, v in headers.items()}
    check("as the connected machine", lower.get("authorization"), "Bearer t0ken")
    check("carrying both turns", [m["role"] for m in body["messages"]], ["user", "assistant"])
    check("numbered from zero", [m["seq"] for m in body["messages"]], [0, 1])
    check("named", body.get("title"), "how do I rotate the key?")
    # The workspace cannot tell the two tools apart on shape alone - same fields, same
    # delivery - so the tool has to say which it is.
    check("and says which tool it came from", body.get("source"), "codex")
    check("and nothing Codex wrote itself",
          any("environment_context" in m["content"] for m in body["messages"]), False)
    # The mark is written by the detached child after the POST it just made, so it can land a
    # moment after the delivery this test is already holding.
    mark_file = os.path.join(data, "delivered.json")
    for _ in range(40):
        if os.path.exists(mark_file):
            break
        time.sleep(0.25)
    marks = json.load(open(mark_file)) if os.path.exists(mark_file) else {}
    check("the mark is namespaced by source",
          list(marks), ["codex:01a07aac-f5b3-74c1-9fe5-c1c43e31d2ee"])

print("what a person is told, in this tool")
fresh = tempfile.mkdtemp()
out = subprocess.run(
    [sys.executable, "plugins/kollate/hooks/kollate.py", "status"],
    env=dict(os.environ, HOME=fresh, CLAUDE_PLUGIN_DATA=os.path.join(fresh, "d"),
             CLAUDE_PLUGIN_ROOT=os.path.join(fresh, ".codex", "plugins", "cache", "kollate")),
    capture_output=True, text=True).stdout
check("the commands named are the ones this tool has", "kollate:connect" in out, True)
check("and not the other tool's slash form", "/kollate:connect" in out, False)
check("an unapproved install says so instead of looking healthy",
      "Codex will not run a hook until you approve it" in out, True)

print("the helpers a message needs are still there when it is written")
# A local named after a module-level helper makes every f-string that calls the helper raise at
# the moment it is used - which, for a hook, is the moment a person would have been told
# something. Codex reported "hook: Stop Failed" on Windows for exactly this.
import ast as _ast
_tree = _ast.parse(open("plugins/kollate/hooks/kollate.py").read())
_helpers = {n.name for n in _tree.body if isinstance(n, _ast.FunctionDef)}
_shadowed = []
for _fn in [n for n in _tree.body if isinstance(n, _ast.FunctionDef)]:
    _assigned = {t.id for n in _ast.walk(_fn) if isinstance(n, _ast.Assign)
                 for t in n.targets if isinstance(t, _ast.Name)}
    _shadowed += [f"{_fn.name}/{name}" for name in sorted(_assigned & _helpers)]
check("no function shadows a helper it also calls", _shadowed, [])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
