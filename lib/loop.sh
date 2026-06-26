#!/usr/bin/env bash
# loop.sh — the GATED ENGINEERING LOOP engine for waspflow.
#
# THE STRUCTURAL ENFORCEMENT: this engine runs in ITS OWN process. The objective
# oracle (lib/loop-oracle.sh) runs here, in bash — no agent in the command path,
# so the facts are un-fakeable. Agents (driven via waspflow spawn/wait/reap) do
# ONLY the irreducibly-semantic steps: classify, make, judge-the-diff, judge-ambition.
# The loop GATES on the oracle's facts, never on an agent's claim.
#
# A PROFILE (a sourced .sh, e.g. profiles/refactor.sh) fills the task slots:
#   profile_lint_cmd            → repo-wide linter command (prints biome output)
#   profile_lint_file_cmd FILE  → linter for one file
#   profile_classify_prompt RAWJSON INTENT   → the classify-and-rank agent prompt
#   profile_make_prompt TARGETJSON REPORT    → the maker agent prompt (writes REPORT)
#   profile_revise_prompt TARGETJSON FACTS SEM REPORT
#   profile_check_prompt TARGETJSON BRANCH FACTS REPORT
#   profile_done_prompt TARGETJSON FACTS HARDLIST INTENT REPORT
#   profile_select_target CLASSIFY_JSON      → echoes the chosen target JSON (highest value, safe)
#   profile_test_cmd TARGETJSON              → the shell test command for the touched file
# The engine owns control flow, gating, fail-closed, and the run report.

set -uo pipefail
_LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LOOP_DIR/loop-oracle.sh"

# Read field from a JSON string on stdin.
_loop_jget() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1" 2>/dev/null; }
_loop_jbool() { [ "$(_loop_jget "$1")" = "True" ]; }

# Drive ONE semantic agent IN THE TARGET WORKTREE. spawn --cwd $wt --report, wait,
# read report, reap. Echoes report content. The --cwd is the Codex review-4 #1 fix:
# without it the maker/checker could edit/read a DIFFERENT checkout than the oracle
# measures. Model/effort forwarded so checker strength is ENFORCED, not just prompted.
# $1 wt  $2 lane  $3 provider  $4 report-path  $5 prompt  [$6 model]  [$7 effort]
loop_run_agent() {
  local wt="$1" lane="$2" provider="$3" report="$4" prompt="$5" model="${6:-}" effort="${7:-}"
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

# The structural gate: PASS iff the ORACLE facts AND the semantic verdict are all good.
# $1 facts-json  $2 sem-json
loop_gate_passed() {
  local f="$1" s="$2"
  [ "$(printf '%s' "$f" | _loop_jget testExitCode)" = "0" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget diffCheckExitCode)" = "0" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget targetDiagnosticCleared)" = "True" ] || return 1
  [ "$(printf '%s' "$f" | _loop_jget newDiagnosticsCount)" = "0" ] || return 1
  printf '%s' "$f" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if isinstance(d.get("diffFiles"),list) and len(d["diffFiles"])>0 else 1)' || return 1
  [ "$(printf '%s' "$s" | _loop_jget behaviorPreserving)" = "True" ] || return 1
  [ "$(printf '%s' "$s" | _loop_jget methodologyAligned)" = "True" ] || return 1
  [ "$(printf '%s' "$s" | _loop_jget callerCountsVerified)" = "True" ] || return 1
  [ "$(printf '%s' "$s" | _loop_jget surfaceUnchanged)" = "True" ] || return 1
  local ev; ev="$(printf '%s' "$s" | _loop_jget evidence)"; [ "${#ev}" -gt 80 ] || return 1
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

# Ground a target's line against the RAW ORACLE FINDINGS (Codex review-5 #1): the
# agent-carried line is NOT trusted. Echoes the oracle's line iff the target matches a
# raw finding on (file, line, AND complexity) — complexity is included so the agent
# can't point at a REAL finding's line while mislabeling its severity. Echoes empty
# otherwise (→ fail closed). $1 raw-findings-json  $2 target-json
_loop_ground_target_line() {
  printf '%s\t%s' "$1" "$2" | python3 -c '
import json,sys
raw_s, tgt_s = sys.stdin.read().split("\t", 1)
try: raw=json.loads(raw_s); tgt=json.loads(tgt_s)
except Exception: print(""); sys.exit(0)
f, ln, cx = tgt.get("file"), tgt.get("line"), tgt.get("complexity")
for r in (raw if isinstance(raw,list) else []):
    if r.get("file")==f and str(r.get("line"))==str(ln) and (cx is None or str(r.get("complexity"))==str(cx)):
        print(r["line"]); break
else:
    print("")  # no oracle finding at this (file,line[,complexity]) → caller fails closed
' 2>/dev/null
}

