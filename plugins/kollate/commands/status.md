---
description: Show Kollate's health on this desktop - version, connection, capture state
---
Run `py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status` and show its output to the user as a
code block, unchanged. If something looks wrong (not connected, paused, opted out), add one short
sentence saying which command fixes it.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), Python is genuinely missing: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Do not send the user away to install it, and do not mention interpreters at all when the command simply works.
