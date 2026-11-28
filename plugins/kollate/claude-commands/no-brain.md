---
description: Exclude the current saved conversation from one Kollate brain
---
Run the bundled script with the current Claude Code session ID, never a user-supplied argument:
`py -3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" no-brain "${CLAUDE_SESSION_ID}" || python3 "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" no-brain "${CLAUDE_SESSION_ID}" || python "${CLAUDE_PLUGIN_ROOT}/hooks/kollate.py" no-brain "${CLAUDE_SESSION_ID}"`

Show the returned link as a clickable link. The signed-in chooser lets the user choose the brain and confirm the exclusion. If the script reports that the session cannot be identified, show its instructions.
