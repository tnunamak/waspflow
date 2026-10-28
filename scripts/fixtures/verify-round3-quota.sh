#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/lib/billing.sh"
source "$root/lib/selection.sh"
source "$root/lib/ops.sh"
export WASPFLOW_OPS_POLICY="$root/tests/fixtures/selection-policy-fallback.json"
err() { printf '%s\n' "$*" >&2; }
warn() { :; }
codex_valid_models() { printf 'source=live_query\nfallback-only\n'; }
clawmeter() { if [[ "$1" == --version ]]; then printf 'fixture\n'; else printf '%s\n' "$quota_raw"; fi; }
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
quota_raw="$(jq --arg at "$fresh" '.providers.openai.usage.fetched_at = $at | .providers.openai.usage.windows[0].utilization = 100 | .providers.openai.usage.reset_credits.available_count = 0' "$root/tests/fixtures/clawmeter-healthy.json")"
quota="$(quota_observation_v1 codex)"
case "$1" in
  no_timeout)
    codex() { printf 'Logged in using ChatGPT\n'; }
    command() { if [[ "$*" == '-v timeout' ]]; then return 1; fi; builtin command "$@"; }
    export WASPFLOW_DOCTOR_READ_ONLY=1
    billing="$(billing_path_v1 codex default false)"
    rc=0; output="$(selection_gate_op new codex fallback-only default "$billing" false true 2>&1)" || rc=$?
    [[ "$rc" == 5 && "$output" == *'reason=billing path is unknown: timeout_unavailable'* ]] || { printf 'missing timeout: expected a clear block, got: %s\n' "$output" >&2; exit 1; }
    ;;
  clawmeter_timeout)
    unset -f clawmeter
    stub_dir="$(mktemp -d "${TMPDIR:-$HOME/.tmp}/waspflow-quota-stub-XXXXXX")"
    printf '#!/usr/bin/env bash\nexit 99\n' >"$stub_dir/clawmeter"
    chmod +x "$stub_dir/clawmeter"
    export PATH="$stub_dir:$PATH"
    command() { if [[ "$*" == '-v timeout' ]]; then return 1; fi; builtin command "$@"; }
    quota="$(quota_observation_v1 codex)"
    [[ "$(jq -r .reason <<<"$quota")" == 'timeout unavailable for clawmeter' ]]
    ;;
  antigravity)
    quota_raw="$(jq '.providers.antigravity = .providers.openai' <<<"$quota_raw")"
    quota="$(quota_observation_v1 antigravity)"
    [[ "$(selection_quota_filtered '{"path":"oauth_quota_heuristic"}' "$quota" default)" == true ]]
    ;;
  credits)
    quota="$(jq '.observation.reset_credits_available = 1' <<<"$quota")"
    [[ "$(selection_quota_filtered '{"path":"chatgpt_subscription"}' "$quota" default)" == true ]]
    ;;
  mismatch)
    [[ "$(selection_quota_filtered '{"path":"chatgpt_subscription"}' "$quota" mismatched)" == true ]]
    ;;
  unknown)
    [[ "$(selection_quota_filtered '{"path":"unknown","detail":"status_failed"}' '{"state":"absent"}' default)" == true ]]
    [[ "$(selection_quota_filtered '{"path":"scoped_unknown"}' '{"state":"absent"}' default)" == true ]]
    ;;
  grok)
    quota="$(quota_observation_v1 grok)"
    [[ "$(selection_quota_filtered '{"path":"oauth_env_heuristic"}' "$quota" default)" == true ]]
    ;;
  forecast)
    quota="$(jq '.observation.windows[0].utilization_pct = 68' <<<"$quota")"
    [[ "$(selection_quota_filtered '{"path":"chatgpt_subscription"}' "$quota" default)" == false ]]
    ;;
esac
