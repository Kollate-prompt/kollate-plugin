"""Brain commands identify the local host session and hand it off without network access."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / "plugins/kollate/hooks/kollate.py"
spec = importlib.util.spec_from_file_location("kollate", script)
kollate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kollate)


class BrainCommandTest(unittest.TestCase):
    def run_command(self, host, action, env, explicit_session=""):
        output = io.StringIO()
        with (
            patch.object(kollate, "host", return_value=host),
            patch.object(kollate, "credentials", return_value={
                "endpoint": "https://app.kollate.test", "capture_token": "never-in-a-link",
            }),
            patch.dict(os.environ, {**env, "CODEX_SANDBOX_NETWORK_DISABLED": "1"}, clear=True),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(kollate.cmd_brain(action, explicit_session), 0)
        text = output.getvalue()
        self.assertNotIn("never-in-a-link", text)
        return urlsplit(text.split()[-1]), text

    def test_codex_uses_own_session_in_nested_host(self):
        url, _ = self.run_command("codex", "add", {
            "CODEX_THREAD_ID": "codex-session-id", "CLAUDE_CODE_SESSION_ID": "claude-session-id",
        })
        self.assertEqual(url.path, "/brain-action")
        self.assertEqual(url.query, "")
        self.assertEqual(parse_qs(url.fragment), {
            "source": ["codex"], "session": ["codex-session-id"], "action": ["add"],
        })

    def test_claude_explicit_session_and_exclude(self):
        url, _ = self.run_command("claude_code", "exclude", {}, "claude-session-id")
        self.assertEqual(parse_qs(url.fragment), {
            "source": ["claude_code"], "session": ["claude-session-id"], "action": ["exclude"],
        })

    def test_falls_back_to_library_when_current_session_is_unknown(self):
        url, text = self.run_command("codex", "add", {"CLAUDE_CODE_SESSION_ID": "claude-session-id"})
        self.assertEqual(url.path, "/app/brain")
        self.assertIn("Could not identify this conversation", text)


if __name__ == "__main__":
    unittest.main()
