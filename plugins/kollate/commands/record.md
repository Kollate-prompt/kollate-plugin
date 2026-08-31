---
description: Say yes - record this project's sessions to Kollate
---
Run `py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record` and report its output in one line.
This approves the current working directory (and its subdirectories) for capture. Only sessions
from this moment on are captured - never anything said before approval.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), Python is genuinely missing: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Do not send the user away to install it, and do not mention interpreters at all when the command simply works.
