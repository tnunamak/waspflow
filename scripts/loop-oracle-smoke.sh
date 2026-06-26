#!/usr/bin/env bash
# Smoke tests for lib/loop-oracle.sh — proves the deterministic facts behave
# (Codex review-3 approval-bar #5). Each test asserts a JSON field. No agents.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib/loop-oracle.sh"
PASS=0; FAIL=0
jqget() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 ($3)"; else FAIL=$((FAIL+1)); echo "  FAIL $1 — want $2 got $3"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 1. dirty preflight fails ──
git init -q "$TMP/repo"; ( cd "$TMP/repo" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && echo dirty > untracked.txt )
out="$(oracle_preflight "$TMP/repo")"
check "preflight: dirty worktree → ok:false" "False" "$(echo "$out" | jqget ok)"

# ── 2. missing worktree fails ──
out="$(oracle_preflight "$TMP/does-not-exist")"
check "preflight: missing worktree → ok:false" "False" "$(echo "$out" | jqget ok)"

# ── 3. discover parser actually parses biome output (the bug Codex caught) ──
synthetic_lint() { cat <<'LINT'
foo.ts:42:1 lint/complexity/noExcessiveCognitiveComplexity ━━━
  × Excessive complexity of 31 detected (max: 20).
bar.ts:7:1 lint/complexity/noExcessiveCognitiveComplexity ━━━
  × Excessive complexity of 25 detected (max: 20).
LINT
}
export -f synthetic_lint
out="$(oracle_discover "$TMP/repo" "synthetic_lint" "$TMP/run")"
check "discover: parses 2 complexity findings → rawLinterCount=2" "2" \
  "$(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["rawLinterCount"])' 2>/dev/null)"
check "discover: ok:true on clean parse" "True" "$(echo "$out" | jqget ok)"

# ── 4. discover fails-closed when the linter command errors with no output ──
fail_lint() { echo "boom" >&2; return 3; }
export -f fail_lint
out="$(oracle_discover "$TMP/repo" "fail_lint" "$TMP/run2")"
check "discover: linter error → ok:false (not rawLinterCount=0)" "False" "$(echo "$out" | jqget ok)"

# ── 5. gate: missing/empty test command → hard fail (no false-pass) ──
: > "$TMP/empty-testcmd.sh"   # empty file
echo '{"diagnostics":{}}' > "$TMP/baseline.json"
out="$(oracle_gate "$TMP/repo" "nope-branch" "foo.ts" "foo" "$TMP/empty-testcmd.sh" "$TMP/baseline.json" "true")"
check "gate: empty test command → ok:false" "False" "$(echo "$out" | jqget ok)"
check "gate: empty test command → testCommandPresent:false" "False" "$(echo "$out" | jqget testCommandPresent)"

# ── 6. gate: nonexistent branch → checkout-failed (never measures wrong branch) ──
echo 'true' > "$TMP/good-testcmd.sh"
out="$(oracle_gate "$TMP/repo" "branch-that-does-not-exist" "foo.ts" "foo" "$TMP/good-testcmd.sh" "$TMP/baseline.json" "true")"
check "gate: missing branch → ok:false" "False" "$(echo "$out" | jqget ok)"
check "gate: missing branch → reason checkout-failed" "checkout-failed" "$(echo "$out" | jqget reason)"

# ── 7. gate: empty-diff branch → ok:true but diffFiles=[] AND the gate REJECTS it ──
# (Codex approval-bar item 5: "empty diff fails". A real branch identical to
#  origin/main produces honest facts with no changed files; loop_gate_passed must reject.)
source "$HERE/lib/loop.sh"  # for loop_gate_passed
( cd "$TMP/repo" && git branch -f origin-main-shadow HEAD \
  && git remote add origin "$TMP/repo" 2>/dev/null; git update-ref refs/remotes/origin/main HEAD \
  && git checkout -q -b empty-diff-branch )
echo 'true' > "$TMP/good-testcmd.sh"
out="$(oracle_gate "$TMP/repo" "empty-diff-branch" "untracked.txt" "foo" "$TMP/good-testcmd.sh" "$TMP/baseline.json" "true")"
check "gate: empty-diff branch → ok:true (oracle reports honest facts)" "True" "$(echo "$out" | jqget ok)"
check "gate: empty-diff branch → diffFiles is []" "[]" "$(echo "$out" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("diffFiles")))' 2>/dev/null)"
# The structural gate must REJECT an empty diff even with green facts + a green semantic verdict.
green_sem='{"behaviorPreserving":true,"methodologyAligned":true,"callerCountsVerified":true,"surfaceUnchanged":true,"evidence":"'"$(printf 'x%.0s' {1..90})"'"}'
if loop_gate_passed "$out" "$green_sem"; then gate_verdict=accepted; else gate_verdict=rejected; fi
check "gate: empty-diff branch → loop_gate_passed REJECTS" "rejected" "$gate_verdict"

echo ""
echo "loop-oracle smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
