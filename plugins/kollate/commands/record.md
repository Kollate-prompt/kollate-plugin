---
description: Say yes - record this project's sessions to Kollate
---
Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record` and report its output in one line.
This approves the current working directory (and its subdirectories) for capture. Only sessions
from this moment on are captured - never anything said before approval.

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead, and if that also fails, with `py -3` (the Windows launcher - present even when Python was installed without updating PATH).
If all three fail on Windows (the output is just "Python", nothing, or the Microsoft Store opens), Python is not really installed - install it yourself, do not send the user away to do it:
`winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`
then retry the command with `python`. If the new PATH is not picked up yet, tell the user to close this session, open a new one, and run the command again - it will work there.

On Windows `python3` is usually the Microsoft Store stub and fails immediately. If that happens, rerun the same command with `python`, then `py -3`, before reporting any failure to the user.
