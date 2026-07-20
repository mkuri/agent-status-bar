"""End-to-end tests for setup.sh, driven against a sandboxed HOME.

Each test runs the installer via bash with HOME pointed at a throwaway temp dir,
so nothing touches the real user config. Requires bash + python3 on PATH.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SETUP = Path(__file__).resolve().parent.parent / "setup.sh"
NINE = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "Notification", "SessionEnd"]
CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "PermissionRequest",
                "PostToolUse", "Stop"]


def run(home, answers):
    """Run setup.sh with HOME=home, feeding `answers` (e.g. "y\\nn\\n") on stdin."""
    return subprocess.run(
        ["bash", str(SETUP)],
        input=answers, capture_output=True, text=True,
        env={**os.environ, "HOME": home}, timeout=30,
    )


class SetupTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def claude_settings(self):
        return Path(self.home) / ".claude" / "settings.json"

    def load(self, path):
        return json.loads(Path(path).read_text())

    def codex_hooks(self):
        return Path(self.home) / ".codex" / "hooks.json"

    def test_fresh_install_writes_nine_events(self):
        run(self.home, "y\nn\n")  # Claude yes, agy no
        d = self.load(self.claude_settings())
        self.assertEqual(sorted(d["hooks"]), sorted(NINE))
        self.assertEqual(d["hooks"]["Notification"][0]["matcher"], "idle_prompt")
        stop = d["hooks"]["Stop"][0]["hooks"][0]
        self.assertEqual(stop["timeout"], 5)
        self.assertTrue(stop["command"].endswith('record-session-state.py"'))

    def test_idempotent_no_duplicate_no_new_backup(self):
        run(self.home, "y\nn\n")
        settings = self.claude_settings()
        baks = lambda: sorted(settings.parent.glob("settings.json.bak.*"))
        before = baks()
        result = run(self.home, "y\nn\n")
        self.assertIn("no change", result.stdout)
        self.assertEqual(baks(), before)  # no-op writes no new backup
        stop = self.load(settings)["hooks"]["Stop"]
        recs = [h for e in stop for h in e.get("hooks", [])
                if h.get("command", "").endswith('record-session-state.py"')]
        self.assertEqual(len(recs), 1)  # not duplicated

    def _symlinked_claude(self):
        """Return (real_target_path) with ~/.claude/settings.json a symlink to it."""
        real = Path(self.home) / "dot" / "settings.json"
        real.parent.mkdir(parents=True)
        real.write_text('{"other": 1}')
        link = self.claude_settings()
        link.parent.mkdir(parents=True)
        os.symlink(real, link)
        return real, link

    def test_symlinked_config_edited_on_confirm(self):
        real, link = self._symlinked_claude()
        run(self.home, "y\ny\nn\n")  # Claude yes, edit-target yes, agy no
        d = self.load(real)
        self.assertEqual(sorted(d["hooks"]), sorted(NINE))
        self.assertEqual(d["other"], 1)          # unrelated key preserved
        self.assertTrue(link.is_symlink())        # symlink not replaced by a real file

    def test_symlinked_config_untouched_on_decline(self):
        real, _ = self._symlinked_claude()
        result = run(self.home, "y\nn\nn\n")  # Claude yes, edit-target NO, agy no
        # resolve diagnostics go to stderr (stdout stays clean for capture)
        self.assertIn("is a symlink ->", result.stdout + result.stderr)
        self.assertEqual(self.load(real), {"other": 1})  # unchanged

    def test_continues_after_symlink_decline(self):
        # Declining the symlink edit must SKIP Claude and fall through to the
        # agy prompt + Done footer, not abort the installer under `set -e`.
        self._symlinked_claude()
        # Claude yes, decline edit, agy yes (agy config is a fresh plain file).
        result = run(self.home, "y\nn\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Done.", result.stdout)  # reached the footer
        agy = Path(self.home) / ".gemini" / "config" / "hooks.json"
        group = self.load(agy)["record-session-state"]
        self.assertEqual(set(group), {"PreInvocation", "Stop"})  # agy still ran

    def test_dangling_symlink_skipped(self):
        link = self.claude_settings()
        link.parent.mkdir(parents=True)
        missing = Path(self.home) / "does-not-exist.json"
        os.symlink(missing, link)
        result = run(self.home, "y\nn\n")
        self.assertIn("symlink to a missing target", result.stdout + result.stderr)
        self.assertFalse(missing.exists())  # no phantom target created

    def test_home_relative_command_when_recorder_under_home(self):
        # When the recorder lives under $HOME, the emitted hook command uses a
        # literal $HOME prefix (shorter, no username, portable) instead of an
        # absolute path. Run a copy of setup.sh placed under the sandbox HOME so
        # RECORDER_DIR resolves inside it.
        recdir = Path(self.home) / "projects" / "asb" / "session-state-recorder"
        recdir.mkdir(parents=True)
        setup_copy = recdir / "setup.sh"
        setup_copy.write_text(SETUP.read_text())
        setup_copy.chmod(0o755)
        subprocess.run(
            ["bash", str(setup_copy)], input="y\ny\ny\n",
            capture_output=True, text=True,
            env={**os.environ, "HOME": self.home}, timeout=30,
        )
        base = "$HOME/projects/asb/session-state-recorder"
        claude_cmd = self.load(self.claude_settings())["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(claude_cmd, 'python3 "%s/record-session-state.py"' % base)
        agy = Path(self.home) / ".gemini" / "config" / "hooks.json"
        agy_cmd = self.load(agy)["record-session-state"]["Stop"][0]["command"]
        self.assertEqual(
            agy_cmd, 'python3 "%s/record-antigravity-session-state.py" Stop' % base)
        codex = self.load(Path(self.home) / ".codex" / "hooks.json")
        codex_cmd = codex["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(codex_cmd, 'python3 "%s/record-codex-session-state.py"' % base)

    def test_absolute_command_when_recorder_outside_home(self):
        # The real repo checkout lives outside the sandbox HOME, so the emitted
        # command falls back to a literal absolute path (no $HOME rewrite).
        run(self.home, "y\nn\n")
        cmd = self.load(self.claude_settings())["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertNotIn("$HOME", cmd)
        self.assertTrue(cmd.startswith('python3 "/'))

    def test_agy_symlinked_config_edited_on_confirm(self):
        real = Path(self.home) / "dot" / "hooks.json"
        real.parent.mkdir(parents=True)
        real.write_text("{}")
        link = Path(self.home) / ".gemini" / "config" / "hooks.json"
        link.parent.mkdir(parents=True)
        os.symlink(real, link)
        run(self.home, "n\ny\ny\n")  # Claude no, agy yes, edit-target yes
        group = self.load(real)["record-session-state"]
        self.assertEqual(set(group), {"PreInvocation", "Stop"})
        self.assertTrue(group["Stop"][0]["command"].endswith(
            'record-antigravity-session-state.py" Stop'))

    def test_codex_fresh_install_writes_five_events(self):
        result = run(self.home, "n\nn\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        hooks = self.load(self.codex_hooks())["hooks"]
        self.assertEqual(sorted(hooks), sorted(CODEX_EVENTS))
        stop = hooks["Stop"][0]["hooks"][0]
        self.assertEqual(stop["timeout"], 5)
        self.assertTrue(stop["command"].endswith('record-codex-session-state.py"'))

    def test_codex_install_is_idempotent_and_preserves_other_keys(self):
        hooks_path = self.codex_hooks()
        hooks_path.parent.mkdir(parents=True)
        hooks_path.write_text('{"description": "personal hooks"}')
        run(self.home, "n\nn\ny\n")
        before = sorted(hooks_path.parent.glob("hooks.json.bak.*"))
        result = run(self.home, "n\nn\ny\n")
        self.assertIn("no change", result.stdout)
        self.assertEqual(sorted(hooks_path.parent.glob("hooks.json.bak.*")), before)
        data = self.load(hooks_path)
        self.assertEqual(data["description"], "personal hooks")
        recorders = [
            handler
            for entry in data["hooks"]["Stop"]
            for handler in entry.get("hooks", [])
            if handler.get("command", "").endswith('record-codex-session-state.py"')
        ]
        self.assertEqual(len(recorders), 1)


if __name__ == "__main__":
    unittest.main()
