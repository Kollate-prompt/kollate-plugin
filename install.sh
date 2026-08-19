#!/usr/bin/env bash
# Kollate for Claude Code - one command.
#
#   curl -fsSL https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.sh | bash -s -- https://your-kollate-address
#
# Works on every Claude Code version: the address is written to settings.json rather than
# passed as --config, which older builds reject. Existing settings are merged, not replaced.
set -euo pipefail

URL="${1:-}"
if [ -z "$URL" ]; then
  echo "Usage: install.sh https://your-kollate-address" >&2
  echo "Your Kollate address is the one you sign in at - it is shown on the Connect page." >&2
  exit 2
fi
case "$URL" in
  https://*) ;;
  *) echo "The address must start with https:// - got: $URL" >&2; exit 2 ;;
esac

command -v claude  >/dev/null || { echo "Claude Code is not installed."   >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (macOS and Linux ship it)." >&2; exit 1; }
command -v curl    >/dev/null || { echo "curl is required."               >&2; exit 1; }

echo "→ Adding the Kollate marketplace"
claude plugin marketplace add Kollate-prompt/kollate-plugin >/dev/null 2>&1 \
  || claude plugin marketplace update kollate >/dev/null

echo "→ Installing the plugin"
claude plugin install kollate >/dev/null 2>&1 || claude plugin install kollate@kollate >/dev/null

# `install` is a no-op when the plugin is already present, and an old version is exactly why
# someone re-runs this script - so always finish on the latest release.
claude plugin update kollate@kollate >/dev/null 2>&1 || claude plugin update kollate >/dev/null 2>&1 || true

echo "→ Pointing it at $URL"
KOLLATE_URL="$URL" python3 - <<'PY'
import json, os

path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                    "settings.json")
try:
    with open(path) as handle:
        settings = json.load(handle)
except Exception:
    settings = {}

# Merge. Somebody's other plugins, hooks and permissions live in this file too.
options = (settings.setdefault("pluginConfigs", {})
                   .setdefault("kollate@kollate", {})
                   .setdefault("options", {}))
options["endpoint"] = os.environ["KOLLATE_URL"].rstrip("/")
settings.setdefault("enabledPlugins", {})["kollate@kollate"] = True

os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)

# Keep whatever permissions the file already had; create a new one owner-only. This file can
# carry hook commands and permission rules, so it must not become group- or world-writable.
try:
    mode = os.stat(path).st_mode & 0o777
except OSError:
    mode = 0o600

tmp = path + ".tmp"
handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump(settings, out, indent=2)
os.chmod(tmp, mode)
os.replace(tmp, path)

# The desktop app loads the plugin but has no userConfig screen - its plugin page offers only
# Skills and Hooks - so the setting above is invisible there. The same address goes to a file
# both surfaces read, which is what lets one install cover the terminal and the app.
shared = os.path.expanduser("~/.kollate")
os.makedirs(shared, mode=0o700, exist_ok=True)
config = os.path.join(shared, "config.json")
tmp = config + ".tmp"
handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump({"endpoint": os.environ["KOLLATE_URL"].rstrip("/")}, out)
os.replace(tmp, config)
PY

cat <<DONE

  Installed.

  Two things left, and they are both yours:

    1. Quit Claude Code completely and open it again.
       Plugins load at startup - a session already running will not see this one.

    2. Run:  /kollate:connect

  Your browser opens the sign-in you already use. Approve it, and this machine is
  connected. You are never shown a key and never edit a file.

DONE
