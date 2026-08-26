---
description: Show Kollate's health on this desktop - version, connection, capture state
---
Run `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py status` and show its output to the user as a
code block, unchanged. If something looks wrong (not connected, paused, opted out), add one short
sentence saying which command fixes it.

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead, and if that also fails, with `py -3` (the Windows launcher - present even when Python was installed without updating PATH).
If all three fail on Windows (the output is just "Python", nothing, or the Microsoft Store opens), Python is not really installed - install it yourself, do not send the user away to do it:
`winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`
then retry the command with `python`. If the new PATH is not picked up yet, tell the user to close this session, open a new one, and run the command again - it will work there.
