---
name: connect
description: Connect this machine to your Kollate account
---
Connecting needs the network and opens a sign-in page in a browser. Codex blocks both inside a session, so connecting always finishes in a real terminal. Your job is to hand the user ONE command line that works when pasted - nothing to install, no PATH setup.

**Where the script is.** This file is `<plugin>/codex-skills/connect/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Build the script path from the absolute path you loaded this file from. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it. If you do not know where this file came from, the plugin is the newest folder under `%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows (`~/.codex/plugins/cache/kollate/kollate/` on macOS/Linux).

**Never use `python3` or a bare `python`.** On Windows `python3` is a Microsoft Store stub that prints "Python was not found" and does nothing, and the user usually has no Python on PATH at all. Use Codex's own bundled Python, by full path:

- Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" connect`
  - If that exact file is not there, use the newest `python.exe` under `%USERPROFILE%\.cache\codex-runtimes\` (any `*\dependencies\python\python.exe`).
- macOS/Linux: `python3 "<plugin>/hooks/kollate.py" connect`

**What to do with the output.** Running it inside Codex will not connect (no network here); it prints one line that begins `Run it in a terminal instead:` followed by a complete command whose Python is already an absolute path. Show the user THAT line exactly and tell them to paste it into a terminal (PowerShell on Windows) and press Enter. That command works as-is. When they run it a browser opens - tell them to click "Connect this machine".

Never print any token, secret, or id from the output - only the sign-in step and that one command line. Report in one line what happened.
