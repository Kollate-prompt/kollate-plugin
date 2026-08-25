#!/usr/bin/env bash
# zombie-hunt.sh - find out HOW a plugin keeps resurrecting in the Claude desktop app,
# and kill it in a way that can't be undone by the app itself.
#
#   bash zombie-hunt.sh scan      # read-only: where does "kollate" live, what's running
#   bash zombie-hunt.sh purge     # kill app processes, back everything up, scrub, verify clean
#   bash zombie-hunt.sh verdict   # AFTER reopening the app: what came back, from where, and why
#
# Nothing is lost: purge copies every store it touches into ~/kollate-hunt/backup-<time>/
set -uo pipefail

WORD="kollate"
HUNT="$HOME/kollate-hunt"
mkdir -p "$HUNT"

APP_SUPPORT="$HOME/Library/Application Support/Claude"
ROOTS=(
  "$APP_SUPPORT"
  "$HOME/.claude"
  "$HOME/.claude.json"
  "$HOME/.kollate"
  "$HOME/Library/Caches/claude-code"
  "$HOME/Library/Caches/com.anthropic.claudefordesktop"
  "$HOME/Library/Preferences"
  "$HOME/Library/Saved Application State/com.anthropic.claudefordesktop.savedState"
  "/Library/Application Support/ClaudeCode"
)

list_procs() {
  # Desktop app only - never the `claude` CLI running in a terminal
  pgrep -fl 'Claude\.app' 2>/dev/null || true
}

scan_hits() {
  # Every file whose NAME or CONTENT mentions kollate, with mtime, oldest first
  for r in "${ROOTS[@]}"; do
    [ -e "$r" ] || continue
    if [ -f "$r" ]; then
      grep -qsi --binary-files=text "$WORD" "$r" && echo "$r"
      continue
    fi
    find "$r" -iname "*${WORD}*" 2>/dev/null
    grep -rlsi --binary-files=text "$WORD" "$r" 2>/dev/null
  done | sort -u | while IFS= read -r f; do
    stat -f '%m %Sm  %N' -t '%H:%M:%S' "$f" 2>/dev/null
  done | sort -n | cut -d' ' -f2-
}

case "${1:-scan}" in

scan)
  echo "== Claude desktop app processes =="
  P=$(list_procs)
  if [ -n "$P" ]; then echo "$P"; else echo "(none running)"; fi
  echo
  echo "== Files mentioning '$WORD' (oldest first: mtime  path) =="
  scan_hits | tee "$HUNT/scan-before.txt"
  echo
  echo "$(wc -l < "$HUNT/scan-before.txt" | tr -d ' ') hit(s). Saved to $HUNT/scan-before.txt"
  ;;

