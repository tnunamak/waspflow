#!/usr/bin/env bash
# loop.sh — the GATED ENGINEERING LOOP engine for waspflow.
#
# THE STRUCTURAL ENFORCEMENT: this engine runs in ITS OWN process. The objective
# oracle (lib/loop-oracle.sh) runs here, in bash — no agent in the command path,
# so the facts are un-fakeable. Agents (driven via waspflow spawn/wait/reap) do
# ONLY the irreducibly-semantic steps: make-the-change, judge-the-diff, judge-ambition.
# The loop GATES on the oracle's facts; an agent's contribution is ONE fail-closed sentinel
# token (ABANDON / VERDICT: LAND|REVISE / DONE|CONTINUE|ESCALATE) + prose — never telemetry.
#
# DECOMPLECTED (Claude+Codex SLVP-ideal): there is NO classify agent. Target selection is
# DETERMINISTIC in the engine over the oracle's raw findings (highest complexity not in a
# no-go path-glob). Strict schemas live ONLY at deterministic boundaries (oracle output,
# repo config), never between a model and a parser.
#
# A PROFILE (a sourced .sh, e.g. profiles/refactor.sh) fills the task slots:
#   profile_lint_cmd            → repo-wide linter command (prints biome output)
#   profile_lint_file_cmd FILE  → linter for one file
#   profile_select_target       → reads ORACLE findings JSON on stdin, echoes ONE target JSON
#   profile_test_cmd TARGETJSON → the deterministic test command for the touched file
#   profile_make_prompt TARGETJSON REPORT          → maker prompt (writes a branch diff or ABANDON:)
#   profile_revise_prompt TARGETJSON FACTS VERDICT REPORT
#   profile_check_prompt TARGETJSON BRANCH FACTS REPORT   → checker prompt (ends VERDICT: LAND|REVISE)
#   profile_done_prompt TARGETJSON FACTS REMAINING INTENT REPORT  → ends DONE|CONTINUE|ESCALATE
# The engine owns control flow, gating, fail-closed, and the run report.

set -uo pipefail
_LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LOOP_DIR/loop-oracle.sh"

# Read field from a JSON string on stdin.
_loop_jget() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1" 2>/dev/null; }
_loop_jbool() { [ "$(_loop_jget "$1")" = "True" ]; }

# Universal NON-INTERACTIVE WORKER preamble prepended to EVERY loop agent prompt.
# Dogfood finding: a capable model dropped into a rich repo, given a task but no
# worker framing, will INTERVIEW the "user" (build a menu, ask "what do you want?")
# instead of executing. The loop has no human in the lane — asking = a dead lane.
# This is a loop invariant, so it lives at the engine layer (one source of truth),
# not duplicated per profile prompt.
_LOOP_WORKER_PREAMBLE='You are a NON-INTERACTIVE WORKER in an automated loop. There is NO human in this session to answer questions. Do the task in this message NOW, autonomously, using the repo you are in. Do NOT ask for confirmation, do NOT present options or a menu, do NOT wait for input — if something is ambiguous, make the most reasonable assumption and proceed. Your ONLY deliverable is to write the requested file; when it is written, stop. Ignore the branch name, commit history, and any dogfooding/feedback notes — they are not your task. THE TASK:

'

