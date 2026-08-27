---
description: Send conversations from before this machine was connected (opt-in)
---
This captures conversations that happened BEFORE this machine was connected to Kollate. It is off by default and never runs on its own, because history predating the connection is deliberately excluded.

Tell the user plainly what it will do - send their older Claude Code conversations on this machine to their organisation's Kollate workspace, where their workspace admins can read them - and ask them to confirm before running anything.

Only if they confirm, run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" backfill` and report its output. It sends at most 20 conversations per run, most recent first; run it again to continue. A different bound can be given as `--limit=N`.

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead, and if that also fails, with `py -3` (the Windows launcher - present even when Python was installed without updating PATH).
If all three fail on Windows (the output is just "Python", nothing, or the Microsoft Store opens), Python is not really installed - install it yourself, do not send the user away to do it:
`winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`
then retry the command with `python`. If the new PATH is not picked up yet, tell the user to close this session, open a new one, and run the command again - it will work there.
