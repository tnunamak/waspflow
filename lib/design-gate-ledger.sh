#!/usr/bin/env bash
# design-gate-ledger.sh — meta-evaluation of the two-model design gate.
#
# WHY THIS EXISTS (the literature gap we close):
# The LLM-judge literature (JudgeBench ICLR'25, RubricEval, Meta-Rewarding) is
# blunt: LLM judges are weak alone, a judge's accuracy correlates with its own
# ability to solve the task, and you must META-EVALUATE the judge itself rather
# than trust it. Our gated loop keeps the judge OFF the critical path (the
# deterministic oracle — tsc/tests/dependency-cruiser/diff-check — is the
# load-bearing signal; the design judge only answers the one semantic question
# "is this the concept-correct boundary"). But until now we never SCORED the
# design judge. This makes "do we trust the design gate" a MEASUREMENT.
#
# THE GROUND TRUTH the judge is scored against is the DETERMINISTIC ORACLE
# OUTCOME, not human opinion — same principle as JudgeBench scoring judges
# against objective correctness. A gate verdict of LAND is "correct" when the
# maker's work then passed the oracle on first try and was not later reverted.
# A REVISE / DONT verdict is "correct" when the concern it raised was real
# (a different-model re-review or the oracle later confirmed the issue).
#
# Each row is appended at the moment we KNOW the outcome (after the oracle runs
# / after a re-review), so the ledger accumulates honest verdict→outcome pairs.
#
# Storage: JSONL at ${WASPFLOW_DG_LEDGER:-$PWD/.waspflow/design-gate-ledger.jsonl}
# Every function does `set +e` for set-e immunity (matches loop-oracle.sh).

# Resolve jq once. Functions may run in subshells whose PATH differs; cache an
# absolute path so the ledger works regardless of the caller's PATH.
_dg_jq() {
  set +e
  if [ -n "${_DG_JQ:-}" ]; then "$_DG_JQ" "$@"; return; fi
  _DG_JQ="$(command -v jq 2>/dev/null)"
  [ -z "$_DG_JQ" ] && for c in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq /home/linuxbrew/.linuxbrew/bin/jq; do
    [ -x "$c" ] && { _DG_JQ="$c"; break; }
  done
  if [ -z "$_DG_JQ" ]; then echo '{"ok":false,"reason":"jq-not-found"}' >&2; return 127; fi
  "$_DG_JQ" "$@"
}

# --- row schema (one JSON object per line) -----------------------------------
# {
#   "swing":        "<short id, e.g. scheduler/pre-run-gate>",
#   "judge":        "codex|claude|two-model",   # who issued the design verdict
#   "verdict":      "LAND|REVISE|DONT",          # the design-gate decision
#   "confidence":   "high|medium|low|<pct>",     # judge's stated confidence (optional)
#   "oracle":       "pass|fail|na",              # deterministic oracle result on the maker's work
#   "first_try":    true|false,                  # did the oracle pass on the FIRST maker attempt
#   "concern_real": true|false|null,             # for REVISE/DONT: was the raised concern real
#   "reverted":     true|false,                  # was the landed work later reverted
#   "note":         "<freeform>"
# }
# A verdict is scored CORRECT when:
#   LAND        -> oracle==pass && first_try && !reverted
#   REVISE/DONT -> concern_real==true
# SCORABLE means we have ground truth for that verdict type: LAND needs oracle!="na";
# REVISE/DONT need concern_real!=null (a refusal/redirect has no maker work to gate, so
# its ground truth is whether the raised concern was real — not an oracle pass).

dg_ledger_path() {
  set +e
  printf '%s' "${WASPFLOW_DG_LEDGER:-${PWD}/.waspflow/design-gate-ledger.jsonl}"
}

# dg_ledger_record <swing> <judge> <verdict> <confidence> <oracle> <first_try> <concern_real> <reverted> [note]
# Appends one verdict→outcome row. Booleans accept true/false; concern_real also accepts null.
dg_ledger_record() {
  set +e
  local swing="$1" judge="$2" verdict="$3" confidence="$4" oracle="$5" \
        first_try="$6" concern_real="$7" reverted="$8" note="${9:-}"
  local path; path="$(dg_ledger_path)"
  # pure-bash dirname (mkdir/dirname may be off a stripped PATH; parameter expansion isn't)
  local dir="${path%/*}"; [ "$dir" = "$path" ] && dir="."
  mkdir -p "$dir" 2>/dev/null || command mkdir -p "$dir" 2>/dev/null
  # jq builds the row so strings are escaped correctly; booleans/null passed raw via --argjson.
  _dg_jq -cn \
    --arg swing "$swing" --arg judge "$judge" --arg verdict "$verdict" \
    --arg confidence "$confidence" --arg oracle "$oracle" --arg note "$note" \
    --argjson first_try "${first_try:-false}" \
    --argjson concern_real "${concern_real:-null}" \
    --argjson reverted "${reverted:-false}" \
    '{swing:$swing,judge:$judge,verdict:$verdict,confidence:$confidence,
      oracle:$oracle,first_try:$first_try,concern_real:$concern_real,
      reverted:$reverted,note:$note}' >> "$path"
}

# dg_ledger_score [path]
# Emits a JSON calibration report scoring the design judge against oracle ground truth.
dg_ledger_score() {
  set +e
  local path="${1:-$(dg_ledger_path)}"
  if [ ! -s "$path" ]; then
    printf '{"ok":false,"reason":"empty-or-missing-ledger","path":%s}\n' \
      "$(_dg_jq -Rn --arg p "$path" '$p')"
    return 0
  fi
  # A row is SCORABLE if oracle != "na" and verdict is known.
  # correct = (LAND & oracle pass & first_try & !reverted) | ((REVISE|DONT) & concern_real)
  _dg_jq -s '
    # A row is scorable when we have ground truth for its verdict type:
    #   LAND        -> needs an oracle outcome (oracle != "na").
    #   REVISE/DONT -> ground truth is whether the concern was REAL (concern_real
    #                  non-null); these legitimately have oracle=="na" because a
    #                  refusal/redirect produces no maker work for the oracle to gate.
    def scorable:
      if .verdict == "LAND" then (.oracle != "na")
      elif (.verdict == "REVISE" or .verdict == "DONT") then (.concern_real != null)
      else false end;
    def correct:
      if .verdict == "LAND" then (.oracle == "pass" and .first_try == true and (.reverted != true))
      elif (.verdict == "REVISE" or .verdict == "DONT") then (.concern_real == true)
      else false end;
    (map(select(scorable))) as $s
    | ($s | length) as $n
    | {
        ok: true,
        total_rows: length,
        scored: $n,
        unscored: (length - $n),
        correct: ($s | map(select(correct)) | length),
        accuracy: (if $n == 0 then null else (($s | map(select(correct)) | length) / $n) end),
        by_verdict: (
          $s | group_by(.verdict) | map({
            verdict: .[0].verdict,
            n: length,
            correct: (map(select(correct)) | length)
          })
        ),
        by_judge: (
          $s | group_by(.judge) | map({
            judge: .[0].judge,
            n: length,
            correct: (map(select(correct)) | length)
          })
        ),
        caught_real_issues: ($s | map(select((.verdict=="REVISE" or .verdict=="DONT") and .concern_real==true)) | length),
        landed_clean_first_try: ($s | map(select(.verdict=="LAND" and .oracle=="pass" and .first_try==true and (.reverted!=true))) | length)
      }
  ' "$path"
}
