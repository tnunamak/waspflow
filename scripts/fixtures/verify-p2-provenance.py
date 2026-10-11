import importlib.util
import json
import tempfile
import pathlib
import sys
import unittest
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, root / "scripts" / filename)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m
m = load("provenance", "waspflow-provenance.py")
b = load("backfill", "provenance-backfill.py")

class Provenance(unittest.TestCase):
    def test_invocation_matching(self):
        for module in (m, b):
            for command in (
                "waspflow spawn --lane target -- task",
                '/repo/bin/waspflow spawn --lane=target -- "task"',
                "waspflow spawn \\\n  --lane target -- task",
                "WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --lane target -- task",
                "A=1 B=value waspflow spawn --lane=target -- task",
                'A="literal value" waspflow spawn --lane target -- task',
            ):
                self.assertTrue(module.lane_argument(command, "target"), command)
            for command in (
                "printf '%s' 'waspflow spawn --lane target -- task'",
                "# waspflow spawn --lane target",
                "false && waspflow spawn --lane target",
                "waspflow spawn --lane other -- 'waspflow spawn --lane target'",
                "echo spawn; echo --lane target",
                "bash -c 'waspflow spawn --lane target'",
                "waspflow spawn --lane target -- task\nwaspflow wait target",
                "'waspflow spawn \\\n --lane target'",
                '"A=1" waspflow spawn --lane target -- task',
                "'A=1' waspflow spawn --lane target -- task",
            ):
                self.assertFalse(module.lane_argument(command, "target"), command)

    def test_empty_roots_do_not_search(self):
        with patch.object(m, "checked_run", side_effect=AssertionError("unintended scan")), patch.object(m, "run", side_effect=AssertionError("unintended scan")):
            self.assertEqual(m.candidate_occurrences(["target"], []), ({}, None))
            self.assertEqual(m.fixed_occurrences("target", []), {})

    def test_rollout_identity(self):
        sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / ("rollout-2026-10-07-" + sid + ".jsonl")
            path.write_text(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"waspflow spawn --lane target -- task"}}]}}) + "\n")
            hits, _ = m.scan_spawns({str(path):[0]}, {"target":{}}, {}, 60, False)
            self.assertEqual(hits["target"][0]["root_session_id"], sid)

sys.argv = [sys.argv[0]]
unittest.main()
