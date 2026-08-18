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
claude plugin marketplace add Kollate-prompt/kollate-plugin >/dev/null

echo "→ Installing the plugin"
claude plugin install kollate >/dev/null 2>&1 || claude plugin install kollate@kollate >/dev/null

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

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as handle:
    json.dump(settings, handle, indent=2)
os.replace(tmp, path)
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
