#!/usr/bin/env bash
#
# billing.sh — billing/auth safety checks.
#
# Claude is intentionally an environment-only hard guard. Codex is different:
# its read-only `login status` command reports the active auth mode, so use that
# observed state instead of treating an environment variable as billing proof.

# Emit a cached, read-only Codex auth observation as `mode<TAB>principal`.
# Modes are `chatgpt_subscription`, `api_key`, or `unknown:<reason>`.
# The cache context deliberately includes only key/token *presence*, never their
# values, and the result never changes whether a command may launch.
codex_auth_observation() {
  local cache_dir cache_file cache_key cache_hash cached_at cached_mode cached_principal
  local codex_path mode="" principal="" status="" status_rc=0
  local now ttl timeout_seconds tmp=""

  if [[ "${WASPFLOW_SKIP_CODEX_AUTH_CHECK:-}" == "1" ]]; then
    printf 'unknown:check_skipped\t\n'
    return 0
  fi
  if ! command -v codex >/dev/null 2>&1; then
    printf 'unknown:codex_missing\t\n'
    return 0
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    printf 'unknown:timeout_unavailable\t\n'
    return 0
  fi

  ttl="${WASPFLOW_CODEX_AUTH_CACHE_TTL_SECONDS:-15}"
  [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || ttl=15
  timeout_seconds="${WASPFLOW_CODEX_AUTH_TIMEOUT_SECONDS:-2}"
  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || timeout_seconds=2

  codex_path="$(command -v codex)"
  cache_dir="${WASPFLOW_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/waspflow}/codex-auth-cache"
  cache_key="v1|$codex_path|${CODEX_HOME:-$HOME/.codex}|openai-api-key:${OPENAI_API_KEY:+set}|codex-access-token:${CODEX_ACCESS_TOKEN:+set}"
  cache_hash="$(printf '%s' "$cache_key" | cksum)"
  cache_hash="${cache_hash%% *}"
  cache_file="$cache_dir/$cache_hash"
  now="$(date +%s)"

  if [[ -r "$cache_file" ]]; then
    cached_at=""; cached_mode=""; cached_principal=""
    IFS=$'\t' read -r cached_at cached_mode cached_principal <"$cache_file" || true
    if [[ "$cached_at" =~ ^[0-9]+$ && "$cached_mode" =~ ^(chatgpt_subscription|api_key|unknown:[a-z_]+)$ ]] \
      && (( now - cached_at >= 0 && now - cached_at < ttl )); then
      printf '%s\t%s\n' "$cached_mode" "$cached_principal"
      return 0
    fi
  fi

  if status="$(timeout --kill-after=1s "${timeout_seconds}s" codex login status 2>&1)"; then
    if grep -qi 'Logged in using ChatGPT' <<<"$status"; then
      mode=chatgpt_subscription
    elif grep -qiE 'api[ -]?key' <<<"$status"; then
      mode=api_key
    else
      mode=unknown:unrecognized_status
    fi
    principal="$(sed -nE '/^[[:space:]]*(Account|Logged in as)[[:space:]]*:/Ip' <<<"$status" | head -1)"
  else
    status_rc=$?
    if [[ "$status_rc" == 124 || "$status_rc" == 137 ]]; then
      mode=unknown:timed_out
    else
      mode=unknown:status_failed
    fi
  fi

  if mkdir -p "$cache_dir" 2>/dev/null; then
    tmp="$(mktemp "$cache_dir/.auth-mode.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$tmp" ]]; then
      if ! printf '%s\t%s\t%s\n' "$now" "$mode" "$principal" >"$tmp" || ! mv -f "$tmp" "$cache_file"; then
        rm -f "$tmp" || true
      fi
    fi
  fi
  printf '%s\t%s\n' "$mode" "$principal"
}

billing_codex_auth_notice() {
  local surface="$1" mode principal reason message
  IFS=$'\t' read -r mode principal < <(codex_auth_observation) || mode=unknown:status_failed

  case "$mode" in
    chatgpt_subscription) return 0 ;;
    api_key) message="active Codex login uses API-key auth; Codex usage is billed at API pay-as-you-go rates." ;;
    unknown:*)
      reason="${mode#unknown:}"
      case "$reason" in
        check_skipped) message="Codex auth mode is unknown: the check was skipped because WASPFLOW_SKIP_CODEX_AUTH_CHECK=1; billing path could not be determined." ;;
        codex_missing) message="Codex auth mode is unknown: codex is not installed; billing path could not be determined." ;;
        timeout_unavailable) message="Codex auth mode is unknown: a hard timeout utility is unavailable; billing path could not be determined." ;;
        timed_out) message="Codex auth mode is unknown: codex login status timed out; billing path could not be determined." ;;
        status_failed) message="Codex auth mode is unknown: codex login status failed; billing path could not be determined." ;;
        *) message="Codex auth mode is unknown: codex login status did not report a recognized auth mode; billing path could not be determined." ;;
      esac
      ;;
    *) message="Codex auth mode is unknown: codex login status did not report a recognized auth mode; billing path could not be determined." ;;
  esac

  if [[ "$surface" == report ]]; then
    echo "  [warn] codex auth: $message"
  else
    warn "codex billing notice: $message"
  fi
}