# Drive ONE semantic agent IN THE TARGET WORKTREE. spawn --cwd $wt --report, wait,
# read report, reap. Echoes report content. The --cwd is the Codex review-4 #1 fix:
# without it the maker/checker could edit/read a DIFFERENT checkout than the oracle
# measures. Model/effort forwarded so checker strength is ENFORCED, not just prompted.
# Every prompt is prefixed with the non-interactive worker preamble.
# $1 wt  $2 lane  $3 provider  $4 report-path  $5 prompt  [$6 model]  [$7 effort]
loop_run_agent() {
  local wt="$1" lane="$2" provider="$3" report="$4" prompt="$5" model="${6:-}" effort="${7:-}"
  prompt="${_LOOP_WORKER_PREAMBLE}${prompt}"
  local -a spawn_args=(spawn --provider "$provider" --lane "$lane" --cwd "$wt" --report "$report")
  [ -n "$model" ] && spawn_args+=(--model "$model")
  [ -n "$effort" ] && spawn_args+=(--effort "$effort")
  spawn_args+=(-- "$prompt")
  "$_LOOP_DIR/../bin/waspflow" "${spawn_args[@]}" >&2 || return 1
  "$_LOOP_DIR/../bin/waspflow" wait "$lane" --timeout "${LOOP_AGENT_TIMEOUT:-1200}" >&2 || true
  local out=""; [ -f "$report" ] && out="$(cat "$report")"
  "$_LOOP_DIR/../bin/waspflow" reap "$lane" --keep-worktree >&2 2>/dev/null || true
  printf '%s' "$out"
}

# Extract a fail-closed SENTINEL token from an agent's prose report. Matches a line of
# the form "<KEY>: <TOKEN>" (e.g. "VERDICT: LAND", "DONE") where TOKEN ∈ the allowed set.
# Decomplected design: the engine parses ONLY this one token, never agent telemetry. A
# missing/ambiguous token returns empty → caller fails closed.
# $1 prose  $2 key (e.g. VERDICT, or "" for a bare token)  $3.. allowed tokens
_loop_sentinel() {
  local prose="$1" key="$2"; shift 2
  local allowed=" $* "
  # Prefer "KEY: TOKEN"; for bare tokens (key empty) match a standalone allowed word.
  local tok
  if [ -n "$key" ]; then
    tok="$(printf '%s' "$prose" | grep -oiE "${key}:[[:space:]]*[A-Za-z_]+" | tail -1 | sed -E "s/.*:[[:space:]]*//" | tr '[:lower:]' '[:upper:]')"
  else
    tok="$(printf '%s' "$prose" | grep -owiE "$(printf '%s' "$*" | tr ' ' '|')" | tail -1 | tr '[:lower:]' '[:upper:]')"
  fi
  case "$allowed" in *" $tok "*) printf '%s' "$tok" ;; *) printf '' ;; esac
}

# The OBJECTIVE half of the gate: the oracle facts alone. The checker LAND verdict is a
# SEPARATE, ADDITIONAL requirement (Codex: "VERDICT: LAND alone never lands; oracle pass
# remains mandatory"). $1 facts-json
loop_oracle_passed() {
  local f="$1"
  [ "$(printf '%s' "$f" | _loop_jget ok)" = "True" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget testExitCode)" = "0" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget diffCheckExitCode)" = "0" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget targetDiagnosticCleared)" = "True" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget newDiagnosticsCount)" = "0" ] || return 1
  printf '%s' "$f" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)   # empty/malformed facts → fail closed, never crash
sys.exit(0 if isinstance(d.get("diffFiles"),list) and len(d["diffFiles"])>0 else 1)' 2>/dev/null || return 1
  return 0
}

# Emit a fail-closed outcome JSON. $1 outcome  $2 note
_loop_fail() { printf '{"outcome":"%s","note":%s}\n' "$1" "$(printf '%s' "$2" | _oracle_json_escape)"; }

