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

class Provenance(unittest.TestCase):
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
