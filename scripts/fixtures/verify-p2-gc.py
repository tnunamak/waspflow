import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("gc_worktrees", pathlib.Path(sys.argv[1]) / "scripts/gc-worktrees.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.merged_pr_heads = lambda repo: ({"merged"}, False)
m.git = lambda *args, **kwargs: (0, "merged\n")
rows = [{"disposition": "unknown", "path": "fixture", "head": "merged", "reasons": [reason]} for reason in
        ("scan error: UnicodeDecodeError", "git status failed", "no reachability proof")]
m.resolve_prs("unused", rows)
assert rows[0]["disposition"] == "unknown", rows[0]
assert rows[1]["disposition"] == "unknown", rows[1]
assert rows[2]["disposition"] == "removable", rows[2]

# Enumeration and the later scan may observe different commits.
import tempfile
with tempfile.TemporaryDirectory() as directory:
    m.classify_status = lambda path: set()
    m.dir_size = lambda path: 0
    m.git_evidence = lambda *args: ("remote-contained", "old commit is pushed")
    m.git = lambda *args, **kwargs: (0, "new-unpushed\n")
    row = m.analyze(directory, {"worktree":directory,"HEAD":"old-pushed","branch":"refs/heads/fix"}, [], [], [], "origin/main")
    assert row["disposition"] != "removable", row
    m.resolve_prs(directory, [row])
    assert row["disposition"] != "removable", row
