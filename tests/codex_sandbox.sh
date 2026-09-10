#!/usr/bin/env bash
# Codex runs a skill's shell command inside a sandbox, so everything Kollate changes -
# all of it outside the project - is refused unless the installer says otherwise. This
# guards the two halves of that: the config edit the installer makes, and what a person
# is told on a machine where it was never made. No database, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import json, os, re, subprocess, sys, tempfile

passed = failed = 0
def check(name, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed += 1
        print(f"  FAIL {name}\n       got:  {got!r}\n       want: {want!r}")

# The installer carries this by copy, in two languages; read it back out of the shell one so
# the thing under test is the thing that ships.
found = re.search(r"KOLLATE_WRITABLE[^\n]*\n(.*?)\nKOLLATE_WRITABLE",
                  open("install.sh").read(), re.S)
check("install.sh still carries the config edit", bool(found), True)
script = found.group(1) if found else ""
check("and install.ps1 carries the same text", script in open("install.ps1").read(), True)

home = os.path.expanduser("~/.kollate")
WINDOWS_PATH = chr(67) + ":" + chr(92) + "Users" + chr(92) + "GT" + chr(92) + "other"
CASES = {
    "no config at all": (None, [home]),
    "an empty config": ("", [home]),
    "a config about other things": ('[plugins."kollate@kollate"]\nenabled = true\n', [home]),
    "the section, without the setting": ("[sandbox_workspace_write]\nnetwork_access = true\n", [home]),
    "the setting, with somebody else's path": (
        '[sandbox_workspace_write]\nwritable_roots = ["/opt/x"]\n', [home, "/opt/x"]),
    # A Windows path in a TOML basic string is a file full of invalid escapes - a lone "\\U"
    # takes Codex down with it. Seen on the bench machine before this was a literal string.
    "somebody else's Windows path": (
        f"[sandbox_workspace_write]\nwritable_roots = ['{WINDOWS_PATH}']\n",
        [home, WINDOWS_PATH]),
    "the setting, already ours": (
        f'[sandbox_workspace_write]\nwritable_roots = ["{home}"]\n', [home]),
}
print("the installer's edit, against every config it can meet")
try:
    import tomllib
except ModuleNotFoundError:
    print("  --  python is too old to parse TOML; the edit was not checked")
    tomllib = None

for name, (before, want) in CASES.items():
    room = tempfile.mkdtemp()
    if before is not None:
        with open(os.path.join(room, "config.toml"), "w") as handle:
            handle.write(before)
    subprocess.run([sys.executable, "-c", script], env=dict(os.environ, CODEX_HOME=room),
                   check=True, capture_output=True)
    with open(os.path.join(room, "config.toml"), "rb") as handle:
        raw = handle.read()
    if tomllib:
        parsed = tomllib.loads(raw.decode())
        check(f"{name} - still valid TOML, and ours is allowed",
              sorted(parsed["sandbox_workspace_write"]["writable_roots"]), sorted(want))
    if before and "network_access" in before:
        check("and nothing else in the section was lost",
              parsed["sandbox_workspace_write"].get("network_access"), True)
    if before is not None and home not in before:
        check(f"{name} - the original was kept alongside",
              os.path.isfile(os.path.join(room, "config.toml.kollate-backup")), True)

print("what a person is told when the sandbox refuses")
# A state change that never reached disk must not report success, and must not print a
# traceback either - it has to name the one thing that does work.
room = tempfile.mkdtemp()
shared = os.path.join(room, ".kollate")
data = os.path.join(room, "data")
os.makedirs(shared)
os.makedirs(data)
os.chmod(shared, 0o500)                      # the sandbox, in the only form a test can build
try:
    done = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "pause", "3h"],
                          env=dict(os.environ, HOME=room, CLAUDE_PLUGIN_DATA=data,
                                   CLAUDE_PLUGIN_ROOT=os.path.join(room, ".codex", "plugins",
                                                                   "cache", "kollate")),
                          capture_output=True, text=True)
finally:
    os.chmod(shared, 0o700)
check("it fails, rather than claiming to have paused", done.returncode, 1)
check("with no traceback", "Traceback" in (done.stdout + done.stderr), False)
check("it says nothing was changed", "Nothing was changed" in done.stdout, True)
check("it names the sandbox", "sandbox" in done.stdout, True)
check("it gives the command that does work", "kollate.py\" pause 3h" in done.stdout, True)
check("and the setting that would fix it for good",
      "writable_roots" in done.stdout, True)

