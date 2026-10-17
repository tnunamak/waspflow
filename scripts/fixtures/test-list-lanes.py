#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
root = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("generator", root / "scripts/fixtures/generate-list-lanes.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

class GeneratorTests(unittest.TestCase):
    def test_all_records_match_legacy_jq_schema(self):
        # Full count and every pathname/value; jq oracle runs once per mode,
        # separately from the production generator's one-process contract.
        for mode, count in (("index", 1600), ("batch", 240), ("table", 240)):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                generator.generate(mode, home)
                prefix = {"index": "idx", "batch": "batch", "table": "table"}[mode]
                paths = sorted((home / "lanes").glob("*/state.json"))
                self.assertEqual(len(paths), count)
                expression = {
                    "index": '{provider:"codex",status:"reaped",rollout:$p,cwd:"/fixture",runtime_model:"stored-model",runtime_refresh_state:"observed"}',
                    "batch": '{provider:"codex",status:"reaped",cwd:$cwd,runtime_model:"saved"}',
                    "table": '{provider:"codex",status:"reaped",cwd:$cwd}',
                }[mode]
                reference = json.loads(subprocess.check_output(
                    ["jq", "-n", "--arg", "p", "POISON", "--arg", "cwd", "CWD", expression],
                    text=True))
                for i, path in enumerate(paths, 1):
                    lane = f"{prefix}-{i:04d}"
                    self.assertEqual(path.parent.name, lane)
                    expected = dict(reference)
                    if mode == "index":
                        expected["rollout"] = str(home / "provider-log-must-not-be-read" / (lane + ".jsonl"))
                    else:
                        expected["cwd"] = f"/fixture/{i}"
                    self.assertEqual(json.loads(path.read_text()), expected)
                self.assertFalse((home / "provider-log-must-not-be-read").exists())

if __name__ == "__main__":
    unittest.main()
