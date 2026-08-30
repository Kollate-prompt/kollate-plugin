---
description: Connect this machine to your Kollate account
---
Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" connect` and report the result to the user in one line. EXCEPTION: if the output contains a sign-in link (a URL to visit), show that link to the user prominently and tell them to open it - without it they cannot finish connecting. Never repeat any other value from the output (tokens, secrets, ids).

If `python3` is missing or is the Windows Store stub, run the same command with `python` instead, and if that also fails, with `py -3` (the Windows launcher - present even when Python was installed without updating PATH).
If all three fail on Windows (the output is just "Python", nothing, or the Microsoft Store opens), Python is not really installed - install it yourself, do not send the user away to do it:
`winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements`
then retry the command with `python`. If the new PATH is not picked up yet, tell the user to close this session, open a new one, and run the command again - it will work there.

On Windows `python3` is usually the Microsoft Store stub and fails immediately. If that happens, rerun the same command with `python`, then `py -3`, before reporting any failure to the user.