# The loop. $1 worktree  $2 intent  $3 provider  (profile already sourced)
loop_run() {
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

  # S2 CLASSIFY+RANK (agent classifies the ORACLE'S findings; fail-closed if under-covered)
  local clsrep="$rundir/classify.json"
  local cls; cls="$(loop_run_agent "$wt" "loop-classify-$rid" "$provider" "$clsrep" "$(profile_classify_prompt "$raw" "$intent")" "$LOOP_MAKER_MODEL" "$LOOP_MAKER_EFFORT")"
  # The agent writes JSON to the report; parse it.
  local covered hard
  covered="$(printf '%s' "$cls" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read()); print(len(d.get("classified",[])))
except: print(0)')"
  hard="$(printf '%s' "$cls" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read()); print(len(d.get("hardAreasInspected",[])))
except: print(0)')"
  if [ "${covered:-0}" -lt "$(( rawcount * 8 / 10 ))" ] || [ "${hard:-0}" -lt 3 ]; then
    _loop_fail "classification-fail-closed" "Classify covered $covered/$rawcount findings, $hard hard areas — under-reach guard tripped."; return 0
  fi
  # Select the highest-value SAFE target (profile decides ranking).
  local target; target="$(printf '%s' "$cls" | profile_select_target)"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    _loop_fail "non-finding" "No safe-incidental target cleared the bar. Full classified map in $clsrep. (Honest non-finding — the gate working.)"; return 0
  fi
  local tfile tsym tline
  tfile="$(printf '%s' "$target" | _loop_jget file)"; tsym="$(printf '%s' "$target" | _loop_jget symbol)"
  # Codex review-5 #1: the agent-carried line is NOT trusted. Ground it against the RAW
  # ORACLE FINDINGS; if no raw finding matches (file,line), the agent invented/mis-copied
  # it → FAIL CLOSED. (Same fn the smoke suite exercises — one source of truth.)
  tline="$(_loop_ground_target_line "$raw" "$target")"
  if [ -z "$tline" ]; then
    _loop_fail "target-not-oracle-grounded" "Selected target $tfile::$tsym claims line '$(printf '%s' "$target" | _loop_jget line)' but NO raw oracle finding matches (file,line). The agent invented or mis-copied the line; refusing to measure an unverified location."; return 0
  fi
  log "loop: target = $tfile::$tsym @ oracle-line $tline (highest-value safe, oracle-grounded)"

  # baseline (oracle) + write the test command to a file (engine-owned, not agent)
  local baseline="$rundir/baseline.json" testcmd_file="$rundir/testcmd.sh"
  oracle_baseline "$wt" "$tfile" "$(profile_lint_file_cmd "$tfile")" > "$baseline"
  profile_test_cmd "$target" > "$testcmd_file"

  # S3..S6 MAKE → ORACLE → SEMANTIC CHECK → bounded REVISE
  local facts="" sem="" makerep branch attempt
  for attempt in 1 2 3; do
    makerep="$rundir/make-$attempt.md"
    local mprompt
    if [ "$attempt" -eq 1 ]; then mprompt="$(profile_make_prompt "$target" "$makerep")"
    else mprompt="$(profile_revise_prompt "$target" "$facts" "$sem" "$makerep")"; fi
    local mout; mout="$(loop_run_agent "$wt" "loop-make-$rid-$attempt" "$provider" "$makerep" "$mprompt" "$LOOP_MAKER_MODEL" "$LOOP_MAKER_EFFORT")"
    branch="$(printf '%s' "$mout" | grep -oE 'refactor/[a-z0-9._-]+' | head -1)"
    [ -z "$branch" ] && branch="waspflow/loop-make-$rid-$attempt"  # waspflow's own lane branch as fallback

    # ORACLE gate (engine process — un-fakeable)
    facts="$(oracle_gate "$wt" "$branch" "$tfile" "$tsym" "$testcmd_file" "$baseline" "$(profile_lint_file_cmd "$tfile")" "$tline")"

    # SEMANTIC check (stronger model judges the diff; objective facts handed in, not asked for)
    local semrep="$rundir/check-$attempt.json"
    sem="$(loop_run_agent "$wt" "loop-check-$rid-$attempt" "$LOOP_CHECKER_PROVIDER" "$semrep" "$(profile_check_prompt "$target" "$branch" "$facts" "$semrep")" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"

    if loop_gate_passed "$facts" "$sem"; then break; fi
    printf '%s' "$mout" | grep -qiE '\babandon\b' && break
    printf '%s' "$facts" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if isinstance(d.get("diffFiles"),list) and d["diffFiles"] else 1)' || break
  done

  # S7 DONE/AMBITION gate + report
  if loop_gate_passed "$facts" "$sem"; then
    local hardlist donerep done
    hardlist="$(printf '%s' "$cls" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read()); print(", ".join(f["symbol"] for f in d.get("classified",[]) if f.get("classification")!="safe-incidental")[:200])
except: print("")')"
    donerep="$rundir/done.json"
    done="$(loop_run_agent "$wt" "loop-done-$rid" "$LOOP_CHECKER_PROVIDER" "$donerep" "$(profile_done_prompt "$target" "$facts" "$hardlist" "$intent" "$donerep")" "$LOOP_CHECKER_MODEL" "$LOOP_CHECKER_EFFORT")"
    local dv; dv="$(printf '%s' "$done" | _loop_jget verdict)"
    if [ "$dv" = "complete-and-commensurate" ]; then
      printf '{"outcome":"change-passed-gate","target":"%s","facts":%s,"reportDir":"%s","note":"Passed deterministic oracle + stronger-model semantic check + done/ambition gate. Open a tight PR; owner reviews; no merge/deploy."}\n' \
        "$tfile::$tsym" "$facts" "$rundir"
    else
      printf '{"outcome":"complete-but-under-ambitious","target":"%s","done":%s,"reportDir":"%s","note":"A safe change passed BUT under-ambitious vs the ask. Surface to owner; do not present as satisfying the big ask."}\n' \
        "$tfile::$tsym" "$done" "$rundir"
    fi
  else
    printf '{"outcome":"rejected-or-stopped","target":"%s","facts":%s,"sem":%s,"reportDir":"%s","note":"Target did not pass the gate. Honest result (gate working)."}\n' \
      "$tfile::$tsym" "$facts" "$sem" "$rundir"
  fi
}