billing_report_auth() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "  [warn] claude auth: ANTHROPIC_API_KEY is set -> headless workers bill pay-as-you-go API rates, NOT your subscription. A fleet can run up large charges (see issue #37686). Unset it to use your subscription."
  else
    echo "  [ok]   claude auth: subscription/Agent-SDK credit (no ANTHROPIC_API_KEY)"
  fi

  billing_codex_auth_notice report

  if [[ -n "${XAI_API_KEY:-}" ]]; then
    echo "  [warn] grok auth: XAI_API_KEY is set -> headless Grok may use API pay-as-you-go billing instead of OAuth/subscription-backed CLI auth. Verify billing before fleet use."
  else
    echo "  [ok]   grok auth: no XAI_API_KEY in environment; billing follows configured Grok CLI auth (OAuth cache or login)"
  fi
  echo "  [info] antigravity auth: agy OAuth/quota path is provider-owned (heuristic only)"

  if [[ -n "${BAILIAN_TOKEN_PLAN_API_KEY:-}" || -n "${BAILIAN_CODING_PLAN_API_KEY:-}" || -n "${DASHSCOPE_API_KEY:-}" ]]; then
    echo "  [ok]   qwen auth: API key detected in environment (Token Plan / Coding Plan / DashScope)"
  else
    echo "  [warn] qwen auth: no API key in environment (set BAILIAN_TOKEN_PLAN_API_KEY or BAILIAN_CODING_PLAN_API_KEY)"
  fi
}

billing_preflight_provider() {
  local provider="$1"
  case "$provider" in
    claude) billing_preflight_claude ;;
    codex) billing_preflight_codex ;;
    grok) billing_preflight_grok ;;
    antigravity) billing_preflight_antigravity ;;
    qwen) billing_preflight_qwen ;;
    deepseek) billing_preflight_deepseek ;;
    *) return 0 ;;
  esac
}

billing_preflight_claude() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 0

  if [[ "${WASPFLOW_ALLOW_API_BILLING:-}" == "1" ]]; then
    warn "claude billing guard: ANTHROPIC_API_KEY is set; proceeding because WASPFLOW_ALLOW_API_BILLING=1."
    warn "claude billing guard: headless workers bill pay-as-you-go API rates, NOT your subscription. Monitor usage before running fleets."
    return 0
  fi

  err "claude billing guard: ANTHROPIC_API_KEY is set."
  err "Headless Claude workers will bill pay-as-you-go API rates, NOT your subscription/Agent-SDK credit."
  err "A fleet can run up large charges (see claude-code issue #37686)."
  err "Fix: unset ANTHROPIC_API_KEY before spawning Claude workers."
  err "Intentional override: WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude ..."
  return 1
}

billing_preflight_codex() {
  billing_codex_auth_notice preflight
  return 0
}

billing_preflight_grok() {
  [[ -n "${XAI_API_KEY:-}" ]] || return 0
  warn "grok billing notice: XAI_API_KEY is set; verify whether Grok will use API pay-as-you-go billing before fleet use."
  return 0
}

billing_preflight_antigravity() { return 0; }