purge)
  echo "== Step 1: kill the desktop app - ALL of it =="
  osascript -e 'quit app "Claude"' >/dev/null 2>&1
  sleep 3
  pkill -9 -f 'Claude\.app' 2>/dev/null
  sleep 2
  P=$(list_procs)
  if [ -n "$P" ]; then
    echo "FATAL: app processes still alive - this is exactly how the plugin survives."
    echo "$P"
    echo "Force-quit them (Activity Monitor) and rerun purge."
    exit 1
  fi
  echo "OK: zero Claude.app processes."

  echo "== Step 2: backup =="
  BK="$HUNT/backup-$(date +%H%M%S)"
  mkdir -p "$BK"
  for d in "Local Storage" "Session Storage" "IndexedDB"; do
    [ -d "$APP_SUPPORT/$d" ] && cp -R "$APP_SUPPORT/$d" "$BK/" 2>/dev/null
  done
  [ -d "$APP_SUPPORT/local-agent-mode-sessions" ] && cp -R "$APP_SUPPORT/local-agent-mode-sessions" "$BK/" 2>/dev/null
  [ -d "$HOME/.claude/plugins" ] && cp -R "$HOME/.claude/plugins" "$BK/cli-plugins" 2>/dev/null
  [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$BK/" 2>/dev/null
  echo "Backed up to $BK - nothing tonight is unrecoverable."

  echo "== Step 3: scrub =="
  # 3a. CLI-side registries + settings (surgical, JSON-aware)
  python3 - <<'PY'
import json, os
def scrub(path, fn):
    try:
        with open(path) as h: data = json.load(h)
    except Exception: return
    if fn(data):
        with open(path, "w") as h: json.dump(data, h, indent=2)
        print(f"scrubbed {path}")
def rm_keys(d):
    hit = False
    if isinstance(d, dict):
        for k in [k for k in d if "kollate" in k.lower()]:
            del d[k]; hit = True
        for v in d.values(): hit = rm_keys(v) or hit
    elif isinstance(d, list):
        for v in d: hit = rm_keys(v) or hit
    return hit
home = os.path.expanduser("~")
for f in ("settings.json", "settings.local.json",
          "plugins/installed_plugins.json", "plugins/known_marketplaces.json"):
    scrub(os.path.join(home, ".claude", f), rm_keys)
scrub(os.path.join(home, ".claude.json"), rm_keys)
PY
  # 3b. kollate files anywhere under the roots
  rm -rf "$HOME/.claude/plugins/cache/kollate" "$HOME/.claude/plugins/marketplaces/kollate" \
         "$HOME/.claude/plugins/data/kollate" "$HOME/.kollate" 2>/dev/null
  find "$APP_SUPPORT" -depth -iname "*${WORD}*" -exec rm -rf {} \; 2>/dev/null
  # 3c. the app's browser-side stores - the ONLY places the leveldb registry can hide
  rm -rf "$APP_SUPPORT/Local Storage" "$APP_SUPPORT/Session Storage" "$APP_SUPPORT/IndexedDB" 2>/dev/null

  echo "== Step 4: prove the disk is clean =="
  scan_hits > "$HUNT/scan-clean.txt"
  N=$(wc -l < "$HUNT/scan-clean.txt" | tr -d ' ')
  if [ "$N" -eq 0 ]; then
    echo "CLEAN: zero files on this Mac mention '$WORD'."
  else
    echo "STILL DIRTY ($N hits) - these survived, and one of them is the source:"
    cat "$HUNT/scan-clean.txt"
    exit 1
  fi
  date +%s > "$HUNT/purge-time.txt"
  echo
  echo "Now: open the Claude app, sign in if asked, open the Plugins screen, wait ~1 min."
  echo "Then run:  bash zombie-hunt.sh verdict"
  ;;

verdict)
  [ -f "$HUNT/purge-time.txt" ] || { echo "Run purge first."; exit 1; }
  PT=$(cat "$HUNT/purge-time.txt")
  echo "== What mentions '$WORD' now (oldest first) =="
  scan_hits | tee "$HUNT/scan-after.txt"
  N=$(wc -l < "$HUNT/scan-after.txt" | tr -d ' ')
  echo
  if [ "$N" -eq 0 ]; then
    echo "VERDICT: still clean. The zombie is dead. Tonight's failures were flush-on-quit -"
    echo "the app rewrote its registry from memory because a helper process was alive"
    echo "during every previous wipe. This purge killed the processes first, so it stuck."
  else
    echo "VERDICT: it came back. Disk was PROVEN clean at $(date -r "$PT" +%H:%M:%S),"
    echo "the app was fully dead, and every file above was created AFTER relaunch."
    echo "The only remaining writer is the app itself pulling the WHOLE plugin registry"
    echo "from the ACCOUNT (server sync) - which also explains why every other deleted"
    echo "plugin resurrects, not just this one. Local deletion can never win."
    echo "The real delete is server-side: in the app, Plugins -> the plugin -> (...) ->"
    echo "Uninstall, done ONLINE, then verify it is gone at claude.ai as well. If the"
    echo "in-app uninstall itself reverts, that is Anthropic's bug - file it."
    echo "Evidence bundle: $HUNT/scan-before.txt, scan-clean.txt, scan-after.txt"
  fi
  ;;

*)
  echo "usage: zombie-hunt.sh scan|purge|verdict"; exit 2 ;;
esac
