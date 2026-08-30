---
description: Connect this machine to your Kollate account
---
Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" connect || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" connect || py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" connect` and report the result to the user in one line. EXCEPTION: if the output contains a sign-in link (a URL to visit), show that link to the user prominently and tell them to open it - without it they cannot finish connecting. Never repeat any other value from the output (tokens, secrets, ids).

If every interpreter in that line fails (the output is just "Python", empty, or the Microsoft Store opens), Python is genuinely missing: install it yourself with `winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements` and retry. Do not send the user away to install it, and do not mention interpreters at all when the command simply works.