billing_preflight_qwen() { return 0; }
billing_preflight_deepseek() { return 0; }

# Emit BillingPath v1. This is observational only: an uncertain billing path
# never changes whether a lane may launch. Args: provider endpoint_profile raw_args
billing_path_v1() {
  local provider="$1" endpoint_profile="${2:-default}" raw_args="${3:-false}"
  local path="unknown" evidence="none" detail="" mode="" principal=""
  case "$provider" in
    claude)
      if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then path="api_key"; evidence="env:ANTHROPIC_API_KEY"
      elif [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then path="auth_token"; evidence="env:ANTHROPIC_AUTH_TOKEN"
      elif [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]]; then path="bedrock"; evidence="env:CLAUDE_CODE_USE_BEDROCK"
      elif [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]; then path="vertex"; evidence="env:CLAUDE_CODE_USE_VERTEX"
      elif [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then path="custom_base_url"; evidence="env:ANTHROPIC_BASE_URL"
      else path="subscription_env_heuristic"; evidence="absence_of_provider_overrides"; fi
      ;;
    codex)
      if [[ "$endpoint_profile" == oss ]]; then
        path="oss_local"; evidence="oss_flag"
      elif [[ "$endpoint_profile" != default || "$raw_args" == true ]]; then
        path="scoped_unknown"; evidence="scoped_invocation"
      else
        IFS=$'\t' read -r mode principal < <(codex_auth_observation) || mode=unknown:status_failed
        case "$mode" in
          chatgpt_subscription) path="chatgpt_subscription"; evidence="codex_login_status" ;;
          api_key) path="api_key"; evidence="codex_login_status" ;;
          unknown:*) evidence="codex_login_status_unknown"; detail="${mode#unknown:}" ;;
        esac
      fi
      ;;
    grok)
      if [[ -n "${XAI_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:XAI_API_KEY"
      else path="oauth_env_heuristic"; evidence="absence_of_XAI_API_KEY"; fi
      ;;
    antigravity) path="oauth_quota_heuristic"; evidence="agy_provider_owned_auth" ;;
    qwen)
      if [[ -n "${BAILIAN_TOKEN_PLAN_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:BAILIAN_TOKEN_PLAN_API_KEY"
      elif [[ -n "${BAILIAN_CODING_PLAN_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:BAILIAN_CODING_PLAN_API_KEY"
      elif [[ -n "${DASHSCOPE_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:DASHSCOPE_API_KEY"
      else path="unknown"; evidence="none"; fi
      ;;
    deepseek)
      if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:DEEPSEEK_API_KEY"
      else path="unknown"; evidence="none"; fi
      ;;
  esac
  jq -cn --arg path "$path" --arg evidence "$evidence" --arg detail "$detail" \
    '{schema_version:1,path:$path,evidence:$evidence,detail:$detail}'
}

billing_auth_principal() {
  local mode principal
  [[ "$1" == codex ]] || return 0
  IFS=$'\t' read -r mode principal < <(codex_auth_observation) || return 0
  [[ -n "$principal" ]] && printf '%s\n' "$principal"
}

billing_cost_currency() {
  case "$1" in
    chatgpt_subscription|subscription_env_heuristic|oauth_env_heuristic|oauth_quota_heuristic) printf 'quota\n' ;;
    api_key|auth_token|access_token_env|api_key_env) printf 'usd\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Emit a QuotaObservation v1 envelope. The clawmeter contract is deliberately
# narrow and checked at the parsing boundary; it is never a launch gate.
quota_observation_v1() {
  local provider="$1" provider_key raw version usage_error stale state reason source observation
  case "$provider" in codex) provider_key=openai ;; claude) provider_key=claude ;; antigravity) provider_key=antigravity ;; qwen) provider_key=alibaba ;; *)
    jq -cn '{schema_version:1,state:"absent",reason:"clawmeter has no provider mapping",stale:false,source:"",observation:null}'
    return 0 ;;
  esac
  command -v clawmeter >/dev/null 2>&1 || {
    jq -cn '{schema_version:1,state:"absent",reason:"clawmeter not on PATH",stale:false,source:"",observation:null}'
    return 0
  }
  if declare -F clawmeter >/dev/null || ! command -v timeout >/dev/null 2>&1; then
    version="$(clawmeter --version 2>/dev/null || true)"
  else
    version="$(timeout 5 clawmeter --version 2>/dev/null || true)"
  fi
  if declare -F clawmeter >/dev/null; then
    raw="$(clawmeter --json 2>/dev/null)" || {
      jq -cn --arg reason "clawmeter --json failed" --arg source "clawmeter@${version}" '{schema_version:1,state:"absent",reason:$reason,stale:false,source:$source,observation:null}'
      return 0
    }
  elif command -v timeout >/dev/null 2>&1; then
    raw="$(timeout 10 clawmeter --json 2>/dev/null)" || {
      jq -cn --arg reason "clawmeter --json failed" --arg source "clawmeter@${version}" '{schema_version:1,state:"absent",reason:$reason,stale:false,source:$source,observation:null}'
      return 0
    }
  else
    raw="$(clawmeter --json 2>/dev/null)" || {
      jq -cn --arg reason "clawmeter --json failed" --arg source "clawmeter@${version}" '{schema_version:1,state:"absent",reason:$reason,stale:false,source:$source,observation:null}'
      return 0
    }
  fi
  # clawmeter >= 0.28 declares its --json contract; a declared-but-unknown major
  # is drift we must not shape-guess through. Absent field = pre-contract
  # binary: fall through to the shape checks below exactly as before.
  local declared_schema
  declared_schema="$(jq -r '.schema_version // empty' <<<"$raw" 2>/dev/null)"
  if [[ -n "$declared_schema" && "$declared_schema" != 1 ]]; then
    jq -cn --arg reason "clawmeter --json schema_version ${declared_schema} unsupported (expected 1)" --arg source "clawmeter@${version}" \
      '{schema_version:1,state:"absent",reason:$reason,stale:false,source:$source,observation:null}'
    return 0
  fi
  jq -e --arg p "$provider_key" '
    .providers[$p].usage as $u |
    ($u | type == "object") and
    (($u.error // null) | type == "null" or type == "string") and
    (if ($u.error // "") != "" then true else
      (($u.windows // null) | type == "array") and
      (($u.stale // false) | type == "boolean") and
      (($u.fetched_at // null) | type == "string") and
      (.providers[$p].forecast | type == "object") and
      ((.providers[$p].forecast.windows // null) | type == "object") and
      all($u.windows[]; type == "object" and ((.name // .display_name // null) | type == "string") and (.utilization | type == "number") and (.resets_at | type == "string"))
    end)' >/dev/null <<<"$raw" 2>/dev/null || {
    jq -cn --arg reason "clawmeter JSON has unsupported provider shape" --arg source "clawmeter@${version}" '{schema_version:1,state:"absent",reason:$reason,stale:false,source:$source,observation:null}'
    return 0
  }
  usage_error="$(jq -r --arg p "$provider_key" '.providers[$p].usage.error // empty' <<<"$raw")"
  stale="$(jq -r --arg p "$provider_key" '.providers[$p].usage.stale // false' <<<"$raw")"
  source="clawmeter@${version}"
  if [[ -n "$usage_error" ]]; then state=provider_error; reason="$usage_error"; observation=null
  else
    [[ "$stale" == true ]] && state=stale || state=ok
    reason=""
    observation="$(jq -c --arg p "$provider_key" '
      .providers[$p] as $provider |
      {provider_key:$p,
       windows:[(($provider.usage.windows // [])[] | {
         name:(.name // .display_name // ""),
         utilization_pct:(.utilization // null), resets_at:(.resets_at // null),
         projected_pct:($provider.forecast.windows[(.name // .display_name // "")].projected_pct // null)
       })],
       reset_credits_available:(if $p == "openai" then ($provider.usage.reset_credits.available_count // null) else null end),
       fetched_at:($provider.usage.fetched_at // null)}' <<<"$raw" 2>/dev/null)" || observation=null
  fi
  jq -cn --arg state "$state" --arg reason "$reason" --argjson stale "$([[ "$stale" == true ]] && echo true || echo false)" --arg source "$source" --argjson observation "$observation" \
    '{schema_version:1,state:$state,reason:$reason,stale:$stale,source:$source,observation:$observation}'
}
