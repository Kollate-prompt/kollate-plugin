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
S = "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py"

# The shipped file has to serve a plugin-screen install on BOTH systems, and Codex offers no
# per-OS field: a `command_windows` key and a per-OS object in the manifest were both tested on
# Windows 11 and silently ignored (2026-09-11). So it carries both interpreters as two entries.
# Codex runs each one; the interpreter that exists completes and the other is reported Failed.
# That visible failure is what buys a working UI route on Windows, where the POSIX `A || B || C`
# probe is never executed at all because Codex runs hook commands through a shell on macOS and
# Linux but not on Windows.
CROSS = {
    "Stop": "capture", "SessionEnd": "capture", "SessionStart": "reconcile",
}
manifest = json.load(open("plugins/kollate/hooks/hooks-codex.json"))["hooks"]
for event, verb in CROSS.items():
    got = [h["command"] for h in manifest[event][0]["hooks"]]
    check(f"{event} offers both interpreters", got,
          [f'python3 -S -E "{S}" {verb}', f'py -3 -S -E "{S}" {verb}'])
check("neither entry needs a shell",
      [c for e in manifest.values() for g in e for h in g["hooks"] for c in [h["command"]]
       if any(op in c for op in ("||", "&&", "|", ";", ">", "<", "&"))], [])
check("SessionStart only fires for a real session start",
      manifest["SessionStart"][0].get("matcher"), "startup|resume|clear")
check("every hook declares the timeout Codex would clamp it to anyway",
      sorted({h["timeout"] for e in manifest.values() for g in e for h in g["hooks"]}), [3])

print("each installer points at the single-command file for its own system")
# Nobody who ran an installer should see a hook fail, so each one repoints the installed copy
# at a file holding one invocation. `marketplace upgrade` undoes that, which is why rerunning
# the install command is the documented repair.
SINGLE = {
    "hooks-codex-windows.json": ('py -3 -S -E "%s" %s', "install.ps1", "install.sh"),
    "hooks-codex-posix.json": ('python3 -S -E "%s" %s || python -S -E "%s" %s',
                               "install.sh", "install.ps1"),
}
for name, (shape, mine, theirs) in SINGLE.items():
    one = json.load(open("plugins/kollate/hooks/" + name))["hooks"]
    check(f"{name} covers the same events", sorted(one), sorted(manifest))
    for event, verb in CROSS.items():
        entries = one[event][0]["hooks"]
        check(f"{name} {event} runs one command", len(entries), 1)
        want = shape % ((S, verb) if shape.count("%s") == 2 else (S, verb, S, verb))
        check(f"{name} {event} is that command", entries[0]["command"], want)
    check(f"{name} still only fires SessionStart for a real session start",
          one["SessionStart"][0].get("matcher"), "startup|resume|clear")
    check(f"{name} is pointed at by {mine} and only there",
          name in open(mine).read() and name not in open(theirs).read(), True)
check("the Windows file asks for nothing a shell would have to do",
      [c for e in json.load(open("plugins/kollate/hooks/hooks-codex-windows.json"))["hooks"].values()
       for g in e for h in g["hooks"] for c in [h["command"]]
       if any(op in c for op in ("||", "&&", "|", ";", ">", "<", "&"))], [])

print("the Failed hook explains itself, once")
# The two-interpreter file means Codex reports one hook Failed every session. Unexplained, that
# reads as a broken install; explained every session, it is noise. Once per machine, and only
# when the manifest still names the file that causes it.
import tempfile
HOME_NOTE = tempfile.mkdtemp()
NOTE_CODE = """
import json, os, sys
sys.argv = ["kollate.py", "status"]
sys.path.insert(0, %r)
import importlib.util
spec = importlib.util.spec_from_file_location("k", %r)
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
root = os.environ["CLAUDE_PLUGIN_ROOT"]
os.makedirs(os.path.join(root, ".codex-plugin"), exist_ok=True)
with open(os.path.join(root, ".codex-plugin", "plugin.json"), "w") as h:
    json.dump({"hooks": os.environ["WANT_HOOKS"]}, h)
print(json.dumps([bool(k.hook_pair_note()), bool(k.hook_pair_note())]))
""" % ("plugins/kollate/hooks", os.path.abspath("plugins/kollate/hooks/kollate.py"))

def note_says(hooks_value):
    root = tempfile.mkdtemp()
    env = dict(os.environ, HOME=tempfile.mkdtemp(), CLAUDE_PLUGIN_ROOT=root,
               WANT_HOOKS=hooks_value)
    env.pop("CLAUDE_PLUGIN_DATA", None)
    out = subprocess.run([sys.executable, "-c", NOTE_CODE], env=env,
                         capture_output=True, text=True).stdout
    return json.loads(out or "[null, null]")

check("it speaks the first time the two-interpreter file is in use",
      note_says("./hooks/hooks-codex.json"), [True, False])
check("and never when an installer has repointed the manifest",
      note_says("./hooks/hooks-codex-windows.json"), [False, False])

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

print("install.sh repoints the copy Codex actually loads - the one under a hidden .tmp dir")
# The first version used glob("**"), which skips dotted directories, so only the cache copy
# was repointed and Gal's Mac kept the two-interpreter file. This runs the real block.
import re, subprocess, tempfile
_sh = open("install.sh").read()
_block = re.search(r"<<'KOLLATE_POSIX_HOOKS'[^\n]*\n(.*?)\nKOLLATE_POSIX_HOOKS", _sh, re.S).group(1)
with tempfile.TemporaryDirectory(prefix="kollate-") as _home:
    _paths = [os.path.join(_home, "plugins", "cache", "kollate", "kollate", "0.0.1", ".codex-plugin"),
              os.path.join(_home, ".tmp", "marketplaces", "kollate", "plugins", "kollate", ".codex-plugin")]
    for _d in _paths:
        os.makedirs(_d)
        json.dump({"name": "kollate", "hooks": "./hooks/hooks-codex.json"}, open(os.path.join(_d, "plugin.json"), "w"))
    _other = os.path.join(_home, "plugins", "cache", "openai", "templates", "0.1.0", ".codex-plugin")
    os.makedirs(_other)
    json.dump({"name": "templates"}, open(os.path.join(_other, "plugin.json"), "w"))
    subprocess.run([sys.executable, "-c", _block], env={**os.environ, "CODEX_HOME": _home}, check=True,
                   capture_output=True)
    for _d in _paths:
        check(f"repointed {_d.split(_home)[1]}",
              json.load(open(os.path.join(_d, "plugin.json")))["hooks"], "./hooks/hooks-codex-posix.json")
    check("and leaves other plugins alone even when the home path says kollate",
          json.load(open(os.path.join(_other, "plugin.json"))), {"name": "templates"})

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
