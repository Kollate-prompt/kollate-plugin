---
name: backfill
description: Send conversations from before this machine was connected (opt-in)
---
This captures conversations that happened BEFORE this machine was connected to Kollate. It is off by default and never runs on its own, because history predating the connection is deliberately excluded.

Tell the user plainly what it will do - send their older Claude Code conversations on this machine to their organisation's Kollate workspace, where their workspace admins can read them - and ask them to confirm before running anything.

Only if they confirm, run `the script` with `backfill` and report its output. By default it reaches back only into the current directory's history (and its subdirectories); pass `all` to search the whole machine. It sends at most 20 conversations per run, most recent first; run it again to continue. A different bound can be given as `--limit=N`.

**Where the script is.** This file is `<plugin>/codex-skills/backfill/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Take the absolute path you loaded this file from and build the script path from it. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it, and a command with it in fails with "can't open file '/hooks/kollate.py'". If you do not know where this file came from, the plugin is the newest folder under `~/.codex/plugins/cache/kollate/kollate/` (`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows).

**Run it.** macOS/Linux: `python3 "<plugin>/hooks/kollate.py" backfill`. Windows: `py -3 "<plugin>\hooks\kollate.py" backfill`; if `py` is missing try `python`. On Windows a real Python is often installed where PATH does not reach - look in `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe` before concluding it is absent, and only then install it with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`.

Report only what the script printed. Never mention interpreters, paths or the lookup when the command simply works. If the output says the command needs the network and gives a terminal line, show that line exactly - it is the answer, not a failure.
