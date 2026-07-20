"""Tests for record-codex-session-state.py."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HOOK_PATH = Path(__file__).resolve().parent.parent / "record-codex-session-state.py"
_spec = importlib.util.spec_from_file_location("record_codex_session_state", HOOK_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


class HandleEventTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def event(self, name, session_id="codex-123", **extra):
        return {"hook_event_name": name, "session_id": session_id,
                "cwd": "/tmp/proj", "turn_id": "turn-1", **extra}

    def read(self, session_id="codex-123"):
        return json.loads((self.state_dir / f"{session_id}.json").read_text())

    def test_event_state_mapping(self):
        cases = {
            "SessionStart": "idle",
            "UserPromptSubmit": "running",
            "PermissionRequest": "permission",
            "PostToolUse": "running",
            "Stop": "idle",
        }
        for name, expected in cases.items():
            with self.subTest(event=name):
                hook.handle_event(self.event(name, session_id=name),
                                  self.state_dir, 100.0, 42)
                record = self.read(name)
                self.assertEqual(record["state"], expected)
                self.assertEqual(record["version"], 1)
                self.assertEqual(record["pid"], 42)
                self.assertEqual(record["cwd"], "/tmp/proj")

    def test_same_state_preserves_since(self):
        hook.handle_event(self.event("UserPromptSubmit"), self.state_dir, 100.0, 42)
        hook.handle_event(self.event("PostToolUse"), self.state_dir, 150.0, 42)
        record = self.read()
        self.assertEqual(record["since"], 100.0)
        self.assertEqual(record["updated_at"], 150.0)

    def test_unknown_event_is_ignored(self):
        hook.handle_event(self.event("PreCompact"), self.state_dir, 100.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_unsafe_session_id_is_ignored(self):
        hook.handle_event(self.event("Stop", session_id="../evil"),
                          self.state_dir, 100.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_missing_cwd_falls_back_to_previous(self):
        hook.handle_event(self.event("UserPromptSubmit"), self.state_dir, 100.0, 42)
        payload = {"hook_event_name": "Stop", "session_id": "codex-123"}
        hook.handle_event(payload, self.state_dir, 110.0, 42)
        self.assertEqual(self.read()["cwd"], "/tmp/proj")


if __name__ == "__main__":
    unittest.main()
