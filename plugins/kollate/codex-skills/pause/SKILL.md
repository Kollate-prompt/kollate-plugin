---
name: pause
description: Pause Kollate capture - this session, or everything for a while
---
If the user gave an argument (session / 3h / today / week / dir), run
`the script` with `pause <argument>` and report its output in one line.

If they gave no argument, ask which they want - **this session only**, **this working directory** (never capture sessions here), **3 hours**, **rest of today**, or **a week** - then run the command with their choice. Do not guess. Paused turns are dropped permanently, not queued; say so if asked.

**Where the script is.** This file is `<plugin>/codex-skills/pause/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Take the absolute path you loaded this file from and build the script path from it. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it, and a command with it in fails with "can't open file '/hooks/kollate.py'". If you do not know where this file came from, the plugin is the newest folder under `~/.codex/plugins/cache/kollate/kollate/` (`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows).

**Run it.** Never use `python3` or a bare `python` - on Windows `python3` is a do-nothing Microsoft Store stub and the user often has no Python on PATH. Use Codex's bundled Python by full path. Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" pause <argument>` (if that file is absent, use the newest `*\dependencies\python\python.exe` under `%USERPROFILE%\.cache\codex-runtimes\`). macOS/Linux: `python3 "<plugin>/hooks/kollate.py" pause <argument>`. If the script says it needs a terminal, it prints a ready-to-paste command whose Python is already an absolute path - show that line to the user exactly.

Report only what the script printed. Never mention interpreters, paths or the lookup when the command simply works. If the output says the command needs the network and gives a terminal line, show that line exactly - it is the answer, not a failure.
