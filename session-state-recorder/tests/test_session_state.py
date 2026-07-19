"""Tests for the shared session_state helper."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parent.parent / "session_state.py"
_spec = importlib.util.spec_from_file_location("session_state", MODULE_PATH)
session_state = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(session_state)


class WriteStateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def read(self, session_id="abc123"):
        return json.loads((self.state_dir / f"{session_id}.json").read_text())

    def test_writes_versioned_record(self):
        session_state.write_state(self.state_dir, "abc123", "running",
                                  "/tmp/proj", 42, 100.0)
        self.assertEqual(self.read(), {
            "version": 1, "session_id": "abc123", "state": "running",
            "since": 100.0, "cwd": "/tmp/proj", "pid": 42, "updated_at": 100.0})

    def test_since_preserved_on_same_state(self):
        session_state.write_state(self.state_dir, "abc123", "running", "/p", 42, 100.0)
        session_state.write_state(self.state_dir, "abc123", "running", "/p", 42, 150.0)
        r = self.read()
        self.assertEqual(r["since"], 100.0)
        self.assertEqual(r["updated_at"], 150.0)

    def test_since_resets_on_state_change(self):
        session_state.write_state(self.state_dir, "abc123", "running", "/p", 42, 100.0)
        session_state.write_state(self.state_dir, "abc123", "idle", "/p", 42, 160.0)
        self.assertEqual(self.read()["since"], 160.0)

    def test_empty_cwd_falls_back_to_previous(self):
        session_state.write_state(self.state_dir, "abc123", "running", "/tmp/proj", 42, 100.0)
        session_state.write_state(self.state_dir, "abc123", "idle", "", 42, 110.0)
        self.assertEqual(self.read()["cwd"], "/tmp/proj")

    def test_corrupt_existing_file_recovered(self):
        (self.state_dir / "abc123.json").write_text("{not json")
        session_state.write_state(self.state_dir, "abc123", "idle", "/p", 42, 100.0)
        self.assertEqual(self.read()["state"], "idle")

    def test_unsafe_session_id_ignored(self):
        for bad in ("../evil", "", ".hidden", "a/b"):
            with self.subTest(session_id=bad):
                session_state.write_state(self.state_dir, bad, "idle", "/p", 42, 100.0)
        self.assertEqual(list(self.state_dir.iterdir()), [])


class DeleteStateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_deletes_existing(self):
        session_state.write_state(self.state_dir, "abc123", "idle", "/p", 42, 100.0)
        session_state.delete_state(self.state_dir, "abc123")
        self.assertFalse((self.state_dir / "abc123.json").exists())

    def test_missing_is_noop(self):
        session_state.delete_state(self.state_dir, "abc123")
        self.assertEqual(list(self.state_dir.iterdir()), [])


class ResolveAgentPidTests(unittest.TestCase):
    def _fake_ps(self, table):
        """table: pid -> (ppid, comm). Mimics `ps -o ppid=,comm= -p PID`."""
        def fake_run(cmd, **kwargs):
            pid = int(cmd[-1])
            ppid, comm = table[pid]
            return mock.Mock(stdout=f"{ppid} {comm}\n")
        return fake_run

    def test_direct_parent_is_agent(self):
        with mock.patch.object(session_state.subprocess, "run",
                               self._fake_ps({10: (1, "claude")})):
            self.assertEqual(session_state.resolve_agent_pid(10), 10)

    def test_skips_shell_wrapper(self):
        table = {10: (9, "/bin/sh"), 9: (1, "agy")}
        with mock.patch.object(session_state.subprocess, "run", self._fake_ps(table)):
            self.assertEqual(session_state.resolve_agent_pid(10), 9)

    def test_ps_failure_returns_input(self):
        with mock.patch.object(session_state.subprocess, "run", side_effect=OSError):
            self.assertEqual(session_state.resolve_agent_pid(10), 10)


if __name__ == "__main__":
    unittest.main()
