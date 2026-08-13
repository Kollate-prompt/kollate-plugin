---
description: Send conversations from before this machine was connected (opt-in)
---
This captures conversations that happened BEFORE this machine was connected to Kollate. It is off by default and never runs on its own, because history predating the connection is deliberately excluded.

Tell the user plainly what it will do - send their older Claude Code conversations on this machine to their organisation's Kollate workspace, where their workspace admins can read them - and ask them to confirm before running anything.

Only if they confirm, run `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py backfill` and report its output. It sends at most 20 conversations per run, most recent first; run it again to continue. A different bound can be given as `--limit=N`.
