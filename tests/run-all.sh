#!/usr/bin/env bash
# Every suite that needs no database, in one run, with a log worth keeping.
#   ./tests/run-all.sh            # to the terminal
#   ./tests/run-all.sh out.log    # and to a file
#
# tests/capture_flow.sh is deliberately NOT here: it needs a local Supabase and psql, so it
# cannot be the thing anybody runs to check a change quickly.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${1:-}"

run() {
  echo
  echo "=============================================================================="
  echo "$1"
  echo "=============================================================================="
  "./tests/$1"
}

main() {
  echo "Kollate test run - $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "host:   $(uname -srm)"
  echo "python: $(python3 -V 2>&1)"
  echo "plugin: $(python3 -c 'import json;print(json.load(open("plugins/kollate/.claude-plugin/plugin.json"))["version"])')"
  echo "commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'not a repository')"
  rc=0
  for suite in endpoint_resolution.sh claude_capture.sh codex_capture.sh live_transcripts.sh; do
    run "$suite" || rc=1
  done
  echo
  echo "=============================================================================="
  if [ $rc -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SOMETHING FAILED - read up"; fi
  echo "=============================================================================="
  return $rc
}

if [ -n "$LOG" ]; then
  main 2>&1 | tee "$LOG"
  exit "${PIPESTATUS[0]}"
fi
main
