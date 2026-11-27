# Artifact metadata from transcripts (docs/artifacts-spec.md, section 8).
# Source of truth for the shared fixtures: kollate-product,
# supabase/functions/_shared/artifact-rules.fixtures.json. Keep tests/fixtures/ a verbatim copy;
# the extension (extension/lib/artifacts.ts) and the server are tested against the same file.
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("kollate", ROOT / "plugins" / "kollate" / "hooks" / "kollate.py")
kollate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kollate)
FIXTURES = json.loads((pathlib.Path(__file__).parent / "fixtures" / "artifact-rules.fixtures.json").read_text())


def pairs(case):
    return [(r["seq"], r["record"]) for r in case["records"]]


def tool_use(name, input_, cwd="/Users/d/p", id_="t1"):
    return {"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": id_, "name": name, "input": input_}]}}


def read_body(cmd):
    with open(cmd[cmd.index("--data-binary") + 1][1:]) as handle:
        return json.load(handle)


def say(role, text, cwd="/Users/d/p"):
    return {"type": role, "cwd": cwd, "message": {"role": role, "content": text}}


class SharedFixtures(unittest.TestCase):
    def test_every_fixture_matches_exactly(self):
        for case in FIXTURES:
            with self.subTest(case["name"]):
                self.assertEqual(kollate.artifacts_from(pairs(case), case["turn_seqs"]), case["expected"])

    def test_no_file_bodies(self):
        got = kollate.artifacts_from(pairs(FIXTURES[0]), FIXTURES[0]["turn_seqs"])
        self.assertNotIn("SECRET BODY", json.dumps(got))

    def test_share_key_never_leaves(self):
        case = FIXTURES[2]
        self.assertNotIn("SECRET", json.dumps(kollate.artifacts_from(pairs(case), case["turn_seqs"])))

    def test_items_after_the_last_turn_are_not_returned(self):
        recs = [(1, say("user", "hi")), (2, tool_use("Write", {"file_path": "/Users/d/p/a.md"}))]
        self.assertEqual(kollate.artifacts_from(recs, [1]), [])

    def test_unanswered_artifact_call_is_dropped(self):
        recs = [(1, tool_use("Artifact", {"file_path": "/Users/d/p/x.html"}, id_="x")), (2, say("assistant", "ok"))]
        self.assertEqual(kollate.artifacts_from(recs, [2]), [])

    def test_home_directory_never_sent_outside_the_working_folder(self):
        recs = [(1, tool_use("Write", {"file_path": "/Users/other/secret/plan.md"})), (2, say("assistant", "ok"))]
        got = kollate.artifacts_from(recs, [2])
        self.assertEqual(got[0]["path"], "plan.md")
        self.assertNotIn("/Users/", json.dumps(got))


class CodexPatches(unittest.TestCase):
    def test_patch_headers(self):
        code = ('const patch = "*** Begin Patch\\n*** Add File: /Users/d/p/docs/a.md\\n+x\\n'
                '*** Update File: /Users/d/p/src/b.ts\\n*** Delete File: /Users/d/p/old.csv\\n*** End Patch"')
        rec = {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "input": code}}
        got = kollate.codex_artifacts(rec, "/Users/d/p")
        self.assertEqual([(a["ref"], a["operation"]) for a in got],
                         [("docs/a.md", "created"), ("src/b.ts", "edited"), ("old.csv", "deleted")])
        self.assertTrue(all(a["tool"] == "apply_patch" for a in got))
        self.assertEqual([a.get("file_type") for a in got], ["md", "ts", "csv"])

    def test_real_newlines_and_function_call_arguments(self):
        text = "*** Begin Patch\n*** Add File: /Users/d/p/notes/plan.md\n+body\n*** End Patch\n"
        rec = {"type": "response_item", "payload": {"type": "function_call", "name": "shell",
                                                    "arguments": json.dumps({"input": text})}}
        got = kollate.codex_artifacts(rec, "/Users/d/p")
        self.assertEqual([(a["ref"], a["operation"], a["path"]) for a in got], [("notes/plan.md", "created", "notes/plan.md")])
        self.assertNotIn("body", json.dumps(got))

    def test_relative_patch_path_is_kept_and_outside_path_loses_its_folders(self):
        text = "*** Update File: docs/x.md\n*** Add File: /Users/other/h/y.md\n*** Add File: ../up/z.md\n"
        rec = {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "apply_patch", "input": text}}
        got = kollate.codex_artifacts(rec, "/Users/d/p")
        self.assertEqual([a["ref"] for a in got], ["docs/x.md", "y.md", "z.md"])

    def test_other_records_yield_nothing(self):
        self.assertEqual(kollate.codex_artifacts({"type": "response_item", "payload": {"type": "message", "role": "user",
                         "content": "*** Add File: /a.md"}}, "/"), [])
        self.assertEqual(kollate.codex_artifacts({"type": "event_msg"}, "/"), [])
        self.assertEqual(kollate.codex_artifacts({}, None), [])


