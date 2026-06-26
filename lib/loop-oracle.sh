#!/usr/bin/env bash
# loop-oracle.sh — the DETERMINISTIC ORACLE for the waspflow gated loop.
#
# This is the "real commands whose pass/fail you cannot override" layer. The loop
# engine (lib/loop.sh) runs these functions in ITS OWN process — no agent is in
# the command path, so the facts are un-fakeable by construction. Each function
# prints ONE JSON object to stdout. Agents NEVER author these numbers; they only
# consume them and judge semantics.
#
# Generic where possible; the complexity-linter specifics are refactoring's, but
# a different profile can supply its own discover/baseline/gate-extra commands.
#
# Codex review-3 fixes baked in: parser reads stdin via `python3 -c` (not a
# heredoc that eats stdin); linter/checkout/test failures FAIL-CLOSED with
# explicit ok:false; empty test command is a hard fail; per-run artifact dirs.

set -uo pipefail

_oracle_json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Per-run scratch dir (concurrency-safe; Codex review-3 non-blocking #5).
oracle_run_dir() {
  local rid="${1:-$(date +%s)-$$}"
  local d="${TMPDIR:-/tmp}/wf-loop-$rid"
  mkdir -p "$d" && echo "$d"
}

# ── preflight: worktree clean + descended from origin/main ──
oracle_preflight() {
  local wt="${1:?worktree}"
  if [ ! -e "$wt/.git" ]; then echo '{"ok":false,"reason":"worktree-missing"}'; return 0; fi
  git -C "$wt" fetch origin main -q 2>/dev/null
  local porcelain head base clean descended
  porcelain="$(git -C "$wt" status --porcelain 2>/dev/null | grep -v 'node_modules' | head -1)"
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  base="$(git -C "$wt" rev-parse origin/main 2>/dev/null)"
  [ -z "$porcelain" ] && clean=true || clean=false
  if git -C "$wt" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then descended=true; else descended=false; fi
  printf '{"ok":%s,"clean":%s,"descendedFromMain":%s,"head":"%s","originMain":"%s","dirtyExample":%s}\n' \
    "$([ "$clean" = true ] && [ "$descended" = true ] && echo true || echo false)" \
    "$clean" "$descended" "${head:0:12}" "${base:0:12}" "$(printf '%s' "$porcelain" | _oracle_json_escape)"
}

# ── discover: run a profile-supplied linter command; emit raw findings (FAIL-CLOSED on error) ──
# $1 worktree   $2 the lint command to eval (must print biome-style output)   $3 run dir
oracle_discover() {
  set +e   # linters exit nonzero when they find issues; never let a caller's set -e abort us.
  local wt="${1:?worktree}" lintcmd="${2:?lintcmd}" rundir="${3:-$(oracle_run_dir)}"
  mkdir -p "$rundir"
  local raw="$rundir/discover-raw.txt"
  # Run the REAL linter; capture stdout+stderr + the exit code (Codex review-3 #3: fail-closed).
  ( cd "$wt" && eval "$lintcmd" ) >"$raw" 2>&1
  local rc=$?
  # A nonzero exit with NO complexity output means the linter itself failed → fail-closed.
  if [ "$rc" -ne 0 ] && ! grep -q 'noExcessiveCognitiveComplexity' "$raw"; then
    printf '{"ok":false,"reason":"linter-failed","linterExitCode":%s,"tail":%s}\n' \
      "$rc" "$(tail -5 "$raw" | _oracle_json_escape)"
    return 0
  fi
  # Parse complexity findings — FIXED: python3 -c reading the file (Codex review-3 #2;
  # the old `python3 - <<HEREDOC` consumed the heredoc as the script and left stdin empty).
  local findings
  findings="$(python3 -c '
import sys, json, re
out=[]; loc=None
for line in open(sys.argv[1]):
    m=re.search(r"([\w./\[\]-]+\.(?:ts|tsx|js)):(\d+):\d+\s+lint/complexity/noExcessiveCognitiveComplexity", line)
    if m: loc=(m.group(1), int(m.group(2)))
    c=re.search(r"Excessive complexity of (\d+)", line)
    if c and loc: out.append({"file":loc[0],"line":loc[1],"complexity":int(c.group(1))}); loc=None
out.sort(key=lambda x:-x["complexity"])
print(json.dumps({"rawLinterCount":len(out),"findings":out}))
' "$raw" 2>/dev/null)"
  if [ -z "$findings" ]; then
    printf '{"ok":false,"reason":"parse-failed","linterExitCode":%s}\n' "$rc"; return 0
  fi
  printf '{"ok":true,"linterExitCode":%s,"result":%s}\n' "$rc" "$findings"
}

# ── baseline: pre-change lint diagnostics-by-rule for one file ──
# Codex review-4 #3: emit lintFileExitCode + ok; FAIL CLOSED if the file-lint command
# errors AND produced no parseable diagnostics (else a broken cmd → {} → false-pass).
oracle_baseline() {
  set +e   # the oracle RUNS commands expected to exit nonzero (linters) and captures their
           # codes; a caller's `set -e` must never abort us mid-measurement. (bin/waspflow has set -e.)
  local wt="${1:?worktree}" file="${2:?file}" lintfile_cmd="${3:?lintfile_cmd}"
  local out rc diags
  out="$( ( cd "$wt" && eval "$lintfile_cmd" ) 2>&1 )"; rc=$?
  diags="$(printf '%s' "$out" | grep -oE 'lint/[a-z]+/[A-Za-z]+' \
    | sort | uniq -c | python3 -c 'import sys,json;d={};[d.update({p[1]:int(p[0])}) for p in (l.split() for l in sys.stdin if len(l.split())==2)];print(json.dumps(d))' 2>/dev/null )"
  # A nonzero exit that emitted NO lint diagnostic lines means the linter itself broke.
  local ok=true
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'lint/'; then ok=false; fi
  printf '{"ok":%s,"file":%s,"lintFileExitCode":%s,"diagnostics":%s}\n' \
    "$ok" "$(printf '%s' "$file" | _oracle_json_escape)" "$rc" "${diags:-\{\}}"
}

# ── gate: the post-change objective receipts (FAIL-CLOSED on checkout/test/cmd problems) ──
# $1 wt  $2 branch  $3 file  $4 symbol  $5 testcmd_file  $6 baseline_json  $7 lintfile_cmd  $8 target_line
oracle_gate() {
  set +e   # runs tests/linters that exit nonzero by design; capture codes, never abort on them.
  local wt="${1:?wt}" branch="${2:?branch}" file="${3:?file}" symbol="${4:?symbol}"
  local testcmd_file="${5:?testcmd-file}" baseline_path="${6:?baseline}" lintfile_cmd="${7:?lintfile_cmd}"
  local target_line="${8:-}"   # original linter line for the target (Codex review-4 #4)

  # Codex review-3 #4: missing/empty test command is a HARD FAIL (eval "" exits 0 = false-pass).
  if [ ! -s "$testcmd_file" ]; then
    printf '{"ok":false,"reason":"test-command-missing","testCommandPresent":false}\n'; return 0
  fi
  local testcmd; testcmd="$(cat "$testcmd_file")"

  git -C "$wt" fetch origin main -q 2>/dev/null
  # Codex review-3 #5: checkout failure must HARD FAIL (never measure the wrong branch).
  if ! git -C "$wt" checkout "$branch" -q 2>/dev/null; then
    printf '{"ok":false,"reason":"checkout-failed","branch":%s,"currentBranch":%s}\n' \
      "$(printf '%s' "$branch" | _oracle_json_escape)" \
      "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null | _oracle_json_escape)"
    return 0
  fi
  local head mergebase diff_files diffcheck testrc
  head="$(git -C "$wt" rev-parse HEAD)"
  mergebase="$(git -C "$wt" merge-base origin/main HEAD 2>/dev/null)"
  diff_files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null \
    | python3 -c 'import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  git -C "$wt" diff --check origin/main...HEAD >/dev/null 2>&1; diffcheck=$?

  local rundir; rundir="$(dirname "$baseline_path")"
  ( cd "$wt" && eval "$testcmd" ) >"$rundir/test.log" 2>&1; testrc=$?

  # post-change lint for the file (Codex review-4 #3: capture exit code, fail closed on broken lint)
  local post postrc; post="$( ( cd "$wt" && eval "$lintfile_cmd" ) 2>&1 )"; postrc=$?
  if [ "$postrc" -ne 0 ] && ! printf '%s' "$post" | grep -q 'lint/'; then
    printf '{"ok":false,"reason":"post-lint-failed","lintFileExitCode":%s,"tail":%s}\n' \
      "$postrc" "$(printf '%s' "$post" | tail -5 | _oracle_json_escape)"; return 0
  fi
  # Locate the target by the ORIGINAL linter line; fall back to a symbol grep.
  # Codex review-4 #4: if we CANNOT locate it, FAIL CLOSED — do NOT default cleared=true.
  local sym_line=""
  if [ -n "$target_line" ] && printf '%s' "$target_line" | grep -qE '^[0-9]+$'; then
    sym_line="$target_line"
  elif [ -n "$symbol" ]; then
    # Fallback grep MUST be anchored on the symbol (Codex review-4 #4): a declaration of
    # THIS symbol as function/method/const-arrow/class. Bare `function`/`const` branches
    # would match any line → false target-cleared, so every branch contains the symbol.
    local sq; sq="$(printf '%s' "$symbol" | sed 's/[][\.^$*+?(){}|/]/\\&/g')"
    sym_line="$(grep -nE "((async[[:space:]]+)?function[[:space:]]+$sq[[:space:]]*[(<]|(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+$sq\b|\b$sq[[:space:]]*[:=][[:space:]]*(async[[:space:]]*)?\(|\b$sq[[:space:]]*\([^)]*\)[[:space:]]*[:{]|class[[:space:]]+$sq\b)" "$wt/$file" 2>/dev/null | head -1 | cut -d: -f1)"
  fi
  if [ -z "$sym_line" ]; then
    printf '{"ok":false,"reason":"target-symbol-unlocatable","symbol":%s,"file":%s,"note":"Cannot locate the target by line or symbol; refusing to default targetDiagnosticCleared=true."}\n' \
      "$(printf '%s' "$symbol" | _oracle_json_escape)" "$(printf '%s' "$file" | _oracle_json_escape)"; return 0
  fi
  # target complexity diagnostic still present near the target line?
  local target_cleared=true
  if printf '%s' "$post" | grep -q 'noExcessiveCognitiveComplexity'; then
    while read -r dl; do
      [ -n "$dl" ] && [ "$(( dl>sym_line ? dl-sym_line : sym_line-dl ))" -le 5 ] && target_cleared=false
    done < <(printf '%s' "$post" | grep -oE ":[0-9]+:[0-9]+ lint/complexity/noExcessiveCognitiveComplexity" | grep -oE '^:[0-9]+' | tr -d ':' )
  fi
  # baseline-relative NEW diagnostics (Codex review-2 #9)
  local new_diags
  new_diags="$(printf '%s' "$post" | grep -oE 'lint/[a-z]+/[A-Za-z]+' | sort | uniq -c | python3 -c '
import sys,json,os
base=json.load(open(sys.argv[1])).get("diagnostics",{}) if os.path.exists(sys.argv[1]) else {}
now={}
for l in sys.stdin:
    p=l.split()
    if len(p)==2: now[p[1]]=int(p[0])
print(sum(max(0, now.get(k,0)-base.get(k,0)) for k in now))' "$baseline_path" 2>/dev/null )"
  printf '{"ok":true,"testCommandPresent":true,"commitSha":"%s","branch":%s,"head":"%s","mergeBase":"%s","diffFiles":%s,"testExitCode":%s,"diffCheckExitCode":%s,"lintFileExitCode":%s,"targetLine":%s,"targetDiagnosticCleared":%s,"newDiagnosticsCount":%s}\n' \
    "${head:0:12}" "$(printf '%s' "$branch" | _oracle_json_escape)" "${head:0:12}" "${mergebase:0:12}" \
    "$diff_files" "$testrc" "$diffcheck" "$postrc" "${sym_line:-null}" "$target_cleared" "${new_diags:-0}"
}
