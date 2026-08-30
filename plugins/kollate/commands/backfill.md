---
description: Send conversations from before this machine was connected (opt-in)
---
This captures conversations that happened BEFORE this machine was connected to Kollate. It is off by default and never runs on its own, because history predating the connection is deliberately excluded.

Tell the user plainly what it will do - send their older Claude Code conversations on this machine to their organisation's Kollate workspace, where their workspace admins can read them - and ask them to confirm before running anything.

Only if they confirm, run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" backfill || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" backfill || py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" backfill` and report its output. By default it reaches back only into the current directory's history (and its subdirectories); pass `all` to search the whole machine. It sends at most 20 conversations per run, most recent first; run it again to continue. A different bound can be given as `--limit=N`.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), Python is genuinely missing: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Do not send the user away to install it, and do not mention interpreters at all when the command simply works.