class Transcript(unittest.TestCase):
    def write(self, records):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        p = os.path.join(d, "s.jsonl")
        with open(p, "w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        return p

    def test_artifacts_ride_on_the_next_stored_turn(self):
        p = self.write([say("user", "draft it"), tool_use("Write", {"file_path": "/Users/d/p/plan.md", "content": "BODY"}),
                        say("assistant", "done")])
        turns, *_ = kollate.turns_from(p, 0)
        self.assertEqual([t["role"] for t in turns], ["user", "assistant"])
        self.assertNotIn("artifacts", turns[0])
        self.assertEqual([a["ref"] for a in turns[1]["artifacts"]], ["plan.md"])
        self.assertNotIn("BODY", json.dumps(turns))

    def test_trailing_artifacts_attach_to_the_last_turn(self):
        p = self.write([say("user", "go"), say("assistant", "ok"), tool_use("Write", {"file_path": "/Users/d/p/z.md"})])
        turns, *_ = kollate.turns_from(p, 0)
        self.assertEqual([a["ref"] for a in turns[-1]["artifacts"]], ["z.md"])

    def test_published_artifact_link_from_the_tool_result(self):
        result = {"type": "user", "cwd": "/Users/d/p", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "x1", "content": "https://claude.ai/code/artifact/ab-1?sk=SECRET"}]}}
        p = self.write([say("user", "pub"), tool_use("Artifact", {"file_path": "/Users/d/p/r.html"}, id_="x1"), result,
                        say("assistant", "link")])
        turns, *_ = kollate.turns_from(p, 0)
        got = turns[-1]["artifacts"]
        self.assertEqual(got[0]["url"], "https://claude.ai/code/artifact/ab-1")
        self.assertNotIn("SECRET", json.dumps(turns))

    def test_codex_transcript(self):
        meta = {"type": "session_meta", "payload": {"cwd": "/Users/d/p"}}
        patch = {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                 "input": "*** Begin Patch\n*** Add File: /Users/d/p/docs/n.md\n+x\n*** End Patch"}}
        msg = lambda role, t: {"type": "response_item", "payload": {"type": "message", "role": role,
                               "content": [{"type": "output_text" if role == "assistant" else "input_text", "text": t}]}}
        p = self.write([meta, msg("user", "write notes"), patch, msg("assistant", "done")])
        turns, *_ = kollate.turns_from(p, 0)
        self.assertEqual([a["ref"] for a in turns[-1]["artifacts"]], ["docs/n.md"])

    def test_batches_keep_artifacts_and_deliver_lifts_them(self):
        p = self.write([say("user", "go"), tool_use("Write", {"file_path": "/Users/d/p/a.md"}), say("assistant", "ok")])
        turns, *_ = kollate.turns_from(p, 0)
        batch, _end, _cur = next(kollate.batches(turns, 5))
        self.assertEqual(batch[1]["seq"], 6)
        sent = {}

        def fake_run(cmd, **kw):
            sent["body"] = read_body(cmd)
            return mock.Mock(stdout="200")

        creds = {"capture_token": "t", "hook_secret": "s", "api_base": "https://x.test"}
        with mock.patch.object(kollate.subprocess, "run", fake_run):
            self.assertTrue(kollate.deliver("sid", batch, creds))
        body = sent["body"]
        self.assertEqual(body["artifacts"], [{"anchor_seq": 6, "ref": "a.md", "tool": "Write", "operation": "created",
                                              "path": "a.md", "file_type": "md"}])
        self.assertTrue(all("artifacts" not in m for m in body["messages"]))
        self.assertIn("artifacts", batch[1])  # the caller's batch is left as it was

    def test_no_artifacts_means_no_field(self):
        sent = {}

        def fake_run(cmd, **kw):
            sent["body"] = read_body(cmd)
            return mock.Mock(stdout="200")

        creds = {"capture_token": "t", "hook_secret": "s", "api_base": "https://x.test"}
        with mock.patch.object(kollate.subprocess, "run", fake_run):
            kollate.deliver("sid", [{"role": "user", "content": "hi", "seq": 0}], creds)
        self.assertNotIn("artifacts", sent["body"])


if __name__ == "__main__":
    unittest.main()
