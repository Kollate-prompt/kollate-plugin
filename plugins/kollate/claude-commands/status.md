---
description: Show Kollate's health on this desktop - version, connection, capture state
---
Run `py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" status` and show its output to the user as a
code block, unchanged. If something looks wrong (not connected, paused, opted out), add one short
sentence saying which command fixes it.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), do NOT conclude that Python is missing. On Windows a real Python is very often installed somewhere PATH does not reach, and telling the person to install what they already have is the single worst answer you can give here. Look for it first, quietly: `where.exe python`, then `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe`, `%LOCALAPPDATA%\Python\bin\python.exe`, `%PROGRAMFILES%\Python3*\python.exe`, `C:\Python3*\python.exe`. If any of those exists, re-run the command with that full path in quotes and carry on as though nothing happened. Only when that search comes up empty is Python genuinely absent: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Never tell the user Python is not installed before the search has come up empty, never send them away to install it, and do not mention interpreters at all when the command simply works.
