---
description: Pause Kollate capture - this session, or everything for a while
---
If the user gave an argument (session / 3h / today / week / dir), run
`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py pause <argument>` and report its output in one line.

If they gave no argument, ask which they want - **this session only**, **this working directory** (never capture sessions here), **3 hours**, **rest of today**, or **a week** - then run the command with their choice. Do not guess. Paused turns are dropped permanently, not queued; say so if asked.
