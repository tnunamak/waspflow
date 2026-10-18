#!/usr/bin/env python3
"""Narrow source contract checks; actual Actions integration is still required."""
from pathlib import Path
import sys
import unittest

root = Path(sys.argv.pop(1)).resolve()

class WorkflowTests(unittest.TestCase):
    def test_verify_runs_once(self):
        ci = (root / ".github/workflows/ci.yml").read_text()
        release = (root / ".github/workflows/release.yml").read_text()
        self.assertEqual(ci.count("run: bash scripts/verify.sh"), 1)
        self.assertNotIn("run: bash scripts/verify.sh", release)
        self.assertIn("  pull_request:\n", ci)
        self.assertIn("  push:\n    branches:\n      - main\n", ci)
        self.assertIn("  workflow_call:\n", release)
        self.assertNotIn("  push:\n", release)
        self.assertIn("    needs: verify\n", ci)
        self.assertIn("    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n", ci)
        self.assertIn("    uses: ./.github/workflows/release.yml\n", ci)
        self.assertIn("          ref: ${{ github.sha }}\n", release)
        self.assertNotIn("always()", ci)
        self.assertNotIn("continue-on-error", ci)

if __name__ == "__main__":
    unittest.main()
