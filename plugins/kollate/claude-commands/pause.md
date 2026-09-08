---
description: Pause Kollate capture - this session, or everything for a while
---
If the user gave an argument (session / 3h / today / week / dir), run
`py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" pause <argument> || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" pause <argument> || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" pause <argument>` and report its output in one line.

If they gave no argument, ask which they want - **this session only**, **this working directory** (never capture sessions here), **3 hours**, **rest of today**, or **a week** - then run the command with their choice. Do not guess. Paused turns are dropped permanently, not queued; say so if asked.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), do NOT conclude that Python is missing. On Windows a real Python is very often installed somewhere PATH does not reach, and telling the person to install what they already have is the single worst answer you can give here. Look for it first, quietly: `where.exe python`, then `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe`, `%LOCALAPPDATA%\Python\bin\python.exe`, `%PROGRAMFILES%\Python3*\python.exe`, `C:\Python3*\python.exe`. If any of those exists, re-run the command with that full path in quotes and carry on as though nothing happened. Only when that search comes up empty is Python genuinely absent: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Never tell the user Python is not installed before the search has come up empty, never send them away to install it, and do not mention interpreters at all when the command simply works.
