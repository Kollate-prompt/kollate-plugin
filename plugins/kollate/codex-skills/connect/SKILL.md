---
name: connect
description: Connect this machine to your Kollate account
---
Connecting needs the network and a sign-in in the browser. Your job: run the connect script and get the user signed in with the least friction - ideally without them leaving the app.

**Where the script is.** This file is `<plugin>/codex-skills/connect/SKILL.md`; the script is `<plugin>/hooks/kollate.py`, two folders up. Build the script path from the absolute path you loaded this file from. Do not use `${CLAUDE_PLUGIN_ROOT}` - Codex does not set it. If you do not know where this file came from, the plugin is the newest folder under `%USERPROFILE%\.codex\plugins\cache\kollate\kollate\` on Windows (`~/.codex/plugins/cache/kollate/kollate/` on macOS/Linux).

**Run the script.** Never use `python3` or a bare `python` - on Windows `python3` is a Microsoft Store stub that does nothing and the user usually has no Python on PATH. Use Codex's own bundled Python, by full path, with the `&` call operator:

- Windows: `& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" "<plugin>\hooks\kollate.py" connect`
  - If that exact file is absent, use the newest `python.exe` under `%USERPROFILE%\.cache\codex-runtimes\` (any `*\dependencies\python\python.exe`).
- macOS/Linux: `python3 "<plugin>/hooks/kollate.py" connect`

**If Codex asks to allow network / open the browser, that is expected - approve it.** The script then does one of two things; read its output and act:

1. **It prints a sign-in link** (a URL containing `/connect-machine`). This is the good path - it means the script reached the network and is now waiting for sign-in. Show the user that URL as a **clickable link**, prominently, and tell them to open it and click **Connect this machine**. Do not end your turn saying it is done - the sign-in completes in that browser page.
2. **It prints a line beginning `Run it in a terminal instead:`** followed by a full command (with an absolute Python path and, on Windows, a leading `&`). This means Codex would not grant network here. Show the user THAT command exactly and tell them to paste it into a terminal (PowerShell on Windows) and press Enter - it works as-is, nothing to install.

**After it connects (either path), the app must be restarted before it captures.** The tool already running read its plugin and credential at startup, so a fresh connection does not take effect until it reopens. Tell the user, as the last step: fully quit and reopen the app - the **ChatGPT desktop app** must be quit from the **system tray** (Quit, not just closing the window), or start a **new Codex session** - then open a new chat. Without this, connect succeeds but nothing is captured, and `$kollate:status` still says `Connected: NO`. Do not report the task as done until you have told them this.

Never print any token, secret, or id from the output - only the sign-in link or the terminal command. Report in one line what you did.
