#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/lib/billing.sh"
source "$root/lib/selection.sh"
source "$root/lib/ops.sh"
err() { printf '%s\n' "$*" >&2; }
warn() { :; }
antigravity_valid_models() { printf 'source=live_query\ngemini-3.6-flash-low\nclaude-sonnet-4-6\ngpt-oss-120b-medium\nunknown-model\n'; }
clawmeter() { if [[ "$1" == --version ]]; then printf 'fixture\n'; else printf '%s\n' "$quota_raw"; fi; }
export WASPFLOW_OPS_POLICY="$root/tests/fixtures/selection-policy-fallback.json"
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
billing='{"path":"oauth_quota_heuristic"}'
case "$1" in
  pools)
    quota_raw="$(jq -cn --arg at "$fresh" '{providers:{antigravity:{usage:{fetched_at:$at,windows:[{name:"7d Gemini",utilization:100,resets_at:$at},{name:"7d Claude + GPT",utilization:10,resets_at:$at}]}}}}')"
    rc=0; out="$(selection_gate_op new antigravity gemini-3.6-flash-low default "$billing" false true 2>&1)" || rc=$?
    [[ "$rc" == 5 ]] || { printf 'exhausted Gemini passed: %s\n' "$out" >&2; exit 1; }
    selection_gate_op new antigravity claude-sonnet-4-6 default "$billing" false true
    selection_gate_op new antigravity gpt-oss-120b-medium default "$billing" false true
    quota_raw="$(jq '.providers.antigravity.usage.windows[0].utilization=10 | .providers.antigravity.usage.windows[1].utilization=100' <<<"$quota_raw")"
    selection_gate_op new antigravity gemini-3.6-flash-low default "$billing" false true
    rc=0; selection_gate_op new antigravity claude-sonnet-4-6 default "$billing" false true >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 5 ]]
    rc=0; selection_gate_op new antigravity unknown-model default "$billing" false true >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 5 ]]
    quota_raw="$(jq 'del(.providers.antigravity.usage.windows[0]) | .providers.antigravity.usage.windows[0].utilization=10' <<<"$quota_raw")"
    rc=0; selection_gate_op new antigravity gemini-3.6-flash-low default "$billing" false true >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 5 ]]
    ;;
  forecast)
    quota_raw="$(jq --arg at "$fresh" '.providers.openai.usage.fetched_at=$at | .providers.openai.forecast="drift"' "$root/tests/fixtures/clawmeter-healthy.json")"
    quota="$(quota_observation_v1 codex)"
    jq -e '.state == "ok" and .observation.windows[0].utilization_pct == 68 and .observation.windows[0].projected_pct == null' <<<"$quota" >/dev/null
    quota_raw="$(jq '.providers.openai.forecast={windows: [1,2]}' <<<"$quota_raw")"
    quota="$(quota_observation_v1 codex)"
    jq -e '.state == "ok" and .observation.windows[0].projected_pct == null' <<<"$quota" >/dev/null
    quota_raw="$(jq '.providers.openai.forecast={windows:{"7d":"drift"}}' <<<"$quota_raw")"
    quota="$(quota_observation_v1 codex)"
    jq -e '.state == "ok" and .observation.windows[0].projected_pct == null' <<<"$quota" >/dev/null
    quota_raw="$(jq '.schema_version=2' <<<"$quota_raw")"
    quota="$(quota_observation_v1 codex)"
    jq -e '.state == "absent"' <<<"$quota" >/dev/null
    ;;
  sigpipe)
    echo() { builtin echo "$@"; case "$*" in *'grok auth:'*) printf '%01000000d\n' 0 ;; esac; }
    export -f echo
    bash "$root/scripts/fixtures/verify-p2-billing.sh" >/dev/null
    ;;
esac
