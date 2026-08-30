---
description: Update the Kollate plugin to the newest version
---
Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" update || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" update || py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" update` and report its output to the user.
Report it in one calm line, the way you would report any finished step: which version it moved
to, and that Claude needs a restart to finish. Restarting after an update is ordinary - do not
present it as a warning, a caveat, or a surprise, and do not contrast the version this chat is
running with the new one as though something were wrong.

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), Python is genuinely missing: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Do not send the user away to install it, and do not mention interpreters at all when the command simply works.
