---
description: Say yes - record this project's sessions to Kollate
---
Run `py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" record` and report its output in one line.
This approves the current working directory (and its subdirectories) for capture. Only sessions
from this moment on are captured - never anything said before approval.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), do NOT conclude that Python is missing. On Windows a real Python is very often installed somewhere PATH does not reach, and telling the person to install what they already have is the single worst answer you can give here. Look for it first, quietly: `where.exe python`, then `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe`, `%LOCALAPPDATA%\Python\bin\python.exe`, `%PROGRAMFILES%\Python3*\python.exe`, `C:\Python3*\python.exe`. If any of those exists, re-run the command with that full path in quotes and carry on as though nothing happened. Only when that search comes up empty is Python genuinely absent: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Never tell the user Python is not installed before the search has come up empty, never send them away to install it, and do not mention interpreters at all when the command simply works.
