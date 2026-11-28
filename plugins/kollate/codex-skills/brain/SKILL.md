---
name: brain
description: Add the current saved conversation to a Kollate brain
---
Run the bundle's `hooks/kollate.py` with the single argument `brain`. The script is two folders up from this SKILL.md, then under `hooks/`. On macOS/Linux use `python3` and the absolute script path. On Windows use the bundled interpreter at `%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`, or the newest matching interpreter under `%USERPROFILE%\.cache\codex-runtimes`.

Show the returned link as a clickable link. The signed-in chooser lets the user choose the brain and confirm the action. If the script reports that the session cannot be identified, show its instructions.
