---
description: Pause Kollate capture - this session, or everything for a while
---
If the user gave an argument (session / 3h / today / week / dir), run
`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py pause <argument>` and report its output in one line.

If they gave no argument, ask which they want - **this session only**, **this working directory** (never capture sessions here), **3 hours**, **rest of today**, or **a week** - then run the command with their choice. Do not guess. Paused turns are dropped permanently, not queued; say so if asked.

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead.
If both fail on Windows (the output is just "Python", nothing, or the Microsoft Store opens), Python is not really installed - install it yourself, do not send the user away to do it:
`winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`
then retry the command with `python`. If the new PATH is not picked up yet, tell the user to close this session, open a new one, and run the command again - it will work there.
