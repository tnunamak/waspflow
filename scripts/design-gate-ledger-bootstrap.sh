#!/usr/bin/env bash
# Bootstrap the design-gate ledger with the REAL verdict→outcome history from
# the PDPP SLVP-Q sweep (2026-06-27). Every row below is an honest record of a
# two-model design-gate decision and what the DETERMINISTIC ORACLE then showed.
# Run: WASPFLOW_DG_LEDGER=<path> bash scripts/design-gate-ledger-bootstrap.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/design-gate-ledger.sh
source "$HERE/lib/design-gate-ledger.sh"

: "${WASPFLOW_DG_LEDGER:=$HERE/tmp/design-gate-ledger.jsonl}"
export WASPFLOW_DG_LEDGER
: > "$WASPFLOW_DG_LEDGER"  # fresh

# dg_ledger_record <swing> <judge> <verdict> <confidence> <oracle> <first_try> <concern_real> <reverted> [note]

# --- browser-surface boundary (swing #1) ---
dg_ledger_record "browser-surface/run-coordinator-facade" two-model LAND 90 pass true null false \
  "Codex 90% the boundary+first-move were right; controller scatter→facade; oracle green."

# --- scheduler kernel (swing #2): pre-run-gate / dispatch-governor / run-executor ---
dg_ledger_record "scheduler/pre-run-gate" two-model LAND high pass true null false \
  "Both picked it first independently; oracle tsc0+163 tests; narrow-deps verified."
dg_ledger_record "scheduler/dispatch-governor" two-model LAND high pass true null false \
  "Highest-blast-radius rate-governance; oracle tsc0+146 tests; probe bodies moved IN."
dg_ledger_record "scheduler/run-executor" two-model LAND high pass true null false \
  "Highest coupling; 15 narrow deps (schedulerStore Pick-narrowed); oracle tsc0+146 tests."
# Codex's REVISE-equivalent: re-verify caught an ADJACENT web-push source-invariant test the
# maker oracle missed. Concern was REAL (a real miss), fixed on branch (f8ea945da).
dg_ledger_record "scheduler/web-push-adjacent-test" codex REVISE high fail false true false \
  "Codex re-verify caught onStarted moved files → web-push source-scan test broke; real miss; fixed."
# Codex also flagged the FALSE ratchet claim — a REVISE on an evidence overclaim. Concern REAL.
dg_ledger_record "scheduler/false-ratchet-claim" codex REVISE high na false true false \
  "Codex caught 'ratchet added' claim was false (local config, not CI-wired); concern real; corrected."

# --- neko-allocator + CDP-readiness package moves (swing #1 cont.) ---
dg_ledger_record "remote-surface/neko-allocator" two-model LAND high pass true null false \
  "Codex A-narrow verdict; already package-neutral; oracle pkg218+RI30 via shim; 0 RI back-dep."
dg_ledger_record "remote-surface/cdp-readiness" two-model LAND high pass true null false \
  "Codex named follow-on; oracle pkg218+RI34 via shim; pure-move (0 code-diff)."

# --- ratchets made real (swing #4) ---
dg_ledger_record "arch-gate/ratchets-real" claude LAND high pass true null false \
  "Mechanical, repo-convention; hermetic test 9/9 + scanner exit0; auto-discovered by run-tests.js."

# --- controller→spine layer cut (swing #3 first target) ---
dg_ledger_record "controller/runtime-no-direct-storage" two-model LAND high pass true null false \
  "Codex named target (NOT _route-contract); verified getRunTerminalStatus equiv; oracle tsc0+45 tests."

# --- PREMISE-CHECKS where the judge's job was to SAY NO (verdict=DONT, concern_real=true). ---
# These are the highest-value judge calls: correctly refusing a bad swing.
dg_ledger_record "cycles/break-server-cycles" two-model DONT high na false true false \
  "Premise WRONG: 6 cycles was a measurement artifact; 2 are mitigated lazy import() cycles; TRUE static=0/220. Correctly refused (would've churned auth.js invalidConnectorManifest×94)."
dg_ledger_record "browser-surface/3-state-split" two-model DONT high na false true false \
  "Ground-truthed: no fat 'session' god-type left after consolidation; Codex agreed; correctly refused inventing a boundary."
dg_ledger_record "storage/hub-split" two-model DONT high na false true false \
  "Corrected numbers (db.ts ~170 importers); hubs are legitimately-shared primitives; Codex high-conviction DONT; correctly refused high-blast-radius churn."

echo "bootstrapped $(wc -l < "$WASPFLOW_DG_LEDGER") rows → $WASPFLOW_DG_LEDGER"
