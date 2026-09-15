---
name: record
description: Say yes - record this project's sessions to Kollate
---
Run `the script` with `record` and report its output in one line.
This approves the current working directory (and its subdirectories) for capture. Only sessions
from this moment on are captured - never anything said before approval.

**Where the script is.** This file is `<plugin>/codex-skills/record/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Take the absolute path you loaded this file from and build the script path from it. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it, and a command with it in fails with "can't open file '/hooks/kollate.py'". If you do not know where this file came from, the plugin is the newest folder under `~/.codex/plugins/cache/kollate/kollate/` (`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows).

**Run it.** Never use `python3` or a bare `python` - on Windows `python3` is a do-nothing Microsoft Store stub and the user often has no Python on PATH. Use Codex's bundled Python by full path. Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" record` (if that file is absent, use the newest `*\dependencies\python\python.exe` under `%USERPROFILE%\.cache\codex-runtimes\`). macOS/Linux: `python3 "<plugin>/hooks/kollate.py" record`. If the script says it needs a terminal, it prints a ready-to-paste command whose Python is already an absolute path - show that line to the user exactly.

Report only what the script printed. Never mention interpreters, paths or the lookup when the command simply works. If the output says the command needs the network and gives a terminal line, show that line exactly - it is the answer, not a failure.
