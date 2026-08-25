#!/usr/bin/env bash
# Kollate full reset - one command that removes every copy, cache and stale pin,
# then installs fresh. For the machine where updates refuse to take.
#
#   curl -fsSL https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/reset.sh | bash -s -- https://your-kollate-address
#
# What it clears: the plugin at every scope, all cached versions, the desktop
# app's cache, kollate entries in any project-level .claude/settings*.json under
# your home folder, and ~/.kollate. Conversations already in Kollate are untouched.
# You will need to run /kollate:connect once afterwards.
set -uo pipefail

URL="${1:-}"
[ -n "$URL" ] || { echo "Usage: reset.sh https://your-kollate-address" >&2; exit 2; }

echo "-> Removing the plugin and its marketplace"
claude plugin uninstall kollate@kollate >/dev/null 2>&1
claude plugin marketplace remove kollate >/dev/null 2>&1

echo "-> Deleting every cached copy and local state"
rm -rf "$HOME/.claude/plugins/cache/kollate" \
       "$HOME/.claude/plugins/marketplaces/kollate" \
       "$HOME/.claude/plugins/data/kollate-kollate" \
       "$HOME/.kollate" \
       "$HOME/Library/Caches/claude-code" 2>/dev/null

echo "-> Scrubbing kollate from project-level Claude settings"
python3 - <<'PY'
import glob, json, os
patterns = [os.path.expanduser(p) for p in
            ("~/Documents/**/.claude/settings*.json", "~/Projects/**/.claude/settings*.json",
             "~/Desktop/**/.claude/settings*.json")]
for pattern in patterns:
    for path in glob.glob(pattern, recursive=True):
        try:
            data = json.load(open(path))
        except Exception:
            continue
        touched = False
        for section in ("enabledPlugins", "pluginConfigs"):
            block = data.get(section)
            if isinstance(block, dict):
                for key in [k for k in block if "kollate" in k.lower()]:
                    del block[key]
                    touched = True
        if touched:
            json.dump(data, open(path, "w"), indent=2)
            print(f"   cleaned {path}")
PY

echo "-> Installing fresh"
curl -fsSL https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.sh | bash -s -- "$URL"

echo ""
echo "-> Connecting this desktop (your browser will open - approve the sign-in)"
HOOK=$(ls -d "$HOME"/.claude/plugins/cache/kollate/kollate/*/hooks/kollate.py 2>/dev/null | sort -V | tail -1)
if [ -n "$HOOK" ] && python3 "$HOOK" connect; then
  echo ""
  echo "  Reset complete and connected. Last step: quit Claude COMPLETELY, reopen,"
  echo "  and start a NEW chat - /kollate:status there should show the newest version."
else
  echo ""
  echo "  Reset complete, but the sign-in did not finish. After restarting Claude,"
  echo "  run /kollate:connect in a new chat to connect this desktop."
fi
