---
name: backfill
description: Send conversations from before this machine was connected (opt-in)
---
This captures conversations that happened BEFORE this machine was connected to Kollate. It is off by default and never runs on its own, because history predating the connection is deliberately excluded.

Tell the user plainly what it will do - send their older Claude Code conversations on this machine to their organisation's Kollate workspace, where their workspace admins can read them - and ask them to confirm before running anything.

Only if they confirm, run `the script` with `backfill` and report its output. By default it reaches back only into the current directory's history (and its subdirectories); pass `all` to search the whole machine. It sends at most 20 conversations per run, most recent first; run it again to continue. A different bound can be given as `--limit=N`.

**Where the script is.** This file is `<plugin>/codex-skills/backfill/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Take the absolute path you loaded this file from and build the script path from it. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it, and a command with it in fails with "can't open file '/hooks/kollate.py'". If you do not know where this file came from, the plugin is the newest folder under `~/.codex/plugins/cache/kollate/kollate/` (`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows).

**Run it.** Never use `python3` or a bare `python` - on Windows `python3` is a do-nothing Microsoft Store stub and the user often has no Python on PATH. Use Codex's bundled Python by full path. Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" backfill` (if that file is absent, use the newest `*\dependencies\python\python.exe` under `%USERPROFILE%\.cache\codex-runtimes\`). macOS/Linux: `python3 "<plugin>/hooks/kollate.py" backfill`. If the script says it needs a terminal, it prints a ready-to-paste command whose Python is already an absolute path - show that line to the user exactly.

Report only what the script printed. Never mention interpreters, paths or the lookup when the command simply works. If the output says the command needs the network and gives a terminal line, show that line exactly - it is the answer, not a failure.
