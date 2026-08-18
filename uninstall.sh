#!/usr/bin/env bash
# Remove Kollate from this machine completely, so an install can be tested from nothing.
#
#   ./uninstall.sh          # say what would go
#   ./uninstall.sh --yes    # do it
#
# Takes the credential with it, so this machine stops being captured immediately. Conversations
# already delivered are untouched - they live in your workspace, not here. Disconnect the machine
# from the Connect page too if you want the server to forget it as well.
set -euo pipefail

APPLY=no
[ "${1:-}" = "--yes" ] && APPLY=yes
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

DIRS=(
  "$CONFIG_DIR/plugins/marketplaces/kollate"
  "$CONFIG_DIR/plugins/cache/kollate"
  "$CONFIG_DIR/plugins/data/kollate-kollate"
  "$HOME/.kollate"
)

echo "Kollate on this machine:"
found=0
for d in "${DIRS[@]}"; do
  [ -e "$d" ] && { echo "  dir   $d"; found=1; }
done
CONFIG_DIR="$CONFIG_DIR" python3 - <<'PY'
import json, os
config = os.environ["CONFIG_DIR"]
for name, keys in (("settings.json", ("pluginConfigs", "enabledPlugins", "extraKnownMarketplaces")),
                   ("plugins/installed_plugins.json", None),
                   ("plugins/known_marketplaces.json", None)):
    path = os.path.join(config, name)
    try:
        data = json.load(open(path))
    except Exception:
        continue
    if keys:
        for key in keys:
            hits = [k for k in data.get(key, {}) if "kollate" in k.lower()]
            for h in hits:
                print(f"  entry {name} → {key} → {h}")
    else:
        body = data.get("plugins", data)
        for h in [k for k in body if "kollate" in k.lower()]:
            print(f"  entry {name} → {h}")
PY

if [ "$APPLY" != yes ]; then
  echo
  echo "Nothing changed. Re-run with --yes to remove all of it."
  exit 0
fi

echo
# Ask Claude Code to do it properly first; fall back to removing the files ourselves.
claude plugin uninstall kollate@kollate >/dev/null 2>&1 || true
claude plugin marketplace remove kollate >/dev/null 2>&1 || true

for d in "${DIRS[@]}"; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  removed $d"; }
done

CONFIG_DIR="$CONFIG_DIR" python3 - <<'PY'
import json, os
config = os.environ["CONFIG_DIR"]

def scrub(path, containers):
    try:
        data = json.load(open(path))
    except Exception:
        return
    changed = False
    for container in containers:
        target = data.get(container)
        if not isinstance(target, dict):
            continue
        for key in [k for k in target if "kollate" in k.lower()]:
            del target[key]
            changed = True
            print(f"  removed entry {os.path.basename(path)} → {container} → {key}")
        if container != "__root__" and target == {}:
            pass
    # Some registries keep the plugins at the top level rather than under a container.
    for key in [k for k in data if "kollate" in k.lower()]:
        del data[key]
        changed = True
        print(f"  removed entry {os.path.basename(path)} → {key}")
    if changed:
        mode = os.stat(path).st_mode & 0o777
        tmp = path + ".tmp"
        handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(handle, "w") as out:
            json.dump(data, out, indent=2)
        os.chmod(tmp, mode)
        os.replace(tmp, path)

scrub(os.path.join(config, "settings.json"),
      ["pluginConfigs", "enabledPlugins", "extraKnownMarketplaces"])
scrub(os.path.join(config, "plugins/installed_plugins.json"), ["plugins"])
scrub(os.path.join(config, "plugins/known_marketplaces.json"), [])
PY

echo
echo "Gone. Restart Claude Code and it will know nothing about Kollate."
