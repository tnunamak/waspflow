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
    (state / lane).write_text(os.getcwd())
    if mode == "spawnfail": sys.exit(1)
    if mode != "noedit":
        match = re.search(r"TOKEN_A_[\w-]+|T[\w-]+_A", " ".join(args))
        token = match.group()
        if mode == "stale":
            previous = state / ("first-" + lane.rsplit("-", 1)[-1])
            if previous.exists(): token = previous.read_text()
            else: previous.write_text(token)
        extra = ""
        if mode in ("foreignrun", "foreignrun_lane10"):
            suffix = "10" if mode == "foreignrun_lane10" else ("2" if lane.rsplit("-", 1)[-1] == "1" else "1")
            if token.startswith("TOKEN_A_"):
                extra = " TOKEN_A_wf-live-run-OLD123_" + suffix
            else:
                extra = " Tsoak-res-OLD123-" + suffix + "_A"
        with pathlib.Path("f.txt").open("a") as f: f.write(token + extra)
elif cmd == "status": print('{"spawn_submitted":true}')
elif cmd == "wait":
    counter = state / (args[0] + ".waits")
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if mode == "timeout" or (mode == "secondtimeout" and count == 2): sys.exit(1)
elif cmd == "revise" and mode != "noedit":
    match = re.search(r"TOKEN_B_[\w-]+|T[\w-]+_B", " ".join(args))
    with (pathlib.Path((state / args[0]).read_text()) / "f.txt").open("a") as f: f.write(match.group() + "\n")
    if mode == "revisefail": sys.exit(1)
elif cmd == "reap":
    workdir = state / args[0]
    if workdir.exists(): (state / (args[0] + ".reapdir")).write_text(str(pathlib.Path(workdir.read_text()).is_dir()))
    print("result=succeeded")
    if mode == "reapfail": sys.exit(1)
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
            text = script.read_text().replace('pids=(); n=0', 'one() { return 0; }\npids=(); n=0')
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
        self.assertIn("expected 3 distinct worker results; got 0", result.stdout)
        self.assertNotIn("LIVE SOAK: GREEN", result.stdout)

    def test_ten_smoke_lanes(self):
        result = self.run_harness("live-smoke.sh", ["claude", "10"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("CROSS-CONTAMINATED", result.stdout)

    def test_twelve_soak_lanes(self):
        result = self.run_harness("live-soak.sh", ["4"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"soak-.*-12")
        self.assertNotIn("DIRTY", result.stdout)

    def test_timeout_cleanup_receipt(self):
        result = self.run_harness("live-smoke.sh", ["claude", "1"], "timeout")
        self.assertIn("SPAWN_WAIT_TIMEOUT", result.stdout)
        self.assertEqual(list((self.repo / "scratch").glob("wf-live-1-*")), [])

    def test_soak_failed_lifecycle_commands(self):
        for mode in ("timeout", "secondtimeout", "revisefail"):
            with self.subTest(mode=mode):
                result = self.run_harness("live-soak.sh", ["1"], mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("LIVE SOAK: GREEN", result.stdout)
                self.assertEqual(list((self.repo / "scratch").glob("soak-soak-*")), [])
                self.assertEqual(len([cmd for cmd, _ in self.calls() if cmd == "reap"]), 3)
                pathlib.Path(self.env["CALLS"]).unlink()

    def test_smoke_failed_revision_commands(self):
        for mode in ("secondtimeout", "revisefail"):
            with self.subTest(mode=mode):
                result = self.run_harness("live-smoke.sh", ["claude", "1"], mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("LIVE MATRIX: GREEN", result.stdout)
                self.assertEqual(list((self.repo / "scratch").glob("wf-live-1-*")), [])
                self.assertIn("reap", [cmd for cmd, _ in self.calls()])
                pathlib.Path(self.env["CALLS"]).unlink()

    def test_failed_reap_never_reports_success_or_deletes_worker_directory(self):
        for script, args, pattern in (("live-smoke.sh", ["claude", "1"], "wf-live-1-*"),
                                       ("live-soak.sh", ["1"], "soak-soak-*")):
            with self.subTest(script=script):
                result = self.run_harness(script, args, "reapfail")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("GREEN", result.stdout)
                self.assertTrue(list((self.repo / "scratch").glob(pattern)), result.stdout)

    def test_previous_run_edit_tokens_cannot_satisfy_current_run(self):
        for script, args in (("live-smoke.sh", ["claude", "1"]), ("live-soak.sh", ["1"])):
            with self.subTest(script=script):
                for saved in pathlib.Path(self.env["FAKE_STATE"]).glob("first-*"): saved.unlink()
                first = self.run_harness(script, args, "stale")
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                second = self.run_harness(script, args, "stale")
                self.assertNotEqual(second.returncode, 0, second.stdout)
                self.assertNotIn("GREEN", second.stdout)
                for saved in pathlib.Path(self.env["FAKE_STATE"]).glob("first-*"): saved.unlink()

    def test_foreign_run_tokens_fail_isolation(self):
        for script, args in (("live-smoke.sh", ["claude", "2"]), ("live-soak.sh", ["1"])):
            with self.subTest(script=script):
                result = self.run_harness(script, args, "foreignrun")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("GREEN", result.stdout)

    def test_foreign_run_lane_10_token_does_not_match_lane_1_prefix(self):
        result = self.run_harness("live-smoke.sh", ["claude", "1"], "foreignrun_lane10")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("TOKEN_A_wf-live-run-OLD123_10", result.stdout)
        self.assertNotIn("GREEN", result.stdout)

    def test_run_unique_labels(self):
        for _ in range(2): self.run_harness("live-smoke.sh", ["claude", "1"])
        labels = [args[args.index("--lane") + 1] for cmd, args in self.calls() if cmd == "spawn"]
        self.assertEqual(len(set(labels)), 2, labels)

    def test_failed_spawn_stops_lifecycle(self):
        self.run_harness("live-smoke.sh", ["claude", "1"], "spawnfail")
        self.assertEqual([cmd for cmd, _ in self.calls()], ["spawn", "reap"])

    def test_soak_failed_spawn_reaps_before_removing_workdir(self):
        result = self.run_harness("live-soak.sh", ["1"], "spawnfail")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        self.assertEqual([cmd for cmd, _ in calls].count("spawn"), 3)
        self.assertEqual([cmd for cmd, _ in calls].count("reap"), 3)
        by_lane = {}
        for cmd, args in calls:
            lane = args[args.index("--lane") + 1] if cmd == "spawn" else args[0]
            by_lane.setdefault(lane, []).append(cmd)
        self.assertEqual(list(by_lane.values()), [["spawn", "reap"]] * 3)
        self.assertEqual([(pathlib.Path(self.env["FAKE_STATE"]) / (lane + ".reapdir")).read_text() for lane in by_lane], ["True"] * 3)
        self.assertEqual(list((self.repo / "scratch").glob("soak-soak-*")), [])

sys.argv = [sys.argv[0]]
unittest.main()