print("what a person is told when the sandbox has no network")
# Codex's default mode gives a skill's command no network. Connecting, updating and
# backfilling all have to reach the workspace, so they say so instead of failing one layer
# down as a curl that returned nothing.
room = tempfile.mkdtemp()
env = dict(os.environ, HOME=room, CLAUDE_PLUGIN_DATA=os.path.join(room, "data"),
           CLAUDE_PLUGIN_ROOT=os.path.join(room, ".codex", "plugins", "cache", "kollate"),
           CODEX_SANDBOX_NETWORK_DISABLED="1")
for verb in ("connect", "update", "backfill"):
    done = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", verb],
                          env=env, capture_output=True, text=True)
    check(f"{verb} stops before trying", done.returncode, 1)
    check(f"{verb} says why", "needs the network" in done.stdout, True)
    check(f"{verb} names the place it works", "Run it in a terminal instead" in done.stdout, True)
check("and connecting explains the browser too",
      "opens a browser" in subprocess.run(
          [sys.executable, "plugins/kollate/hooks/kollate.py", "connect"],
          env=env, capture_output=True, text=True).stdout, True)
# Outside that sandbox the same verbs must not take this exit - connect is not run here
# because it would open a listener and wait for a browser that is not coming.
check("outside the sandbox nothing is refused",
      subprocess.run([sys.executable, "-c",
                      "import sys; sys.path.insert(0, 'plugins/kollate/hooks');"
                      "import kollate; print(kollate.no_network())"],
                     env={k: v for k, v in env.items()
                          if k != "CODEX_SANDBOX_NETWORK_DISABLED"},
                     capture_output=True, text=True).stdout.strip(), "False")

print("knowing which tool this is, without being told")
# Codex expands ${CLAUDE_PLUGIN_ROOT} into the skill text rather than exporting it, so a
# skill's command runs with that variable unset - and a Codex user was being told to run
# `/kollate:pause`, which exists only in the other tool. Where this file sits says it instead.
import shutil
room = tempfile.mkdtemp()
here = os.path.join(room, ".codex", "plugins", "cache", "kollate", "kollate", "0.0.0", "hooks")
os.makedirs(os.path.dirname(here), exist_ok=True)
shutil.copytree("plugins/kollate/hooks", here)
bare = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_PLUGIN_ROOT", "CLAUDE_PLUGIN_DATA")}
bare["HOME"] = room
out = subprocess.run([sys.executable, os.path.join(here, "kollate.py"), "status"],
                     env=bare, capture_output=True, text=True).stdout
check("with no variable set, it still knows it is Codex", "kollate:connect" in out, True)
check("and does not offer the other tool's slash form", "/kollate:connect" in out, False)

print("connecting, when the sandbox is what refused")
# An unreachable address and a sandbox with no network look identical from here. Under Codex
# it is the sandbox, and "check the address" would send a person to fix the wrong thing.
os.makedirs(os.path.join(room, ".kollate"), exist_ok=True)
with open(os.path.join(room, ".kollate", "config.json"), "w") as handle:
    json.dump({"endpoint": "https://127.0.0.1:9"}, handle)
done = subprocess.run([sys.executable, os.path.join(here, "kollate.py"), "connect"],
                      env=bare, capture_output=True, text=True, timeout=60)
check("it blames the sandbox, not the address", "needs the network" in done.stdout, True)
check("and never tells them to check the address",
      "Check the address" in done.stdout, False)

print("pausing just this session, in either tool")
# Each tool names the session differently. Reading only Claude Code's name meant that in
# Codex `kollate:pause session` answered "could not tell which session this is" and left
# capture running - the worst possible outcome for an opt-out.
room = tempfile.mkdtemp()
base = dict(os.environ, HOME=room, CLAUDE_PLUGIN_DATA=os.path.join(room, "data"))
base.pop("CLAUDE_CODE_SESSION_ID", None)
base.pop("CODEX_SESSION_ID", None)
base.pop("CODEX_THREAD_ID", None)
for name, wanted in (("CLAUDE_CODE_SESSION_ID", "from-claude"), ("CODEX_SESSION_ID", "from-codex"),
                     ("CODEX_THREAD_ID", "from-thread")):
    where = tempfile.mkdtemp()
    done = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "pause", "session"],
                          env=dict(base, HOME=where, **{name: wanted}),
                          capture_output=True, text=True)
    check(f"{name} is understood", done.returncode, 0)
    with open(os.path.join(where, ".kollate", "pause.json")) as handle:
        check(f"and {wanted} is the session that stopped",
              json.load(handle).get("sessions"), [wanted])
done = subprocess.run([sys.executable, "plugins/kollate/hooks/kollate.py", "pause", "session"],
                      env=dict(base, HOME=tempfile.mkdtemp()), capture_output=True, text=True)
check("with no session at all it says so rather than pretending", done.returncode, 1)
check("and points at a duration instead", "Use a duration instead" in done.stdout, True)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
