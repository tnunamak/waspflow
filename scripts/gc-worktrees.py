#!/usr/bin/env python3
"""Read-only worktree disposition scan behind `waspflow gc --worktrees`.

Never fetches, prunes, locks, deletes, or writes refs. Every git call runs with
GIT_OPTIONAL_LOCKS=0 so even `git status` leaves the index alone.

A worktree is `removable` only with positive evidence that its work is done,
`blocked` when any blocker holds, and `unknown` otherwise. A worktree that
vanishes mid-scan is `gone`.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

REGENERABLE = {"node_modules", ".next", "dist", "build", "target", ".venv",
               "__pycache__", ".turbo", "coverage"}
SECRET_SUFFIXES = (".pem", ".key")
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
               LC_ALL="C")
GH_LIMIT = 300
DU_TIMEOUT = 30
PROGRESS = {"merge": "MERGE_HEAD", "cherry-pick": "CHERRY_PICK_HEAD",
            "revert": "REVERT_HEAD", "rebase": "rebase-merge",
            "rebase-apply": "rebase-apply", "bisect": "BISECT_LOG"}


def run(args, cwd=None, timeout=60):
    """Return (rc, stdout); rc -1 on missing binary, cwd, or timeout."""
    try:
        p = subprocess.run(args, cwd=cwd, env=GIT_ENV, capture_output=True,
                           text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


def git(cwd, *args, timeout=60):
    return run(["git", "-C", cwd, *args], timeout=timeout)


def inside(path, roots):
    return any(path == r or path.startswith(r + "/") for r in roots)


def list_worktrees(repo):
    rc, out = git(repo, "worktree", "list", "--porcelain", "-z")
    if rc != 0:
        return []
    entries, cur = [], {}
    for field in out.split("\0"):
        if not field:
            if cur:
                entries.append(cur)
            cur = {}
            continue
        key, _, val = field.partition(" ")
        cur[key] = val
    if cur:
        entries.append(cur)
    return entries[1:]  # first entry is the main worktree


def discover_repos(roots, repos):
    found = {}
    for repo in repos:
        rc, out = git(repo, "rev-parse", "--git-common-dir")
        if rc != 0:
            sys.exit(f"gc: --repo is not a git repository: {repo}")
        common = os.path.realpath(os.path.join(os.path.abspath(repo), out.strip()))
        found.setdefault(common, os.path.abspath(repo))
    for root in roots:
        if not os.path.isdir(root):
            sys.exit(f"gc: --repos-root is not a directory: {root}")
        for name in sorted(os.listdir(root)):
            child = os.path.join(root, name)
            if os.path.isdir(os.path.join(child, ".git")):
                found.setdefault(os.path.realpath(os.path.join(child, ".git")), child)
    return list(found.values())


def scan_processes():
    """(pid, path) for the cwd and open files of this user's processes."""
    uid, me, hits = os.getuid(), os.getpid(), []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me:
            continue
        base = f"/proc/{pid}"
        try:
            if os.stat(base).st_uid != uid:
                continue
        except OSError:
            continue
        links = [base + "/cwd"]
        try:
            links += [f"{base}/fd/{fd}" for fd in os.listdir(base + "/fd")]
        except OSError:
            pass
        for link in links:
            try:
                target = os.readlink(link)
            except OSError:
                continue
            if target.startswith("/"):
                hits.append((int(pid), target.removesuffix(" (deleted)")))
    return hits


def tmux_panes():
    rc, out = run(["tmux", "list-panes", "-a", "-F", "#{pane_current_path}"], timeout=10)
    return [p for p in out.splitlines() if p.startswith("/")] if rc == 0 else []


def live_lane_paths(lanes_dir):
    """(lane, path) for every non-reaped lane's cwd/worktree fields."""
    out = []
    if not lanes_dir or not os.path.isdir(lanes_dir):
        return out
    for lane in sorted(os.listdir(lanes_dir)):
        try:
            with open(os.path.join(lanes_dir, lane, "state.json")) as f:
                st = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(st, dict) or st.get("status") == "reaped":
            continue
        for key, val in st.items():
            if (key == "cwd" or key.startswith("worktree")) and isinstance(val, str) \
                    and val.startswith("/"):
                out.append((lane, os.path.realpath(val)))
    return out


def classify_status(wt):
    """Blocker reasons from `git status` (v2, with ignored files)."""
    rc, out = git(wt, "status", "--porcelain=v2", "--ignored=matching", "-z", timeout=120)
    if rc != 0:
        return None
    reasons, other = set(), []
    recs = iter(out.split("\0"))
    for rec in recs:
        if not rec:
            continue
        kind = rec[0]
        if kind == "?":
            reasons.add("untracked files")
        elif kind in "1u":
            parts = rec.split(" ", 8)
            if kind == "1" and len(parts) > 2 and parts[2].startswith("S"):
                reasons.add("dirty submodule")
            else:
                reasons.add("tracked/staged changes")
        elif kind == "2":
            next(recs, None)  # -z puts the rename origin in its own record
            reasons.add("tracked/staged changes")
        elif kind == "!":
            path = rec[2:].rstrip("/")
            parts = path.split("/")
            if any(p.startswith(".env") or p.endswith(SECRET_SUFFIXES) for p in parts):
                reasons.add(f"ignored secret file: {path}")
            elif not REGENERABLE.intersection(parts):
                other.append(path)
    if other:
        reasons.add(f"ignored non-regenerable: {len(other)} path(s), e.g. {', '.join(other[:2])}")
    return reasons