# Classify a provider/model/effort into a normalized FAMILY and capability RANK.
# Family ∈ {gpt, opus, sonnet, unknown} — the lineage that the "different lineage"
# rule compares (Codex review-5 #2: must compare families, NOT raw strings, else
# opus-high vs opus-xhigh would read as different lineage). ONE source of truth.
# Rank (owner table): gpt high=6 > opus xhigh=5 > gpt low=4 > opus high=3 > opus low=2 > sonnet=1.
# Prints "<family> <rank>".
_loop_classify_model() {
  python3 -c '
import sys
prov, model, eff = (sys.argv[1] or "").lower(), (sys.argv[2] or "").lower(), (sys.argv[3] or "medium").lower()
# Explicit known families ONLY; everything else → unknown (which fails closed in the gate).
# A bare "claude" provider with NO model is opus lineage (the default Claude tier here).
if ("codex" in prov) or ("gpt" in model): fam="gpt"
elif "sonnet" in model: fam="sonnet"
elif "opus" in model: fam="opus"
elif prov=="claude" and not model: fam="opus"
else: fam="unknown"   # haiku, fable, future/unrecognized → unknown → checker rejected
hi = eff in ("high","xhigh","max")
if fam=="gpt":    rank = 6 if hi else 4
elif fam=="opus": rank = 5 if eff in ("xhigh","max") else (3 if hi else 2)
elif fam=="sonnet": rank = 1
else: rank = 0   # unknown is the WEAKEST rank — never qualifies as a checker
print(fam, rank)' "$1" "$2" "$3"
}
_loop_caprank() { _loop_classify_model "$1" "$2" "$3" | awk '{print $2}'; }
_loop_family()  { _loop_classify_model "$1" "$2" "$3" | awk '{print $1}'; }

# NOTE: target selection is now DETERMINISTIC in the engine (profile_select_target over
# the oracle's raw findings), so the target line is oracle-sourced by construction — there
# is no agent-carried line to ground. The old _loop_ground_target_line is deleted with the
# classify agent (decomplected design).

# The loop. $1 worktree  $2 intent  $3 provider  (profile already sourced)
loop_run() {
  set +e   # the loop orchestrates fallible steps (linters, tests, agent spawns) and gates on
           # their captured exit codes; a caller's `set -e` (bin/waspflow has it) must not abort us.
  local wt="$1" intent="$2" provider="${3:-claude}"
  local rid; rid="$(date +%s)-$$"
  local rundir; rundir="$(oracle_run_dir "$rid")"
  local report="${LOOP_REPORT:-$rundir/run-report.md}"

  # Maker/checker config (Codex review-4 #5: ENFORCE strength, do not just prompt it).
  local LOOP_MAKER_MODEL="${LOOP_MAKER_MODEL:-}" LOOP_MAKER_EFFORT="${LOOP_MAKER_EFFORT:-}"
  local LOOP_CHECKER_PROVIDER="${LOOP_CHECKER_PROVIDER:-$provider}"
  local LOOP_CHECKER_MODEL="${LOOP_CHECKER_MODEL:-}" LOOP_CHECKER_EFFORT="${LOOP_CHECKER_EFFORT:-}"
  local mrank crank mfam cfam
  mrank="$(_loop_caprank "$provider" "$LOOP_MAKER_MODEL" "$LOOP_MAKER_EFFORT")"
  crank="$(_loop_caprank "$LOOP_CHECKER_PROVIDER" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"
  mfam="$(_loop_family "$provider" "$LOOP_MAKER_MODEL" "$LOOP_MAKER_EFFORT")"
  cfam="$(_loop_family "$LOOP_CHECKER_PROVIDER" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"
  # Codex review-5 #2: lineage is the normalized FAMILY (gpt|opus|sonnet), NOT raw strings
  # — opus-high vs opus-xhigh are the SAME lineage and must NOT count as different.
  if [ "$crank" -lt "$mrank" ] || [ "$cfam" = "$mfam" ] || [ "$cfam" = "unknown" ]; then
    _loop_fail "checker-too-weak" "Checker ($cfam rank $crank: ${LOOP_CHECKER_PROVIDER}/${LOOP_CHECKER_MODEL:-default}/${LOOP_CHECKER_EFFORT:-medium}) must be >= maker ($mfam rank $mrank: ${provider}/${LOOP_MAKER_MODEL:-default}/${LOOP_MAKER_EFFORT:-medium}) AND a DIFFERENT lineage family. Set LOOP_CHECKER_PROVIDER/MODEL/EFFORT. (maker/checker split can't self-grade.)"
    return 0
  fi
  log "loop: maker $mfam(rank $mrank), checker $cfam(rank $crank) — strength + lineage enforced"

  # S0 PREFLIGHT (oracle, fail-closed)
  local pre; pre="$(oracle_preflight "$wt")"
  if ! printf '%s' "$pre" | _loop_jbool ok; then _loop_fail "preflight-fail-closed" "Worktree not clean+descended from origin/main: $pre"; return 0; fi
  log "loop: preflight ok"

  # S1 DISCOVER (oracle owns the linter; agent never sources the count)
  local disc; disc="$(oracle_discover "$wt" "$(profile_lint_cmd)" "$rundir")"
  if ! printf '%s' "$disc" | _loop_jbool ok; then _loop_fail "discover-fail-closed" "Linter failed or parse error: $disc"; return 0; fi
  local raw rawcount; raw="$(printf '%s' "$disc" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["result"]["findings"]))')"
  rawcount="$(printf '%s' "$disc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["rawLinterCount"])')"
  if [ "${rawcount:-0}" -eq 0 ]; then _loop_fail "no-complexity-findings" "Linter ran cleanly and found 0 over-complex functions."; return 0; fi
  log "loop: discover — $rawcount over-complex functions (oracle-sourced)"

  # S2 SELECT TARGET — DETERMINISTIC, engine-side, over the oracle's raw findings.
  # NO classify agent: pre-implementation "is this safe?" is a guess; the behavior-preserving
  # oracle gate + checker on the REAL diff are strictly stronger. no-go is path-globs (repo
  # config). The chosen line is oracle-sourced by construction.
  local target; target="$(printf '%s' "$raw" | profile_select_target)"
  if [ -z "$target" ]; then
    _loop_fail "no-eligible-target" "All $rawcount over-complex findings were excluded by no-go/vendor globs or ungroundable. Honest non-finding (the gate working)."; return 0
  fi
  local tfile tsym tline
  tfile="$(printf '%s' "$target" | _loop_jget file)"; tsym="$(printf '%s' "$target" | _loop_jget symbol)"
  tline="$(printf '%s' "$target" | _loop_jget line)"
  log "loop: target = $tfile @ line $tline (highest-complexity eligible, engine-selected)"

  # remaining eligible findings (for the ambition check + under-reach visibility).
  # NB: no f-string with escaped quotes inside python3 -c '...' (breaks the single-quote block).
  local remaining; remaining="$(printf '%s' "$raw" | python3 -c '
