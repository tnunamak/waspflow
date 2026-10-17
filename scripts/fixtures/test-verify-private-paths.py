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

    def run_cleanup(self, name, status, prefix="tmp"):
        import subprocess, tempfile
        text = (root / "scripts/verify.sh").read_text()
        import re
        body = re.search(r"(?ms)^%s\(\) \{.*?^\}" % name, text).group(0)
        with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
            parent = Path(tmp)
            script = f"""
set -u
parent=$1
scratch="$parent/wf-run"; mkdir -p "$scratch"
fixture="$scratch/fixture"; state_home="$scratch/state"; tmux_wrapper="$scratch/wrap"
tmux_socket_dir="$parent/socket"; mkdir -p "$fixture" "$state_home" "$tmux_wrapper" "$tmux_socket_dir"
touch "$parent/sibling" "$state_home/evidence"
verify_tmux() {{ echo "$*" >> "$parent/tmux.calls"; [[ "$1" == list-sessions ]] && printf 'wf-atomic\\nwf-steer-7\\n'; return 0; }}
failure_line=1; failure_command=x; WASPFLOW_TMUX_SESSION=s
{body}
(exit {status}); {name}
"""
            result = subprocess.run(["bash", "-c", script, "test", str(parent)], capture_output=True, text=True)
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

    def test_cleanup_stops_every_session_left_on_the_private_socket(self):
        import subprocess, tempfile, re
        text = (root / "scripts/verify.sh").read_text()
        body = re.search(r"(?ms)^cleanup\(\) \{.*?^\}", text).group(0)
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            script = f"""
parent=$1; scratch="$parent/run"; mkdir -p "$scratch"
fixture=$scratch/f; state_home=$scratch/s; tmux_wrapper=$scratch/w; tmux_socket_dir=$parent/sock
WASPFLOW_TMUX_SESSION=main; failure_line=1; failure_command=x
verify_tmux() {{ echo "$*" >> "$parent/tmux.calls"; if [[ "$1" == list-sessions ]]; then printf 'wf-atomic\\nwf-steer-7\\n'; fi; return 0; }}
{body}
(exit 1); cleanup
"""
            subprocess.run(["bash", "-c", script, "t", str(parent)], capture_output=True)
            calls = (parent / "tmux.calls").read_text().splitlines()
            for name in ("main", "wf-atomic", "wf-steer-7"):
                self.assertIn(f"kill-session -t {name}", calls)
            self.assertNotIn("kill-server", " ".join(calls))

    def test_cleanup_handles_a_parent_path_with_spaces(self):
        sibling, root_exists, evidence, _ = self.run_cleanup("cleanup", 1, prefix="verify space ")
        self.assertTrue(sibling and root_exists and evidence)


def stub_env(tmp, log):
    """PATH with a recording no-op tmux, and no inherited tmux or session variables."""
    bin_dir = Path(tmp) / "stub-bin"
    bin_dir.mkdir()
    stub = bin_dir / "tmux"
    stub.write_text(f'#!/bin/sh\necho "$@" >> "{log}"\n')
    stub.chmod(0o755)
    return {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp)}


class FixtureTrapTests(unittest.TestCase):
    """Fixture-local EXIT traps must keep their directory when the run failed."""

    def traps(self):
        import re
        found = []
        for path in [root / "scripts/verify.sh", *sorted((root / "scripts/fixtures").glob("*.sh"))]:
            for match in re.finditer(r"trap '([^']*rm -rf[^']*)' EXIT", path.read_text()):
                found.append((path.name, match.group(1)))
        return found

    def test_every_removing_trap_is_conditional_on_success(self):
        traps = self.traps()
        self.assertGreater(len(traps), 20)
        for name, body in traps:
            with self.subTest(file=name, trap=body):
                self.assertIn("__rc=$?", body)
                self.assertIn("__rc == 0", body)

    def test_trap_keeps_directory_on_failure_and_removes_on_success(self):
        import re, subprocess, tempfile
        for name, body in self.traps():
            names = set(re.findall(r'rm -rf "\$(\w+)"', body))
            for status, expect_exists in ((1, True), (0, False)):
                with self.subTest(file=name, status=status), tempfile.TemporaryDirectory() as tmp:
                    target = Path(tmp) / "fixture dir"
                    target.mkdir()
                    assign = "".join(f'{n}="$1"; ' for n in names)
                    script = f"{assign} trap '{body}' EXIT; exit {status}"
                    log = Path(tmp) / "tmux.log"
                    subprocess.run(["bash", "-c", script, "t", str(target)], capture_output=True,
                                   env=stub_env(tmp, log))
                    self.assertEqual(target.exists(), expect_exists)

    def test_fixture_sessions_are_stopped_on_failure(self):
        import re, subprocess, tempfile
        text = (root / "scripts/verify.sh").read_text()
        for anchor, var in (('tmux new-session -d -s "$lifesession" -n _home', "lifesession"),
                            ('tmux new-session -d -s "$sess" -n _h', "sess")):
            with self.subTest(var=var):
                after = text.split(anchor, 1)[1]
                match = re.search(r"trap '([^']*kill-session -t \"\$%s\"[^']*)' EXIT" % var, after[:700])
                self.assertIsNotNone(match, f"no EXIT trap stops ${var}")
                with tempfile.TemporaryDirectory() as tmp:
                    log = Path(tmp) / "tmux.log"
                    script = f"{var}=waspflow-x-1; trap '{match.group(1)}' EXIT; exit 1"
                    subprocess.run(["bash", "-c", script], capture_output=True, env=stub_env(tmp, log))
                    self.assertEqual(log.read_text().strip(), "kill-session -t waspflow-x-1")

    def test_custom_temp_parent_with_a_fresh_home_works(self):
        import subprocess, tempfile
        text = (root / "scripts/verify.sh").read_text()
        head = text.split("trap early_cleanup EXIT", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "fresh home"
            home.mkdir()
            custom = Path(tmp) / "custom parent"
            script = head + 'mktemp -d "$HOME/.tmp/wf-tmux-XXXXXX" >/dev/null && echo SOCKET_PARENT_OK'
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin", "HOME": str(home),
                                         "WASPFLOW_TEST_TMPDIR": str(custom)})
            self.assertIn("SOCKET_PARENT_OK", result.stdout, result.stderr)


if __name__ == "__main__":
    unittest.main()
