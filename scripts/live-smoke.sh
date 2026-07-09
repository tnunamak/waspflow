#!/usr/bin/env bash
# live-smoke.sh — exercise the REAL waspflow loop against live Claude workers,
# hard and in parallel, asserting observable file changes at every step. This is
# the automated live matrix the confidence memo flagged as the gap. Claude-only
# by default (the free/available quota); pass a provider to widen.
#
# Usage: WASPFLOW_HOME=... scripts/live-smoke.sh [provider] [n_parallel]
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BF="$root/bin/waspflow"
prov="${1:-claude}"
N="${2:-4}"
scratch="${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}"
export WASPFLOW_HOME="${WASPFLOW_HOME:-$HOME/.local/state/waspflow}"

# Source core + claude adapter for the turn_mark diagnostic (best-effort).
# shellcheck disable=SC1090
source "$root/lib/core.sh" 2>/dev/null || true
# shellcheck disable=SC1090
source "$root/lib/providers/claude.sh" 2>/dev/null || true

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }

# One full lane lifecycle: spawn -> wait -> assert edit1 -> revise -> wait ->
# assert edit2 -> reap -> assert result. Runs in its own repo. Backgrounded.
one_lane() {
  local id="$1"; local lane="sm-$id"
  local d; d="$(mktemp -d "$scratch/wf-live-$id-XXXXXX")"
  ( cd "$d" && git init -q && git config user.email t@e.invalid && git config user.name T \
      && printf 'L0\n' > f.txt && git add -A && git commit -q -m init )
  local log="$d/_result"

  # spawn
  ( cd "$d" && "$BF" spawn --provider "$prov" --lane "$lane" -- \
      "Append a line reading TOKEN_A to the file f.txt in this directory, then stop. Do nothing else." ) >/dev/null 2>&1

  if ! timeout 130 "$BF" wait "$lane" --timeout 120 >/dev/null 2>&1; then
    echo "SPAWN_WAIT_TIMEOUT" > "$log"; "$BF" reap "$lane" --force >/dev/null 2>&1; echo "$d"; return
  fi
  grep -q TOKEN_A "$d/f.txt" 2>/dev/null && echo "SPAWN_OK" > "$log" || echo "SPAWN_NOEDIT" > "$log"

  # revise (the critical steer-the-live-pane path + the barrier under test)
  local mark_before mark_after
  mark_before="$(claude_turn_mark "$lane" 2>/dev/null || echo 0)"
  "$BF" revise "$lane" -- "Now append a second line reading TOKEN_B to f.txt, then stop." >/dev/null 2>&1
  if ! timeout 130 "$BF" wait "$lane" --timeout 120 >/dev/null 2>&1; then
    echo "REVISE_WAIT_TIMEOUT" >> "$log"
  fi
  # Did a NEW turn actually run? (distinguishes barrier/quota from a bad instruction)
  mark_after="$(claude_turn_mark "$lane" 2>/dev/null || echo 0)"
  [[ "${mark_after:-0}" -gt "${mark_before:-0}" ]] && echo "REVISE_TURN_RAN" >> "$log" || echo "REVISE_NO_TURN" >> "$log"
  # Throttle detection: rate-limit banner in the pane?
  "$BF" peek "$lane" --lines 40 2>/dev/null | grep -qiE 'usage limit|rate limit|resets [0-9]|/upgrade' && echo "THROTTLED" >> "$log"
  grep -q TOKEN_B "$d/f.txt" 2>/dev/null && echo "REVISE_OK" >> "$log" || echo "REVISE_NOEDIT" >> "$log"

  # reap + result contract
  local res
  res="$("$BF" reap "$lane" --force 2>&1 | grep -oE 'result=[a-z_]+' | head -1)"
  echo "REAP_${res:-none}" >> "$log"
  echo "$d"
}

echo "=== waspflow LIVE smoke: provider=$prov, $N parallel lanes ==="
echo "quota before:"; clawmeter status --agent --plain 2>/dev/null | grep -oE 'Claude 5h\([^)]*\)' | head -1

dirs=()
pids=()
for i in $(seq 1 "$N"); do
  one_lane "$i" > "$scratch/wf-live-dir-$i" &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p"; done

echo ""
echo "=== results ==="
for i in $(seq 1 "$N"); do
  d="$(cat "$scratch/wf-live-dir-$i" 2>/dev/null)"
  [[ -n "$d" && -f "$d/_result" ]] || { bad "lane $i: no result"; continue; }
  r="$(tr '\n' ',' < "$d/_result")"
  echo "  lane $i: $r"
  grep -q SPAWN_OK    "$d/_result" && ok "lane $i spawn produced edit"    || bad "lane $i spawn edit"
  grep -q REVISE_OK   "$d/_result" && ok "lane $i revise produced edit"   || bad "lane $i revise edit (STEER)"
  grep -q 'REAP_result=succeeded\|REAP_result=verified' "$d/_result" && ok "lane $i reap result" || bad "lane $i reap result"
  rm -rf "$d" "$scratch/wf-live-dir-$i" 2>/dev/null
done

echo ""
echo "quota after:"; clawmeter status --agent --plain 2>/dev/null | grep -oE 'Claude 5h\([^)]*\)' | head -1
echo "=== SMOKE TOTAL: pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]] && echo "LIVE MATRIX: GREEN" || echo "LIVE MATRIX: $fail FAILURES"
