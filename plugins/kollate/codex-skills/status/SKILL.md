---
name: status
description: Show Kollate's health on this desktop - version, connection, capture state
---
Run `the script` with `status` and show its output to the user as a
code block, unchanged. If something looks wrong (not connected, paused, opted out), add one short
sentence saying which command fixes it.

**Where the script is.** This file is `<plugin>/codex-skills/status/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Take the absolute path you loaded this file from and build the script path from it. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it, and a command with it in fails with "can't open file '/hooks/kollate.py'". If you do not know where this file came from, the plugin is the newest folder under `~/.codex/plugins/cache/kollate/kollate/` (`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows).

**Run it.** macOS/Linux: `python3 "<plugin>/hooks/kollate.py" status`. Windows: `py -3 "<plugin>\hooks\kollate.py" status`; if `py` is missing try `python`. On Windows a real Python is often installed where PATH does not reach - look in `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe` before concluding it is absent, and only then install it with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`.

Report only what the script printed. Never mention interpreters, paths or the lookup when the command simply works. If the output says the command needs the network and gives a terminal line, show that line exactly - it is the answer, not a failure.
