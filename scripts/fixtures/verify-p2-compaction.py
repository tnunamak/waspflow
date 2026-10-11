import importlib.util
import fcntl
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("compaction", root / "scripts/compact_reaped_transcripts.py")
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)

class Compaction(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lane = pathlib.Path(self.tmp.name) / "lane"
        self.lane.mkdir()
        (self.lane / "state.json").write_text('{"status":"reaped","cgroup_scope_receipts":[{"unit":"waspflow-test.scope"}]}')
        self.transcript = self.lane / "transcript.log"
        self.transcript.write_bytes(b"visible\x1b[31mred")

    def test_large_verification_is_bounded(self):
        compacted = self.lane / "clean"
        compacted.write_bytes(b"visiblered")
        real_open = open
        class Bounded:
            def __init__(self, file): self.file = file
            def __enter__(self): return self
            def __exit__(self, *args): self.file.close()
            def read(self, size=-1):
                self.assert_bounded(size)
                return self.file.read(size)
            def assert_bounded(self, size):
                assert 0 <= size <= m.CHUNK_SIZE, f"unbounded read: {size}"
        def bounded_open(path, *args, **kwargs):
            file = real_open(path, *args, **kwargs)
            return Bounded(file) if str(path) == str(compacted) else file
        with patch.object(m.os.path, "getsize", return_value=65 * 1024 * 1024), patch("builtins.open", bounded_open):
            self.assertEqual(m.verify_compacted(str(self.transcript), str(compacted)), (True, ""))

    def test_small_verification_reads_are_bounded(self):
        compacted = self.lane / "clean"
        compacted.write_bytes(b"visiblered")
        cap = m.WHOLE_BUFFER_CAP
        real_open = open
        class Bounded:
            def __init__(self, file): self.file = file
            def __enter__(self): return self
            def __exit__(self, *args): self.file.close()
            def read(self, size=-1):
                assert 0 <= size <= cap + 1, f"unbounded read: {size}"
                return self.file.read(size)
        def bounded_open(path, *args, **kwargs):
            file = real_open(path, *args, **kwargs)
            return Bounded(file) if str(path) in (str(compacted), str(self.transcript)) else file
        with patch("builtins.open", bounded_open):
            self.assertEqual(m.verify_compacted(str(self.transcript), str(compacted)), (True, ""))
            compacted.write_bytes(b"visible\x1b[31mred")
            self.assertEqual(m.verify_compacted(str(self.transcript), str(compacted))[0], False)
        # A file that outgrows the cap after the size check uses the streaming path.
        compacted.write_bytes(b"visiblered")
        with patch.object(m, "WHOLE_BUFFER_CAP", 4), patch.object(m.os.path, "getsize", return_value=1), \
             patch.object(m, "strip_bytes", side_effect=AssertionError("whole-buffer path used")):
            self.assertEqual(m.verify_compacted(str(self.transcript), str(compacted)), (True, ""))

    def test_preflight_error_has_receipt(self):
        with patch.object(m, "already_compacted", side_effect=OSError("fixture read failure")):
            result = m.process_lane(str(self.lane), set(), apply=False)
        self.assertEqual(result.action, "error")
        self.assertIn("fixture read failure", result.reason)

    def test_final_scope_check_is_fresh(self):
        original = self.transcript.read_bytes()
        with patch.object(m, "get_active_waspflow_scopes", return_value={"waspflow-test.scope"}):
            result = m.process_lane(str(self.lane), set(), apply=True)
        self.assertEqual(result.action, "skip")
        self.assertEqual(self.transcript.read_bytes(), original)

    def test_changed_transcript_is_preserved(self):
        def changed(*args):
            with self.transcript.open("ab") as file: file.write(b"later append")
            return True, ""
        with patch.object(m, "verify_compacted", side_effect=changed), patch.object(m, "get_active_waspflow_scopes", return_value=set()):
            result = m.process_lane(str(self.lane), set(), apply=True)
        self.assertEqual(result.action, "skip")
        self.assertTrue(self.transcript.read_bytes().endswith(b"later append"))

    def assert_state_lock_held(self, expected_held):
        with (self.lane / ".state.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.assertTrue(expected_held, "state lock unexpectedly held")
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)
                self.assertFalse(expected_held, "state lock unexpectedly free")

    def test_state_lock_only_covers_final_replace(self):
        real_strip = m.stream_strip_to_tempfile
        real_replace = m.os.replace
        real_verify = m.verify_compacted
        def unlocked_during_verify(*args):
            self.assert_state_lock_held(False)
            return real_verify(*args)
        def unlocked_during_strip(*args):
            self.assert_state_lock_held(False)
            return real_strip(*args)
        def locked_during_replace(*args):
            self.assert_state_lock_held(True)
            return real_replace(*args)
        with patch.object(m, "stream_strip_to_tempfile", side_effect=unlocked_during_strip), \
             patch.object(m, "verify_compacted", side_effect=unlocked_during_verify), \
             patch.object(m.os, "replace", side_effect=locked_during_replace), \
             patch.object(m, "get_active_waspflow_scopes", return_value=set()):
            result = m.process_lane(str(self.lane), set(), apply=True)
        self.assertEqual(result.action, "compacted")

sys.argv = [sys.argv[0]]
unittest.main()
