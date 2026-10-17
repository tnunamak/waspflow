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
        self.assertNotIn("$HOME/.tmp/wf-", self.text)

    def test_run_root_is_exported_and_removed_on_success(self):
        self.assertIn('scratch="$(mktemp -d "$scratch_parent/wf-XXXXXX")"', self.text)
        self.assertIn('export WASPFLOW_TEST_TMPDIR="$scratch" TMPDIR="$scratch"', self.text)
        self.assertIn('rm -rf "$scratch"', self.text)

if __name__ == "__main__":
    unittest.main()
