#!/usr/bin/env bash
# The desktop app loads the plugin but has no userConfig screen, so the address has to come
# from somewhere else or connect fails with nothing the person can do. Needs no database,
# which is the point - it guards the case the DB-backed suite cannot reach.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import json, os, subprocess, sys, tempfile

CODE = ("import sys; sys.path.insert(0,'plugins/kollate/hooks'); import kollate; "
        "print(kollate.configured_endpoint())")

def resolve(home, userconfig=None):
    env = dict(os.environ, HOME=home)
    env.pop("CLAUDE_PLUGIN_OPTION_ENDPOINT", None)
    env.pop("CLAUDE_PLUGIN_DATA", None)
    if userconfig:
        env["CLAUDE_PLUGIN_OPTION_ENDPOINT"] = userconfig
    return subprocess.run([sys.executable, "-c", CODE], env=env,
                          capture_output=True, text=True).stdout.strip()

with_file = tempfile.mkdtemp()
os.makedirs(os.path.join(with_file, ".kollate"))
with open(os.path.join(with_file, ".kollate", "config.json"), "w") as handle:
    json.dump({"endpoint": "https://from-file.example"}, handle)

checks = [
    ("file used when userConfig absent", resolve(with_file), "https://from-file.example"),
    ("userConfig wins when present",
     resolve(with_file, "https://from-userconfig.example"), "https://from-userconfig.example"),
    ("empty when neither is set", resolve(tempfile.mkdtemp()), ""),
]
failed = 0
for name, got, want in checks:
    ok = got == want
    failed += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {name:34} {got!r}")
print(f"\n{len(checks) - failed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
