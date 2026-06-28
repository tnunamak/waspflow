#!/usr/bin/env bash
# Smoke test for lib/design-gate-ledger.sh — the design-gate meta-evaluation.
# Hermetic: builds a temp ledger, records rows, asserts the scorer's verdict.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib/design-gate-ledger.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export WASPFLOW_DG_LEDGER="$TMP/ledger.jsonl"
JQ="$(command -v jq || echo /usr/bin/jq)"

pass=0 fail=0
ok() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 — expected [$2] got [$1]"; fi; }

# empty ledger -> ok:false
got="$(dg_ledger_score | "$JQ" -r '.ok')"
ok "$got" "false" "empty ledger reports ok:false"

# record a clean LAND (oracle pass, first try, not reverted) -> correct
dg_ledger_record "t/land-clean" two-model LAND high pass true null false "clean land"
# record a LAND that FAILED the oracle -> incorrect
dg_ledger_record "t/land-broken" claude LAND high fail false null false "judge said land but oracle failed"
# record a LAND later reverted -> incorrect
dg_ledger_record "t/land-reverted" two-model LAND high pass true null true "landed then reverted"
# record a REVISE whose concern was real -> correct
dg_ledger_record "t/revise-real" codex REVISE high na false true false "caught a real miss"
# record a REVISE whose concern was NOT real (false alarm) -> incorrect
dg_ledger_record "t/revise-false" codex REVISE medium na false false false "false alarm"
# record a DONT correctly refusing a bad swing -> correct
dg_ledger_record "t/dont-correct" two-model DONT high na false true false "correctly refused churn"

report="$(dg_ledger_score)"
ok "$(echo "$report" | "$JQ" -r '.total_rows')" "6" "total_rows counts every row"
ok "$(echo "$report" | "$JQ" -r '.scored')" "6" "all six rows are scorable (LAND via oracle, REVISE/DONT via concern_real)"
ok "$(echo "$report" | "$JQ" -r '.correct')" "3" "3 correct: land-clean + revise-real + dont-correct"
ok "$(echo "$report" | "$JQ" -r '.landed_clean_first_try')" "1" "only land-clean is a clean first-try LAND"
ok "$(echo "$report" | "$JQ" -r '.caught_real_issues')" "2" "revise-real + dont-correct caught real issues"
# accuracy = 3/6 = 0.5
ok "$(echo "$report" | "$JQ" -r '.accuracy')" "0.5" "accuracy is correct/scored = 0.5"

# round-trip: every recorded line is valid JSON
badjson="$("$JQ" -c . "$WASPFLOW_DG_LEDGER" >/dev/null 2>&1 && echo ok || echo bad)"
ok "$badjson" "ok" "every ledger line is valid JSON"

echo "design-gate-ledger smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