def dir_size(path):
    rc, out = run(["du", "-sk", "--one-file-system", path], timeout=DU_TIMEOUT)
    try:
        return int(out.split()[0]) * 1024 if out else None
    except (ValueError, IndexError):
        return None


def default_branch_ref(repo):
    rc, out = git(repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        return out.strip()
    for cand in ("origin/main", "origin/master"):
        if git(repo, "rev-parse", "-q", "--verify", f"refs/remotes/{cand}")[0] == 0:
            return cand
    return None


def git_evidence(repo, wt, head, branch, default_ref):
    """(evidence class or None, why-not notes)."""
    rc, out = git(wt, "for-each-ref", "--contains", head, "--format=%(refname:short)",
                  "refs/remotes")
    remotes = [r for r in out.split() if not r.endswith("/HEAD")] if rc == 0 else []
    if remotes:
        return "ancestor-of-remote", remotes[0]
    notes = []
    if default_ref:
        rc, out = git(wt, "cherry", default_ref, head, timeout=120)
        lines = out.splitlines()
        if rc == 0 and lines and all(ln.startswith("-") for ln in lines):
            return "patch-equivalent", default_ref
        notes.append(f"commits not patch-equivalent to {default_ref}")
    else:
        notes.append("no remote default branch ref")
    rc, out = git(wt, "for-each-ref", "--format=%(refname:short)", "refs/remotes")
    if branch and not any(r.split("/", 1)[-1] == branch for r in out.split()):
        notes.append(f"no remote branch for {branch}")
    return None, notes


def analyze(repo, wt_entry, procs, panes, lanes, default_ref):
    path = wt_entry.get("worktree", "")
    head = wt_entry.get("HEAD", "")
    branch = wt_entry.get("branch", "").removeprefix("refs/heads/") or None
    row = {"repo": repo, "path": path, "branch": branch, "detached": branch is None,
           "head": head, "disposition": "unknown", "evidence": None,
           "reasons": [], "size_bytes": None, "age_seconds": None}
    if not os.path.isdir(path) or "prunable" in wt_entry:
        row["disposition"] = "gone"
        return row
    real = os.path.realpath(path)
    try:
        gitdir = None
        try:
            with open(os.path.join(path, ".git")) as f:
                gitdir = f.read().strip().removeprefix("gitdir:").strip()
            row["age_seconds"] = int(time.time() - os.stat(gitdir).st_mtime)
        except OSError:
            pass
        blockers = classify_status(path)
        if blockers is None:
            row["disposition"] = "gone" if not os.path.isdir(path) else "unknown"
            row["reasons"] = ["git status failed"]
            return row
        blockers = sorted(blockers)
        if "locked" in wt_entry:
            blockers.append("locked" + (f": {wt_entry['locked']}" if wt_entry["locked"] else ""))
        if gitdir:
            for name, marker in PROGRESS.items():
                if os.path.exists(os.path.join(gitdir, marker)):
                    blockers.append(f"in-progress {name}")
        pids = sorted({pid for pid, p in procs if inside(p, [real])})
        if pids:
            blockers.append("process cwd/open files inside: pid " + ",".join(map(str, pids[:5])))
        if any(inside(p, [real]) for p in panes):
            blockers.append("tmux pane cwd inside")
        for lane in sorted({ln for ln, p in lanes if inside(p, [real])}):
            blockers.append(f"live lane record: {lane}")
        row["size_bytes"] = dir_size(path)
        evidence, detail = (None, [])
        if head:
            evidence, detail = git_evidence(repo, path, head, branch, default_ref)
        if blockers:
            row["disposition"], row["reasons"] = "blocked", blockers
            row["evidence"] = evidence
        elif evidence:
            row["disposition"], row["evidence"] = "removable", evidence
            row["reasons"] = [f"via {detail}"]
        else:
            row["reasons"] = list(detail)
    except Exception as exc:  # a concurrent deleter must never crash the scan
        row["disposition"] = "gone" if not os.path.isdir(path) else "unknown"
        row["reasons"] = [f"scan error: {exc}"]
    if not os.path.isdir(path):
        row.update(disposition="gone", reasons=[])
    return row


def merged_pr_heads(repo):
    """(set of merged-PR head OIDs, truncated?) or (None, error)."""
    rc, out = run(["gh", "pr", "list", "--state", "merged", "--limit", str(GH_LIMIT),
                   "--json", "headRefOid"], cwd=repo, timeout=60)
    if rc != 0:
        return None, "gh unavailable or failed (rate limit/auth/network)"
    try:
        prs = json.loads(out)
    except ValueError:
        return None, "gh returned unparsable output"
    return {p.get("headRefOid") for p in prs}, len(prs) >= GH_LIMIT


def pr_for_sha(repo, sha):
    rc, out = run(["gh", "pr", "list", "--state", "merged", "--search", sha, "--json",
                   "headRefOid"], cwd=repo, timeout=60)
    if rc != 0:
        return None
    try:
        return any(p.get("headRefOid") == sha for p in json.loads(out))
    except ValueError:
        return None


def resolve_prs(repo, rows):
    pending = [r for r in rows if r["disposition"] == "unknown" and r["head"]
               and not r["reasons"] == ["git status failed"]]
    if not pending:
        return
    heads, truncated = merged_pr_heads(repo)
    for r in pending:
        if heads is None:
            r["reasons"].append(f"merged-PR check unknown: {truncated}")
            continue
        found = r["head"] in heads
        if not found and truncated:
            found = pr_for_sha(repo, r["head"])
            if found is None:
                r["reasons"].append("merged-PR check unknown: gh search failed")
                continue
        if found:
            r["disposition"], r["evidence"] = "removable", "merged-pr"
            r["reasons"] = ["merged PR head equals HEAD"]
        else:
            r["reasons"].append("no merged PR with head equal to HEAD")


def human(n):
    if n is None:
        return "?"
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024


def age_str(sec):
    if sec is None:
        return "?"
    for div, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if sec >= div:
            return f"{sec // div}{unit}"
    return f"{sec}s"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repos-root", action="append", default=[])
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--lanes-dir", default="")
    ap.add_argument("--json", action="store_true")
    ns = ap.parse_args()
    roots = ns.repos_root or ([] if ns.repo else [os.path.expanduser("~/code")])
    repos = discover_repos(roots, ns.repo)

    procs, panes = scan_processes(), tmux_panes()
    lanes = live_lane_paths(ns.lanes_dir)
    repo_info, all_rows = [], []
    for repo in repos:
        rc, common = git(repo, "rev-parse", "--git-common-dir")
        fetch_age = None
        if rc == 0:
            try:
                fetch_age = int(time.time() - os.stat(os.path.join(
                    os.path.abspath(os.path.join(repo, common.strip())), "FETCH_HEAD")).st_mtime)
            except OSError:
                pass
        default_ref = default_branch_ref(repo)
        entries = list_worktrees(repo)
        with ThreadPoolExecutor(8) as pool:
            rows = list(pool.map(lambda e: analyze(repo, e, procs, panes, lanes, default_ref),
                                 entries))
        resolve_prs(repo, rows)
        repo_info.append({"repo": repo, "worktrees": len(rows), "fetch_age_seconds": fetch_age,
                          "default_ref": default_ref})
        all_rows += rows

    summary = {"total": len(all_rows), "by_disposition": {}, "by_reason": {},
               "removable_bytes": sum(r["size_bytes"] or 0 for r in all_rows
                                      if r["disposition"] == "removable")}
    for r in all_rows:
        summary["by_disposition"][r["disposition"]] = \
            summary["by_disposition"].get(r["disposition"], 0) + 1
        if r["disposition"] in ("blocked", "unknown"):
            for reason in r["reasons"]:
                key = reason.split(":")[0] if reason.startswith(("ignored", "live lane", "process")) \
                    else reason
                summary["by_reason"][key] = summary["by_reason"].get(key, 0) + 1

    if ns.json:
        json.dump({"repos": repo_info, "worktrees": all_rows, "summary": summary},
                  sys.stdout, indent=2)
        print()
        return
    print(f"{'DISPOSITION':<12} {'EVIDENCE/REASONS':<56} {'SIZE':>7} {'AGE':>5}  BRANCH  PATH")
    for r in all_rows:
        what = r["evidence"] if r["disposition"] == "removable" else "; ".join(r["reasons"])
        if r["disposition"] == "blocked" and r["evidence"]:
            what += f" (evidence: {r['evidence']})"
        print(f"{r['disposition']:<12} {what:<56} {human(r['size_bytes']):>7} "
              f"{age_str(r['age_seconds']):>5}  {r['branch'] or '(detached)'}  {r['path']}")
    for info in repo_info:
        print(f"repo {info['repo']}: {info['worktrees']} linked worktrees; newest fetch "
              f"{age_str(info['fetch_age_seconds']) + ' ago' if info['fetch_age_seconds'] is not None else 'never (no FETCH_HEAD)'}")
    print(f"gc --worktrees: {summary['total']} worktrees "
          + " ".join(f"{k}={v}" for k, v in sorted(summary['by_disposition'].items()))
          + f" removable_size={human(summary['removable_bytes'])} (dry run; nothing changed)")


if __name__ == "__main__":
    main()
