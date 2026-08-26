---
description: Show Kollate's health on this desktop - version, connection, capture state
---
Run `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py status` and show its output to the user as a
code block, unchanged. If something looks wrong (not connected, paused, opted out), add one short
sentence saying which command fixes it.

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead.
