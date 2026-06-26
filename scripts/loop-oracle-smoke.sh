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
source "$HERE/lib/loop.sh"  # for loop_gate_passed, _loop_caprank
# Commit a real source file with a locatable symbol so the gate can find the target.
( cd "$TMP/repo" && printf 'export function widget() {\n  return 1;\n}\n' > src.ts \
  && git add src.ts && git commit -q -m "add src.ts" \
  && git remote add origin "$TMP/repo" 2>/dev/null; git update-ref refs/remotes/origin/main HEAD \
  && git checkout -q -b empty-diff-branch )
echo 'true' > "$TMP/good-testcmd.sh"
out="$(oracle_gate "$TMP/repo" "empty-diff-branch" "src.ts" "widget" "$TMP/good-testcmd.sh" "$TMP/baseline.json" "true" "1")"
check "gate: empty-diff branch → ok:true (oracle reports honest facts)" "True" "$(echo "$out" | jqget ok)"
check "gate: empty-diff branch → diffFiles is []" "[]" "$(echo "$out" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("diffFiles")))' 2>/dev/null)"
# The structural gate must REJECT an empty diff even with green facts + a green semantic verdict.
green_sem='{"behaviorPreserving":true,"methodologyAligned":true,"callerCountsVerified":true,"surfaceUnchanged":true,"evidence":"'"$(printf 'x%.0s' {1..90})"'"}'
if loop_gate_passed "$out" "$green_sem"; then gate_verdict=accepted; else gate_verdict=rejected; fi
check "gate: empty-diff branch → loop_gate_passed REJECTS" "rejected" "$gate_verdict"

# ── 8. gate: unlocatable target symbol → ok:false (Codex review-4 #4 false-pass fix) ──
# A symbol that doesn't exist + no usable line must FAIL CLOSED, not default cleared=true.
out="$(oracle_gate "$TMP/repo" "empty-diff-branch" "src.ts" "no_such_symbol_xyz" "$TMP/good-testcmd.sh" "$TMP/baseline.json" "true" "")"
check "gate: unlocatable symbol → ok:false" "False" "$(echo "$out" | jqget ok)"
check "gate: unlocatable symbol → reason target-symbol-unlocatable" "target-symbol-unlocatable" "$(echo "$out" | jqget reason)"

# ── 9. baseline: broken file-lint command → ok:false (Codex review-4 #3 fail-open fix) ──
broken_lint() { echo "config error" >&2; return 2; }
export -f broken_lint
out="$(oracle_baseline "$TMP/repo" "src.ts" "broken_lint")"
check "baseline: broken file-lint → ok:false" "False" "$(echo "$out" | jqget ok)"
check "baseline: broken file-lint → lintFileExitCode=2" "2" "$(echo "$out" | jqget lintFileExitCode)"

# ── 10. gate: broken POST-lint command → ok:false (Codex review-4 #3) ──
out="$(oracle_gate "$TMP/repo" "empty-diff-branch" "src.ts" "widget" "$TMP/good-testcmd.sh" "$TMP/baseline.json" "broken_lint" "1")"
check "gate: broken post-lint → ok:false" "False" "$(echo "$out" | jqget ok)"
check "gate: broken post-lint → reason post-lint-failed" "post-lint-failed" "$(echo "$out" | jqget reason)"

# ── 11. checker-strength: rank ordering enforces the owner capability table (review-4 #5) ──
# gpt-5.5 high (6) > opus xhigh (5) > gpt-5.5 low (4) > opus high (3) > opus low (2) > sonnet (1)
check "caprank: sonnet = 1" "1" "$(_loop_caprank claude sonnet medium)"
check "caprank: opus high = 3" "3" "$(_loop_caprank claude opus high)"
check "caprank: opus xhigh = 5" "5" "$(_loop_caprank claude opus xhigh)"
check "caprank: gpt-5.5 high = 6" "6" "$(_loop_caprank codex gpt-5.5 high)"
# A sonnet checker (1) is WEAKER than an opus-high maker (3) → must be rejected by rank.
maker=$(_loop_caprank claude opus high); chk=$(_loop_caprank claude sonnet medium)
[ "$chk" -lt "$maker" ] && weak=rejected || weak=accepted
check "caprank: sonnet-checker vs opus-maker → weaker (rejected)" "rejected" "$weak"

# ── 12. lineage is FAMILY not raw string (Codex review-5 #2 bypass fix) ──
# opus-high maker vs opus-xhigh checker: stronger rank BUT same lineage → must be rejected.
check "family: opus-high → opus" "opus" "$(_loop_family claude opus-high high)"
check "family: opus-xhigh → opus" "opus" "$(_loop_family claude opus-xhigh xhigh)"
check "family: gpt-5.5 → gpt" "gpt" "$(_loop_family codex gpt-5.5 high)"
mfam=$(_loop_family claude opus-high high); cfam=$(_loop_family claude opus-xhigh xhigh)
[ "$cfam" = "$mfam" ] && lineage=same-rejected || lineage=different-ok
check "family: opus-high maker vs opus-xhigh checker → SAME lineage (rejected)" "same-rejected" "$lineage"
# gpt checker vs opus maker → genuinely different lineage → allowed.
mfam=$(_loop_family claude opus high); cfam=$(_loop_family codex gpt-5.5 high)
[ "$cfam" != "$mfam" ] && lineage=different-ok || lineage=same-rejected
check "family: opus maker vs gpt checker → DIFFERENT lineage (allowed)" "different-ok" "$lineage"

# ── 13. target line must be ORACLE-grounded, not agent-trusted (Codex review-5 #1) ──
# Exercises the REAL engine fn _loop_ground_target_line (sourced from lib/loop.sh).
RAW='[{"file":"src/foo.ts","line":62,"complexity":31}]'
# Honest target (line matches a raw finding) → oracle line returned.
check "target-ground: correct line (62) → grounded" "62" "$(_loop_ground_target_line "$RAW" '{"file":"src/foo.ts","line":62}')"
# Dishonest target (agent set line:1, real diagnostic is at 62) → empty → engine fails closed.
check "target-ground: WRONG line (1) → empty (engine fails closed)" "" "$(_loop_ground_target_line "$RAW" '{"file":"src/foo.ts","line":1}')"
# Wrong file → empty too.
check "target-ground: wrong file → empty" "" "$(_loop_ground_target_line "$RAW" '{"file":"src/other.ts","line":62}')"
# Right (file,line) but MISLABELED complexity → empty (complexity must match too).
check "target-ground: right line wrong complexity → empty" "" "$(_loop_ground_target_line "$RAW" '{"file":"src/foo.ts","line":62,"complexity":99}')"

# ── 14. unknown model family (haiku/fable/future) → rank 0 → never a valid checker ──
check "family: haiku → unknown" "unknown" "$(_loop_family claude haiku medium)"
check "family: fable → unknown" "unknown" "$(_loop_family claude fable high)"
check "caprank: unknown family → rank 0 (weakest)" "0" "$(_loop_caprank claude haiku high)"
# An unknown-family checker can NEVER outrank a real maker → always rejected.
mr=$(_loop_caprank claude sonnet medium); cr=$(_loop_caprank claude haiku high)
[ "$cr" -lt "$mr" ] && uok=rejected || uok=accepted
check "family: unknown checker vs sonnet maker → rejected" "rejected" "$uok"

echo ""
echo "loop-oracle smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
