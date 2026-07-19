"""Tests for record-antigravity-session-state.py."""
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HOOK_PATH = Path(__file__).resolve().parent.parent / "record-antigravity-session-state.py"
_spec = importlib.util.spec_from_file_location(
    "record_antigravity_session_state", HOOK_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


class HandleEventTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def payload(self, conv="conv-1", workspaces=("/Users/x/proj",)):
        return {"conversationId": conv, "workspacePaths": list(workspaces)}

    def read(self, conv="conv-1"):
        return json.loads((self.state_dir / f"{conv}.json").read_text())

    def test_event_state_mapping(self):
        cases = {"PreInvocation": "running", "Stop": "idle"}
        for event, expected in cases.items():
            with self.subTest(event=event):
                hook.handle_event(event, self.payload(conv=event),
                                  self.state_dir, 100.0, 42)
                r = self.read(conv=event)
                self.assertEqual(r["state"], expected)
                self.assertEqual(r["version"], 1)
                self.assertEqual(r["session_id"], event)
                self.assertEqual(r["cwd"], "/Users/x/proj")
                self.assertEqual(r["pid"], 42)

    def test_unknown_event_ignored(self):
        hook.handle_event("PreToolUse", self.payload(), self.state_dir, 100.0, 42)
        hook.handle_event("SessionStart", self.payload(), self.state_dir, 100.0, 42)
        hook.handle_event("PostToolUse", self.payload(), self.state_dir, 100.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_since_preserved_on_same_state(self):
        hook.handle_event("PreInvocation", self.payload(), self.state_dir, 100.0, 42)
        hook.handle_event("PreInvocation", self.payload(), self.state_dir, 150.0, 42)
        r = self.read()
        self.assertEqual(r["since"], 100.0)
        self.assertEqual(r["updated_at"], 150.0)

    def test_missing_workspace_falls_back_to_previous_cwd(self):
        hook.handle_event("PreInvocation", self.payload(), self.state_dir, 100.0, 42)
        hook.handle_event("Stop", {"conversationId": "conv-1"},
                          self.state_dir, 110.0, 42)
        self.assertEqual(self.read()["cwd"], "/Users/x/proj")

    def test_unsafe_conversation_id_ignored(self):
        hook.handle_event("Stop", self.payload(conv="../evil"),
                          self.state_dir, 100.0, 42)
        hook.handle_event("Stop", self.payload(conv=""), self.state_dir, 100.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])


class MainOutputContractTests(unittest.TestCase):
    def test_main_prints_empty_json_object(self):
        stdin = io.StringIO(json.dumps(
            {"conversationId": "c", "workspacePaths": ["/p"]}))
        out = io.StringIO()
        with mock.patch.object(hook.sys, "argv", ["prog", "Stop"]), \
             mock.patch.object(hook.sys, "stdin", stdin), \
             mock.patch.object(hook.sys, "stdout", out), \
             mock.patch.object(hook, "default_state_dir",
                               return_value=Path(tempfile.mkdtemp())):
            hook.main()
        self.assertEqual(out.getvalue(), "{}")

    def test_main_prints_empty_json_on_bad_stdin(self):
        out = io.StringIO()
        with mock.patch.object(hook.sys, "argv", ["prog", "Stop"]), \
             mock.patch.object(hook.sys, "stdin", io.StringIO("not json")), \
             mock.patch.object(hook.sys, "stdout", out):
            hook.main()
        self.assertEqual(out.getvalue(), "{}")


if __name__ == "__main__":
    unittest.main()
