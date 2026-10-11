import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("gc_worktrees", pathlib.Path(sys.argv[1]) / "scripts/gc-worktrees.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.merged_pr_heads = lambda repo: ({"merged"}, False)
rows = [{"disposition": "unknown", "head": "merged", "reasons": [reason]} for reason in
        ("scan error: UnicodeDecodeError", "git status failed", "no reachability proof")]
m.resolve_prs("unused", rows)
assert rows[0]["disposition"] == "unknown", rows[0]
assert rows[1]["disposition"] == "unknown", rows[1]
assert rows[2]["disposition"] == "removable", rows[2]