import json, sys
fs = json.load(sys.stdin)
parts = ["{}:{}(c{})".format(f.get("file"), f.get("line"), f.get("complexity")) for f in fs[:12]]
print(", ".join(parts))' 2>/dev/null)"
  [ -z "$remaining" ] && remaining="(none listed)"

  # baseline (oracle) + write the test command to a file (engine-owned, not agent)
  local baseline="$rundir/baseline.json" testcmd_file="$rundir/testcmd.sh"
  oracle_baseline "$wt" "$tfile" "$(profile_lint_file_cmd "$tfile")" > "$baseline"
  profile_test_cmd "$target" > "$testcmd_file"

  # S3..S6 MAKE → ORACLE → CHECK(sentinel) → bounded REVISE.
  # A change LANDS iff: oracle passes AND checker says VERDICT: LAND. Either missing → no land.
  local facts="" checkprose="" verdict="" makeprose branch attempt landed=0
  for attempt in 1 2 3; do
    makerep="$rundir/make-$attempt.md"
    local mprompt
    if [ "$attempt" -eq 1 ]; then mprompt="$(profile_make_prompt "$target" "$makerep")"
    else mprompt="$(profile_revise_prompt "$target" "$facts" "$checkprose" "$makerep")"; fi
    makeprose="$(loop_run_agent "$wt" "loop-make-$rid-$attempt" "$provider" "$makerep" "$mprompt" "$LOOP_MAKER_MODEL" "$LOOP_MAKER_EFFORT")"

    # Maker abandon sentinel → stop this target.
    if printf '%s' "$makeprose" | grep -qiE '^[[:space:]]*ABANDON:'; then
      _loop_fail "maker-abandoned" "Maker abandoned $tfile:$tline after attempt $attempt: $(printf '%s' "$makeprose" | grep -iE 'ABANDON:' | head -1). Next: engine would select the next deterministic target (or ESCALATE after repeated abandons)."; return 0
    fi
    branch="$(printf '%s' "$makeprose" | grep -oE 'refactor/[a-z0-9._-]+' | head -1 | sed 's/[._-]*$//')"
    # If the maker didn't name a refactor/ branch in prose, discover what it actually committed:
    # the highest-priority is a branch that descends from origin/main and isn't main itself.
    if [ -z "$branch" ]; then
      branch="$(git -C "$wt" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
        | while read -r b; do
            [ "$b" = "main" ] && continue
            if git -C "$wt" merge-base --is-ancestor origin/main "$b" 2>/dev/null \
               && [ -n "$(git -C "$wt" rev-list origin/main.."$b" 2>/dev/null | head -1)" ]; then echo "$b"; fi
          done | grep -E '^(refactor|waspflow)/' | head -1)"
    fi
    [ -z "$branch" ] && branch="waspflow/loop-make-$rid-$attempt"  # last-resort fallback

    # ORACLE gate (engine process — un-fakeable). MANDATORY: VERDICT: LAND alone never lands.
    facts="$(oracle_gate "$wt" "$branch" "$tfile" "$tsym" "$testcmd_file" "$baseline" "$(profile_lint_file_cmd "$tfile")" "$tline")"
    if ! loop_oracle_passed "$facts"; then
      # oracle failed — only revise if there's actually a diff to fix; else stop.
      printf '%s' "$facts" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if isinstance(d.get("diffFiles"),list) and d["diffFiles"] else 1)' || break
      verdict=""; continue
    fi

    # CHECK (stronger/different model) reads the REAL diff; emits VERDICT: LAND|REVISE.
    checkprose="$(loop_run_agent "$wt" "loop-check-$rid-$attempt" "$LOOP_CHECKER_PROVIDER" "$rundir/check-$attempt.md" "$(profile_check_prompt "$target" "$branch" "$facts" "$rundir/check-$attempt.md")" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"
    verdict="$(_loop_sentinel "$checkprose" VERDICT LAND REVISE)"
    if [ "$verdict" = "LAND" ]; then landed=1; break; fi
    # REVISE or missing/ambiguous (fail-closed) → loop to revise.
  done

  # S7 — outcome. Land requires BOTH oracle pass AND checker LAND.
  if [ "$landed" -ne 1 ]; then
    _loop_fail "rejected-or-stopped" "Target $tfile:$tline did not land. Oracle facts: $facts. Checker verdict: ${verdict:-<none/ambiguous → fail-closed>}. Honest result (the gate working). reportDir: $rundir"; return 0
  fi

  # DONE/AMBITION — loop control ONLY (cannot rescue a failed gate; the gate already passed).
  local doneprose decision
  doneprose="$(loop_run_agent "$wt" "loop-done-$rid" "$LOOP_CHECKER_PROVIDER" "$rundir/done.md" "$(profile_done_prompt "$target" "$facts" "$remaining" "$intent" "$rundir/done.md")" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"
  decision="$(_loop_sentinel "$doneprose" "" DONE CONTINUE ESCALATE)"
  [ -z "$decision" ] && decision="DONE"   # missing ambition token does NOT unland a passed change; default DONE
  printf '{"outcome":"change-landed","target":"%s","branch":"%s","ambition":"%s","facts":%s,"reportDir":"%s","note":"Passed deterministic oracle AND stronger-model checker LAND. Ambition: %s. Open a tight PR; owner reviews; no merge/deploy."}\n' \
    "$tfile:$tline" "$branch" "$decision" "$facts" "$rundir" "$decision"
}
