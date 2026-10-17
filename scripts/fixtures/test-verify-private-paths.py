#!/usr/bin/env python3
"""verify.sh must write only below its own per-run root (source contract)."""
from pathlib import Path
import sys
import unittest

root = Path(sys.argv.pop(1)).resolve()

class PrivatePathTests(unittest.TestCase):
    def setUp(self):
        self.text = (root / "scripts/verify.sh").read_text()

    def test_no_fixed_output_paths(self):
        self.assertNotIn(">/tmp/", self.text)
        self.assertNotIn(" /tmp/waspflow-", self.text)
        self.assertNotIn(" /tmp/wf-", self.text)

    def test_run_root_is_exported_and_removed_on_success(self):
        self.assertIn('scratch="$(mktemp -d "$scratch_parent/wf-XXXXXX")"', self.text)
        self.assertIn('export WASPFLOW_TEST_TMPDIR="$scratch" TMPDIR="$scratch"', self.text)
        self.assertIn('rm -rf "$scratch"', self.text)

class CleanupBehaviorTests(unittest.TestCase):
    """Run the real cleanup functions from verify.sh with stubbed tmux."""

    def run_cleanup(self, name, status):
        import subprocess, tempfile
        text = (root / "scripts/verify.sh").read_text()
        import re
        body = re.search(r"(?ms)^%s\(\) \{.*?^\}" % name, text).group(0)
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            script = f"""
set -u
parent={parent}
scratch="$parent/wf-run"; mkdir -p "$scratch"
fixture="$scratch/fixture"; state_home="$scratch/state"; tmux_wrapper="$scratch/wrap"
tmux_socket_dir="$parent/socket"; mkdir -p "$fixture" "$state_home" "$tmux_wrapper" "$tmux_socket_dir"
touch "$parent/sibling" "$state_home/evidence"
verify_tmux() {{ :; }}
failure_line=1; failure_command=x; WASPFLOW_TMUX_SESSION=s
{body}
(exit {status}); {name}
"""
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            return (parent / "sibling").exists(), (parent / "wf-run").exists(), \
                (parent / "wf-run/state/evidence").exists(), (parent / "socket").exists()

    def test_cleanup_removes_run_root_on_success_only(self):
        for name in ("cleanup", "early_cleanup"):
            with self.subTest(name=name, status=0):
                sibling, root_exists, evidence, _ = self.run_cleanup(name, 0)
                self.assertTrue(sibling)
                self.assertFalse(root_exists)
            with self.subTest(name=name, status=1):
                sibling, root_exists, evidence, _ = self.run_cleanup(name, 1)
                self.assertTrue(sibling)
                self.assertTrue(root_exists)
                self.assertTrue(evidence)

if __name__ == "__main__":
    unittest.main()
