---
name: doctor
description: Diagnose where Kollate reads its credentials and hooks from on this machine
---
Run `the script` with `doctor` and show its output to the user as a code block, unchanged. It
prints NO secrets - only paths, booleans, sizes and timestamps - so it is safe to show and
screenshot. It exists to debug the "connected in a terminal but the app says Connected: NO"
split: run it here (inside the app) and compare with the same command run in a terminal.

**Where the script is.** This file is `<plugin>/codex-skills/doctor/SKILL.md`; the script is
`<plugin>/hooks/kollate.py`, two folders up. Build the script path from the absolute path you
loaded this file from. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it. If you do not
know where this file came from, the plugin is the newest folder under
`%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows (`~/.codex/plugins/cache/kollate/kollate/` elsewhere).

**Run it.** Never use `python3` or a bare `python` - on Windows `python3` is a do-nothing
Microsoft Store stub and the user often has no Python on PATH. Use Codex's bundled Python by
full path. Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" doctor` (if that file is absent, use the newest `*\dependencies\python\python.exe` under `%USERPROFILE%\.cache\codex-runtimes\`). macOS/Linux: `python3 "<plugin>/hooks/kollate.py" doctor`.

Show exactly what it printed, as a code block. Do not interpret or summarise - the whole point is
the raw values.
