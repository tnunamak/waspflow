import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

root = pathlib.Path(sys.argv[1])

class LiveHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.repo = self.base / "repo"
        for part in ("scripts", "bin", "lib/providers", "scratch"):
            (self.repo / part).mkdir(parents=True)
        (self.repo / "lib/core.sh").write_text("")
        (self.repo / "lib/providers/claude.sh").write_text("claude_turn_mark() { echo 1; }\n")
        for name in ("live-smoke.sh", "live-soak.sh"):
            shutil.copyfile(root / "scripts" / name, self.repo / "scripts" / name)
        fake = self.repo / "bin/waspflow"
        fake.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys
cmd, args = sys.argv[1], sys.argv[2:]
record = pathlib.Path(os.environ["CALLS"])
with record.open("a") as f: f.write(json.dumps([cmd, args]) + "\n")
state = pathlib.Path(os.environ["FAKE_STATE"]); state.mkdir(exist_ok=True)
mode = os.environ.get("MODE", "ok")
if cmd == "spawn":
    lane = args[args.index("--lane") + 1]
    if mode == "spawnfail": sys.exit(1)
    (state / lane).write_text(os.getcwd())
    if mode != "noedit":
        match = re.search(r"TOKEN_A_\d+|T\d+_A", " ".join(args))
        with pathlib.Path("f.txt").open("a") as f: f.write(match.group() + "\n")
elif cmd == "status": print('{"spawn_submitted":true}')
elif cmd == "wait" and mode == "timeout": sys.exit(1)
elif cmd == "revise" and mode != "noedit":
    match = re.search(r"TOKEN_B_\d+|T\d+_B", " ".join(args))
    with (pathlib.Path((state / args[0]).read_text()) / "f.txt").open("a") as f: f.write(match.group() + "\n")
elif cmd == "reap": print("result=succeeded")
''')
        fake.chmod(0o755)
        monitor = self.repo / "bin/clawmeter"
        monitor.write_text("#!/usr/bin/env bash\nexit 0\n")
        monitor.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.repo / "bin") + os.pathsep + os.environ["PATH"], "WASPFLOW_TEST_TMPDIR": str(self.repo / "scratch"),
                    "WASPFLOW_HOME": str(self.base / "home"), "FAKE_STATE": str(self.base / "state"),
                    "CALLS": str(self.base / "calls")}

    def run_harness(self, name, args, mode="ok", drop_workers=False):
        script = self.repo / "scripts" / name
        if drop_workers:
            text = script.read_text().replace('pids=(); n=0', 'one() { return 9; }\npids=(); n=0')
            script.write_text(text)
        return subprocess.run(["bash", str(script), *args], env={**self.env, "MODE": mode},
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [__import__("json").loads(line) for line in pathlib.Path(self.env["CALLS"]).read_text().splitlines()]

    def test_smoke_failure_exit(self):
        self.assertNotEqual(self.run_harness("live-smoke.sh", ["claude", "1"], "noedit").returncode, 0)

    def test_soak_failure_exit(self):
        self.assertNotEqual(self.run_harness("live-soak.sh", ["1"], "noedit").returncode, 0)

    def test_missing_soak_workers(self):
        result = self.run_harness("live-soak.sh", ["1"], drop_workers=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("LIVE SOAK: GREEN", result.stdout)

    def test_ten_smoke_lanes(self):
        result = self.run_harness("live-smoke.sh", ["claude", "10"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("CROSS-CONTAMINATED", result.stdout)

    def test_timeout_cleanup_receipt(self):
        result = self.run_harness("live-smoke.sh", ["claude", "1"], "timeout")
        self.assertIn("SPAWN_WAIT_TIMEOUT", result.stdout)
        self.assertEqual(list((self.repo / "scratch").glob("wf-live-1-*")), [])

    def test_run_unique_labels(self):
        for _ in range(2): self.run_harness("live-smoke.sh", ["claude", "1"])
        labels = [args[args.index("--lane") + 1] for cmd, args in self.calls() if cmd == "spawn"]
        self.assertEqual(len(set(labels)), 2, labels)

    def test_failed_spawn_stops_lifecycle(self):
        self.run_harness("live-smoke.sh", ["claude", "1"], "spawnfail")
        self.assertEqual([cmd for cmd, _ in self.calls()], ["spawn"])

sys.argv = [sys.argv[0]]
unittest.main()
