"""Tests for record-session-state.py (kebab-case name, loaded via importlib)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HOOK_PATH = Path(__file__).resolve().parent.parent / "record-session-state.py"
_spec = importlib.util.spec_from_file_location("record_session_state", HOOK_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


class HandleEventTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def event(self, name, session_id="abc123", **extra):
        return {"hook_event_name": name, "session_id": session_id,
                "cwd": "/tmp/proj", **extra}

    def read(self, session_id="abc123"):
        return json.loads((self.state_dir / f"{session_id}.json").read_text())

    def test_event_state_mapping(self):
        cases = {
            "SessionStart": "idle",
            "UserPromptSubmit": "running",
            "PermissionRequest": "permission",
            "PostToolUse": "running",
            "PostToolUseFailure": "running",
            "Stop": "idle",
            "StopFailure": "idle",
            "Notification": "idle",
        }
        for name, expected in cases.items():
            with self.subTest(event=name):
                hook.handle_event(self.event(name, session_id=name),
                                  self.state_dir, 100.0, 42)
                record = self.read(session_id=name)
                self.assertEqual(record["state"], expected)
                self.assertEqual(record["version"], 1)
                self.assertEqual(record["pid"], 42)
                self.assertEqual(record["cwd"], "/tmp/proj")
                self.assertEqual(record["since"], 100.0)
                self.assertEqual(record["updated_at"], 100.0)

    def test_since_preserved_on_same_state(self):
        hook.handle_event(self.event("UserPromptSubmit"), self.state_dir, 100.0, 42)
        hook.handle_event(self.event("PostToolUse"), self.state_dir, 150.0, 42)
        record = self.read()
        self.assertEqual(record["since"], 100.0)
        self.assertEqual(record["updated_at"], 150.0)

    def test_since_resets_on_state_change(self):
        hook.handle_event(self.event("UserPromptSubmit"), self.state_dir, 100.0, 42)
        hook.handle_event(self.event("Stop"), self.state_dir, 160.0, 42)
        self.assertEqual(self.read()["since"], 160.0)

    def test_session_end_deletes_file(self):
        hook.handle_event(self.event("Stop"), self.state_dir, 100.0, 42)
        hook.handle_event(self.event("SessionEnd"), self.state_dir, 110.0, 42)
        self.assertFalse((self.state_dir / "abc123.json").exists())

    def test_session_end_without_file_is_noop(self):
        hook.handle_event(self.event("SessionEnd"), self.state_dir, 110.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_unknown_event_ignored(self):
        hook.handle_event(self.event("PreCompact"), self.state_dir, 100.0, 42)
        self.assertFalse((self.state_dir / "abc123.json").exists())

    def test_unsafe_session_id_ignored(self):
        for bad in ("../evil", "", ".hidden", "a/b"):
            with self.subTest(session_id=bad):
                hook.handle_event(self.event("Stop", session_id=bad),
                                  self.state_dir, 100.0, 42)
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_corrupt_existing_file_recovered(self):
        (self.state_dir / "abc123.json").write_text("{not json")
        hook.handle_event(self.event("Stop"), self.state_dir, 100.0, 42)
        self.assertEqual(self.read()["state"], "idle")

    def test_missing_cwd_falls_back_to_previous(self):
        hook.handle_event(self.event("UserPromptSubmit"), self.state_dir, 100.0, 42)
        payload = {"hook_event_name": "Stop", "session_id": "abc123"}
        hook.handle_event(payload, self.state_dir, 110.0, 42)
        self.assertEqual(self.read()["cwd"], "/tmp/proj")


if __name__ == "__main__":
    unittest.main()
