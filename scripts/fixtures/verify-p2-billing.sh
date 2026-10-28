#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Alternate Claude billing routes must not be described as subscription credit.
(
  source "$root/lib/billing.sh"
  billing_codex_auth_notice() { :; }
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_BASE_URL
  for setting in ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_BASE_URL; do
    report="$(export "$setting=fixture"; billing_report_auth)"
    claude_line="$(grep 'claude auth:' <<<"$report")"
    [[ "$claude_line" != *subscription* && "$claude_line" == *"$setting"* ]]
  done
  billing_report_auth | grep -q 'claude auth:.*heuristic'
)
printf 'billing routes: 5 assertions passed\n'

# Missing forecasts must retain current usage, and unknown quota must not make
# an otherwise available operating point auto-selectable. No provider is called.
(
  source "$root/lib/billing.sh"
  source "$root/lib/selection.sh"
  source "$root/lib/ops.sh"
  fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  baseline="$(jq --arg at "$fresh" '
    .providers.openai.usage.fetched_at = $at |
    .providers.openai.usage.windows[0].utilization = 100 |
    .providers.openai.usage.reset_credits.available_count = 0
  ' "$root/tests/fixtures/clawmeter-healthy.json")"
  clawmeter() {
    if [[ "${1:-}" == --version ]]; then printf 'v0.27.6\n'; else printf '%s\n' "$quota_raw"; fi
  }
  billing='{"schema_version":1,"path":"chatgpt_subscription","evidence":"fixture","detail":""}'
  quota_assertions=0
  check_quota_case() {
    local label="$1" transform="$2" expected_state="$3" expected_filtered="$4" expected_utilization="$5" expected_projection="$6"
    local quota filtered auto expected_auto
    quota_raw="$(jq "$transform" <<<"$baseline")"
    quota="$(quota_observation_v1 codex)"
    filtered="$(selection_quota_filtered "$billing" "$quota" default)"
    [[ "$filtered" == "$expected_filtered" ]] || {
      printf 'quota %s: expected filtered=%s, got %s (%s)\n' "$label" "$expected_filtered" "$filtered" "$quota" >&2
      exit 1
    }
    jq -e --arg state "$expected_state" --argjson utilization "$expected_utilization" --argjson projection "$expected_projection" '
      .schema_version == 1 and .state == $state and
      (if $state == "ok" or $state == "stale" then
        .observation.windows[0] | has("projected_pct") and .utilization_pct == $utilization and .projected_pct == $projection
       else .observation == null end)
    ' >/dev/null <<<"$quota" || { printf 'quota %s: unexpected observation %s\n' "$label" "$quota" >&2; exit 1; }
    auto="$(selection_auto_selectable available unratified none none "$filtered" false true)"
    expected_auto=true; [[ "$expected_filtered" == true ]] && expected_auto=false
    [[ "$auto" == "$expected_auto" ]] || { printf 'quota %s: auto-selectable=%s\n' "$label" "$auto" >&2; exit 1; }
    quota_assertions=$((quota_assertions + 3))
  }

  check_quota_case 'known exhausted' '.' ok true 100 494
  check_quota_case 'missing forecast exhausted' 'del(.providers.openai.forecast)' ok true 100 null
  check_quota_case 'missing forecast with headroom' 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 68' ok false 68 null
  check_quota_case 'missing forecast at zero' 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 0' ok false 0 null
  check_quota_case 'null forecast' '.providers.openai.forecast = null' ok true 100 null
  check_quota_case 'missing forecast windows' '.providers.openai.forecast = {}' ok true 100 null
  check_quota_case 'missing window forecast' '.providers.openai.forecast.windows = {}' ok true 100 null
  check_quota_case 'null projection' '.providers.openai.forecast.windows["7d"].projected_pct = null' ok true 100 null
  check_quota_case 'missing projection' 'del(.providers.openai.forecast.windows["7d"].projected_pct)' ok true 100 null
  check_quota_case 'nonnumeric projection' '.providers.openai.forecast.windows["7d"].projected_pct = "unknown"' ok true 100 null
  check_quota_case 'known zero projection' '.providers.openai.forecast.windows["7d"].projected_pct = 0 | .providers.openai.usage.windows[0].utilization = 0' ok false 0 0
  check_quota_case 'null current utilization' '.providers.openai.usage.windows[0].utilization = null | .providers.openai.forecast.windows = {}' absent true null null
  check_quota_case 'missing current utilization' 'del(.providers.openai.usage.windows[0].utilization) | .providers.openai.forecast.windows = {}' absent true null null
  check_quota_case 'provider error' '.providers.openai.usage.error = "forecast unavailable"' provider_error true null null
  check_quota_case 'stale current usage' '.providers.openai.usage.stale = true | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' stale true 0 null
  check_quota_case 'expired current usage' '.providers.openai.usage.fetched_at = "2000-01-01T00:00:00Z" | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' ok true 0 null
  check_quota_case 'invalid timestamp' '.providers.openai.usage.fetched_at = "invalid" | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' ok true 0 null

  quota_raw="$(jq '.providers.openai.usage.windows = []' <<<"$baseline")"
  [[ "$(selection_quota_filtered "$billing" "$(quota_observation_v1 codex)" default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" '{"state":"ok","observation":{"windows":[{"projected_pct":null,"utilization_pct":null}]}}' default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" 'not json' default)" == true ]]
  quota_assertions=$((quota_assertions + 3))

  # Exercise the public selection gate with an available model and unknown quota.
  export WASPFLOW_OPS_POLICY="$root/tests/fixtures/selection-policy-fallback.json"
  codex_valid_models() { printf 'source=live_query\nfallback-only\n'; }
  err() { printf '%s\n' "$*" >&2; }
  warn() { :; }
  quota_raw="$(jq 'del(.providers.openai.usage.windows[0].utilization) | .providers.openai.forecast.windows = {}' <<<"$baseline")"
  gate_rc=0
  gate_out="$(selection_gate_op new codex fallback-only default "$billing" false true 2>&1)" || gate_rc=$?
  [[ "$gate_rc" == 5 && "$gate_out" == *quota_filtered* && "$gate_out" == *--accept-provider-default* ]]
  quota_raw="$(jq 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 68' <<<"$baseline")"
  selection_gate_op new codex fallback-only default "$billing" false true
  quota_assertions=$((quota_assertions + 2))
  printf 'billing quota: %s assertions passed\n' "$quota_assertions"
)
