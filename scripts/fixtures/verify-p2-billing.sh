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
  check_quota_case 'string zero credits' '.providers.openai.usage.reset_credits.available_count = "0"' absent true null null
  check_quota_case 'string positive credits' '.providers.openai.usage.reset_credits.available_count = "3"' absent true null null
  check_quota_case 'negative credits' '.providers.openai.usage.reset_credits.available_count = -1' absent true null null
  check_quota_case 'fractional credits' '.providers.openai.usage.reset_credits.available_count = 0.5' absent true null null
  check_quota_case 'boolean credits' '.providers.openai.usage.reset_credits.available_count = false' absent true null null
  check_quota_case 'missing credits' 'del(.providers.openai.usage.reset_credits)' ok true 100 494
  check_quota_case 'null credits' '.providers.openai.usage.reset_credits.available_count = null' ok true 100 494
  check_quota_case 'positive credits do not rescue' '.providers.openai.usage.reset_credits.available_count = 2' ok true 100 494
  check_quota_case 'negative utilization' '.providers.openai.usage.windows[0].utilization = -5' absent true null null
  check_quota_case 'over quota utilization' '.providers.openai.usage.windows[0].utilization = 250' ok true 250 494
  check_quota_case 'negative projection' '.providers.openai.forecast.windows["7d"].projected_pct = -20' ok true 100 null
  check_quota_case 'over quota projection' '.providers.openai.forecast.windows["7d"].projected_pct = 250' ok true 100 250
  check_quota_case 'missing forecast exhausted' 'del(.providers.openai.forecast)' ok true 100 null
  check_quota_case 'missing forecast with headroom' 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 68' ok false 68 null
  check_quota_case 'missing forecast at zero' 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 0' ok false 0 null
  check_quota_case 'null forecast' '.providers.openai.forecast = null' ok true 100 null
  check_quota_case 'missing forecast windows' '.providers.openai.forecast = {}' ok true 100 null
  check_quota_case 'missing window forecast' '.providers.openai.forecast.windows = {}' ok true 100 null
  check_quota_case 'null projection' '.providers.openai.forecast.windows["7d"].projected_pct = null' ok true 100 null
  check_quota_case 'missing projection' 'del(.providers.openai.forecast.windows["7d"].projected_pct)' ok true 100 null
  check_quota_case 'nonnumeric projection' '.providers.openai.forecast.windows["7d"].projected_pct = "unknown"' ok true 100 null
  check_quota_case 'literal null projection' '.providers.openai.forecast.windows["7d"].projected_pct = "null"' ok true 100 null
  check_quota_case 'known zero projection' '.providers.openai.forecast.windows["7d"].projected_pct = 0 | .providers.openai.usage.windows[0].utilization = 0' ok false 0 0
  check_quota_case 'null current utilization' '.providers.openai.usage.windows[0].utilization = null | .providers.openai.forecast.windows = {}' absent true null null
  check_quota_case 'missing current utilization' 'del(.providers.openai.usage.windows[0].utilization) | .providers.openai.forecast.windows = {}' absent true null null
  check_quota_case 'provider error' '.providers.openai.usage.error = "forecast unavailable"' provider_error true null null
  check_quota_case 'provider error dominates invalid usage' '.providers.openai.usage.error = "forecast unavailable" | .providers.openai.usage.windows[0].utilization = -5 | .providers.openai.usage.reset_credits.available_count = "0"' provider_error true null null
  check_quota_case 'stale current usage' '.providers.openai.usage.stale = true | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' stale true 0 null
  check_quota_case 'expired current usage' '.providers.openai.usage.fetched_at = "2000-01-01T00:00:00Z" | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' ok true 0 null
  check_quota_case 'invalid timestamp' '.providers.openai.usage.fetched_at = "invalid" | .providers.openai.usage.windows[0].utilization = 0 | .providers.openai.forecast.windows = {}' ok true 0 null
  check_quota_case 'future timestamp' '.providers.openai.usage.fetched_at = "2999-01-01T00:00:00Z"' ok true 100 494
  check_quota_case 'timezone offset timestamp' '.providers.openai.usage.fetched_at |= sub("Z$"; "+00:00") | .providers.openai.usage.windows[0].utilization = 68' ok false 68 494
  check_quota_case 'fractional timestamp' '.providers.openai.usage.fetched_at |= sub("Z$"; ".000Z") | .providers.openai.usage.windows[0].utilization = 68' ok false 68 494
  check_quota_case 'timezone missing' '.providers.openai.usage.fetched_at |= sub("Z$"; "") | .providers.openai.usage.windows[0].utilization = 68' ok true 68 494
  check_quota_case 'mixed windows with headroom' '.providers.openai.usage.windows += [{name:"5h",utilization:40,resets_at:"2999-01-01T00:00:00Z"}]' ok false 100 494
  check_quota_case 'all windows exhausted' '.providers.openai.usage.windows += [{name:"5h",utilization:100,resets_at:"2999-01-01T00:00:00Z"}]' ok true 100 494

  quota_raw="$(jq '.providers.openai.usage.windows = []' <<<"$baseline")"
  [[ "$(selection_quota_filtered "$billing" "$(quota_observation_v1 codex)" default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" '{"state":"ok","observation":{"windows":[{"projected_pct":null,"utilization_pct":null}]}}' default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" 'not json' default)" == true ]]
  quota_assertions=$((quota_assertions + 3))

  # Also defend against callers supplying an envelope without using the parser.
  quota_raw="$baseline"
  quota="$(quota_observation_v1 codex)"
  [[ "$(selection_quota_filtered "$billing" "$(jq '.observation.reset_credits_available = "0"' <<<"$quota")" default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" "$(jq '.observation.reset_credits_available = -1' <<<"$quota")" default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" "$(jq '.observation.windows[0].utilization_pct = -5' <<<"$quota")" default)" == true ]]
  # Unknown billing and mismatched quota scope cannot establish headroom.
  [[ "$(selection_quota_filtered '{"path":"unknown"}' "$quota" default)" == true ]]
  [[ "$(selection_quota_filtered "$billing" "$quota" mismatched)" == true ]]
  quota_assertions=$((quota_assertions + 5))

  # Exercise the public selection gate with an available model and unknown quota.
  export WASPFLOW_OPS_POLICY="$root/tests/fixtures/selection-policy-fallback.json"
  codex_valid_models() { printf 'source=live_query\nfallback-only\n'; }
  err() { printf '%s\n' "$*" >&2; }
  warn() { :; }
  quota_raw="$(jq 'del(.providers.openai.usage.windows[0].utilization) | .providers.openai.forecast.windows = {}' <<<"$baseline")"
  gate_rc=0
  gate_out="$(selection_gate_op new codex fallback-only default "$billing" false true 2>&1)" || gate_rc=$?
  [[ "$gate_rc" == 5 && "$gate_out" == *quota_filtered* && "$gate_out" == *--accept-provider-default* ]]
  [[ "$gate_out" == *provider=codex* && "$gate_out" == *quota_state=absent* && "$gate_out" == *'reason=clawmeter JSON has unsupported provider shape'* ]] || {
    printf 'quota gate: missing provider/state/reason: %s\n' "$gate_out" >&2
    exit 1
  }
  quota_assertions=$((quota_assertions + 1))
  check_gate_case() {
    local label="$1" transform="$2" state="$3" reason="$4" gate_rc=0 gate_out
    quota_raw="$(jq "$transform" <<<"$baseline")"
    gate_out="$(selection_gate_op new codex fallback-only default "$billing" false true 2>&1)" || gate_rc=$?
    [[ "$gate_rc" == 5 ]] || { printf 'quota gate %s: expected exit 5, got %s\n' "$label" "$gate_rc" >&2; exit 1; }
    [[ "$gate_out" == *provider=codex* && "$gate_out" == *"quota_state=$state"* ]] || { printf 'quota gate %s: missing provider/state: %s\n' "$label" "$gate_out" >&2; exit 1; }
    [[ "$gate_out" == *"reason=$reason"* && "$gate_out" == *--accept-provider-default* ]] || { printf 'quota gate %s: missing reason/escape: %s\n' "$label" "$gate_out" >&2; exit 1; }
    quota_assertions=$((quota_assertions + 3))
  }
  check_gate_case exhausted '.' ok 'all quota windows are exhausted'
  check_gate_case stale '.providers.openai.usage.stale = true' stale 'quota observation is stale'
  check_gate_case expired '.providers.openai.usage.fetched_at = "2000-01-01T00:00:00Z"' ok 'quota observation is older than 600 seconds'
  check_gate_case future '.providers.openai.usage.fetched_at = "2999-01-01T00:00:00Z"' ok 'quota fetched_at is in the future'
  check_gate_case invalid '.providers.openai.usage.fetched_at = "invalid"' ok 'quota fetched_at is invalid'
  check_gate_case provider_error '.providers.openai.usage.error = "token refresh failed"' provider_error 'token refresh failed'
  quota_raw="$(jq 'del(.providers.openai.forecast) | .providers.openai.usage.windows[0].utilization = 68' <<<"$baseline")"
  selection_gate_op new codex fallback-only default "$billing" false true
  quota_assertions=$((quota_assertions + 2))

  # A BSD-style date has no -d option. Fresh quota must still be usable.
  date() {
    case " $* " in *' -d '*) return 64 ;; esac
    command date "$@"
  }
  [[ "$(selection_quota_filtered "$billing" "$(quota_observation_v1 codex)" default)" == false ]] || {
    printf 'quota portability: fresh headroom blocked without GNU date\n' >&2
    exit 1
  }
  unset -f date
  quota_assertions=$((quota_assertions + 1))
  menu_out="$(selection_menu 2>&1)"
  [[ "$menu_out" == *fallback-only* && "$menu_out" != *quota=* ]] || {
    printf 'quota menu: displays an unobserved quota: %s\n' "$menu_out" >&2
    exit 1
  }
  quota_assertions=$((quota_assertions + 1))
  printf 'billing quota: %s assertions passed\n' "$quota_assertions"
)
