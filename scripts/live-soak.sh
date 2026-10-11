#!/usr/bin/env bash
# live-soak.sh — sustained mixed-provider fleet soak. Launches N lanes across
# claude/codex/grok CONCURRENTLY (tight burst), runs the full loop on each
# (spawn → wait → assert edit → revise → wait → assert edit → reap), and checks
# cross-lane isolation. This is the "bet-the-company" fleet test: the core use
# case is many workers at once, and this proves submission, steering, cleanup,
# and isolation all hold under real concurrent load.
#
# Cheap by design: claude→haiku, codex→gpt-5.6-luna on the SUBSCRIPTION
# (env -u OPENAI_API_KEY, since a stray OPENAI_API_KEY would bill the API).
#
# Usage: WASPFLOW_HOME=... scripts/live-soak.sh [n_per_provider]   (default 3 => 9 lanes)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BF="$root/bin/waspflow"
PER="${1:-3}"
scratch="${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}"
export WASPFLOW_HOME="${WASPFLOW_HOME:-$HOME/.local/state/waspflow}"

pass=0; fail=0
[[ "$PER" =~ ^[1-9][0-9]*$ ]] || { echo "n_per_provider must be a positive integer" >&2; exit 1; }
resfile="$(mktemp "$scratch/soak-res-XXXXXX")"
run_id="${resfile##*/}"

# providers[i] paired with model[i]; empty model = provider default.
PROVIDERS=(claude codex grok)
MODELS=(haiku gpt-5.6-luna "")

one() {
  local lane="$1" prov="$2" model="$3" tag="$4"
  local d; d="$(mktemp -d "$scratch/soak-$lane-XXXXXX")"
  ( cd "$d" && git init -q && git config user.email t@e.invalid && git config user.name T \
      && printf 'L0\n' > f.txt && git add -A && git commit -q -m init )
  local -a mf=(); [[ -n "$model" ]] && mf=(--model "$model") || mf=(--accept-provider-default)
  if ! ( cd "$d" && env -u OPENAI_API_KEY "$BF" spawn --provider "$prov" "${mf[@]}" --lane "$lane" -- \
      "Append ${tag}_A to f.txt then stop." ) >/dev/null 2>&1; then
    printf '%s spawn=FAILED\n' "$lane($prov)" >> "$resfile"
    rm -rf "$d"
    return 1
  fi
  local sub; sub="$(env -u OPENAI_API_KEY "$BF" status "$lane" 2>/dev/null | jq -r '.spawn_submitted // "na"')"
  local spawn_wait=0 revise_status=0 revise_wait=0
  env -u OPENAI_API_KEY timeout 135 "$BF" wait "$lane" --timeout 130 >/dev/null 2>&1 || spawn_wait=$?
  local s=NO; grep -q "${tag}_A" "$d/f.txt" 2>/dev/null && s=YES
  env -u OPENAI_API_KEY "$BF" revise "$lane" -- "Append ${tag}_B to f.txt then stop." >/dev/null 2>&1 || revise_status=$?
  env -u OPENAI_API_KEY timeout 135 "$BF" wait "$lane" --timeout 130 >/dev/null 2>&1 || revise_wait=$?
  local r=NO; grep -q "${tag}_B" "$d/f.txt" 2>/dev/null && r=YES
  local rp; rp="$(env -u OPENAI_API_KEY "$BF" reap "$lane" --force 2>&1 | grep -oE 'result=[a-z_]+' | head -1)"
  # Isolation: the file must NOT contain any OTHER lane's tag. (Substring check,
  # not whole-line: workers sometimes append without a trailing newline, which a
  # line-anchored regex mis-flags as dirty — that's a check artifact, not real
  # contamination. What matters is that no foreign tag leaked in.)
  local x=clean other
  for other in $(seq 1 $((PER*3))); do
    [[ "T$other" == "$tag" ]] && continue
    grep -qF "T${other}_" "$d/f.txt" 2>/dev/null && x="DIRTY_by_T$other"
  done
  printf '%s sub=%s spawn=%s revise=%s spawn_wait=%s revise_status=%s revise_wait=%s %s iso=%s\n' "$lane($prov)" "$sub" "$s" "$r" "$spawn_wait" "$revise_status" "$revise_wait" "${rp:-none}" "$x" >> "$resfile"
  rm -rf "$d"
}

echo "=== waspflow LIVE SOAK: $PER lane(s) x 3 providers = $((PER*3)) concurrent lanes ==="
echo "capacity monitor before:"; clawmeter status --agent --plain 2>/dev/null | grep -oE '(Claude 5h|Codex 5h|Grok 7d)\(current=[0-9]+%' | head -3

pids=(); n=0
for p in 0 1 2; do
  for k in $(seq 1 "$PER"); do
    n=$((n+1))
    one "soak-$run_id-$n" "${PROVIDERS[$p]}" "${MODELS[$p]}" "T$n" &
    pids+=("$!")
  done
done
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    echo "  worker $pid exited before completing its lifecycle"
    fail=$((fail+1))
  fi
done
actual="$(cut -d ' ' -f1 "$resfile" | sort -u | wc -l)"
if [[ "$actual" -ne "$((PER*3))" ]]; then
  echo "  expected $((PER*3)) distinct worker results; got $actual"
  fail=$((fail+1))
fi

echo ""; echo "=== results ==="
while IFS= read -r line; do
  echo "  $line"
  if grep -qE 'sub=true spawn=YES revise=YES spawn_wait=0 revise_status=0 revise_wait=0 result=(succeeded|verified) iso=clean' <<<"$line"; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
done < "$resfile"
rm -f "$resfile"

echo ""; echo "capacity monitor after:"; clawmeter status --agent --plain 2>/dev/null | grep -oE '(Claude 5h|Codex 5h|Grok 7d)\(current=[0-9]+%' | head -3
echo "=== SOAK TOTAL: pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]] && echo "LIVE SOAK: GREEN" || echo "LIVE SOAK: $fail FAILURES"

[[ "$fail" -eq 0 ]]
