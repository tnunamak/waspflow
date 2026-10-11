import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import unittest

root = pathlib.Path(sys.argv[1])

class Fixtures(unittest.TestCase):
    def test_receipt_identity_guard(self):
        text = (root / "scripts/verify.sh").read_text()
        start = text.index('  jq ', text.index('receipt reuse: second lane life'))
        end = text.index('  cmp -s', start)
        snippet = text[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(tmp)
            (home / "receipts.jsonl").write_text('{"receipt_id":"same","lane_uuid":"same"}\n' * 2)
            result = subprocess.run(["bash", "-c", snippet], env={**os.environ,"mcphome":str(home),"first_receipt_id":"same","first_lane_uuid":"same"}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_negative_pgid_guard(self):
        text = (root / "scripts/fixtures/verify-r6.sh").read_text()
        snippet = text[text.index('  if grep -Eq --'):text.index('  if kill -0', text.index('  if grep -Eq --'))]
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "signals"
            for signal in ("-TERM -- -123", "-KILL -123"):
                log.write_text(signal + "\n")
                result = subprocess.run(["bash", "-c", snippet], env={**os.environ,"signal_log":str(log)}, capture_output=True)
                self.assertNotEqual(result.returncode, 0, signal)
            for allowed in ("-0 123", "-9 123", "-TERM 123", "-KILL 123"):
                log.write_text(allowed + "\n")
                result = subprocess.run(["bash", "-c", snippet], env={**os.environ,"signal_log":str(log)}, capture_output=True)
                self.assertEqual(result.returncode, 0, allowed)
            logger = re.search(r'kill\(\) \{ (.*?); builtin kill', text).group(1)
            result = subprocess.run(["bash", "-c", 'set -- -0 "$$"; ' + logger], env={**os.environ,"signal_log":str(log)}, capture_output=True)
            self.assertTrue(log.read_bytes().endswith(b"\n"), log.read_bytes())

    def test_git_shim_fallback(self):
        text = (root / "scripts/fixtures/verify-r3-f1.sh").read_text()
        shim = re.search(r'cat >"\$r3f1/bin/git" <<.EOF.\n(.*?)\nEOF', text, re.S).group(1)
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            git = directory / "git"
            git.write_text(shim); git.chmod(0o755)
            hook = directory / "hook"
            hook.write_text('if [[ "${RECURSION_SEEN:-}" == yes ]]; then exit 42; fi\nexport RECURSION_SEEN=yes\n')
            real = subprocess.run(["bash","-c","type -P git"], capture_output=True, text=True, check=True).stdout.strip()
            result = subprocess.run([str(git),"--version"], env={**os.environ,"PATH":str(directory)+os.pathsep+os.environ["PATH"],"BASH_ENV":str(hook),"R3F1_REAL_GIT":real}, capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith("git version"), result.stdout)

    def test_failure_cleans_detached_child(self):
        text = (root / "scripts/fixtures/verify-r3-f1.sh").read_text()
        prefix = text[:text.index("  # B3:")] + ")\n"
        prefix = prefix.replace("  if tmux_kill_owned_lane_detached_sessions descendants; then", '  tmux_kill_owned_lane_detached_sessions() { printf "%s %s\\n" "$child" "$(process_start_ticks "$child")" >"$PID_RECEIPT"; return 0; }\n  if tmux_kill_owned_lane_detached_sessions descendants; then')
        with tempfile.TemporaryDirectory() as tmp:
            receipt = pathlib.Path(tmp) / "pid"
            result = subprocess.run(["bash", "-euc", prefix], env={**os.environ,"root":str(root),"scratch":tmp,"PID_RECEIPT":str(receipt)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            pid, ticks = receipt.read_text().split()
            stat = pathlib.Path("/proc") / pid / "stat"
            alive = False
            try:
                fields = stat.read_text().rsplit(") ", 1)[1].split()
                alive = fields[19] == ticks and fields[0] != "Z"
                if alive: os.kill(int(pid), signal.SIGKILL)
            except FileNotFoundError:
                pass
            self.assertFalse(alive, "failure path leaked its detached child")

sys.argv = [sys.argv[0]]
unittest.main()
