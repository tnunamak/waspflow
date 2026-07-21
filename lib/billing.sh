#!/usr/bin/env bash
#
# billing.sh — env-only billing/auth safety checks.
#
# This intentionally does not call provider CLIs or networks. It only reports
# and gates on environment variables that change billing paths.

billing_report_auth() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "  [warn] claude auth: ANTHROPIC_API_KEY is set -> headless workers bill pay-as-you-go API rates, NOT your subscription. A fleet can run up large charges (see issue #37686). Unset it to use your subscription."
  else
    echo "  [ok]   claude auth: subscription/Agent-SDK credit (no ANTHROPIC_API_KEY)"
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "  [warn] codex auth: OPENAI_API_KEY is set -> headless Codex may use API pay-as-you-go billing instead of subscription-backed CLI auth. Verify billing before fleet use."
  else
    echo "  [ok]   codex auth: no OPENAI_API_KEY in environment; billing follows configured Codex CLI auth"
  fi

  if [[ -n "${XAI_API_KEY:-}" ]]; then
    echo "  [warn] grok auth: XAI_API_KEY is set -> headless Grok may use API pay-as-you-go billing instead of OAuth/subscription-backed CLI auth. Verify billing before fleet use."
  else
    echo "  [ok]   grok auth: no XAI_API_KEY in environment; billing follows configured Grok CLI auth (OAuth cache or login)"
  fi

  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    echo "  [warn] gemini auth: GEMINI_API_KEY is set -> headless Gemini may use API pay-as-you-go billing instead of OAuth/subscription-backed CLI auth. Verify billing before fleet use."
  else
    echo "  [ok]   gemini auth: no GEMINI_API_KEY in environment; billing follows configured Gemini CLI auth (OAuth cache or login)"
  fi
}

billing_preflight_provider() {
  local provider="$1"
  case "$provider" in
    claude) billing_preflight_claude ;;
    codex) billing_preflight_codex ;;
    grok) billing_preflight_grok ;;
    gemini) billing_preflight_gemini ;;
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
  [[ -n "${OPENAI_API_KEY:-}" ]] || return 0
  warn "codex billing notice: OPENAI_API_KEY is set; verify whether Codex will use API pay-as-you-go billing before fleet use."
  return 0
}

billing_preflight_grok() {
  [[ -n "${XAI_API_KEY:-}" ]] || return 0
  warn "grok billing notice: XAI_API_KEY is set; verify whether Grok will use API pay-as-you-go billing before fleet use."
  return 0
}

billing_preflight_gemini() {
  [[ -n "${GEMINI_API_KEY:-}" ]] || return 0
  warn "gemini billing notice: GEMINI_API_KEY is set; verify whether Gemini will use API pay-as-you-go billing before fleet use."
  return 0
}

# Emit BillingPath v1. This is observational only: an uncertain billing path
# never changes whether a lane may launch. Args: provider endpoint_profile raw_args
billing_path_v1() {
  local provider="$1" endpoint_profile="${2:-default}" raw_args="${3:-false}"
  local path="unknown" evidence="none" detail="" status=""
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
        if command -v codex >/dev/null 2>&1; then
          status="$(codex login status 2>&1 || true)"
          if grep -qi 'Logged in using ChatGPT' <<<"$status"; then
            path="chatgpt_subscription"; evidence="codex_login_status_text"; detail="$(head -n 1 <<<"$status")"
          elif grep -qiE 'api[ -]?key' <<<"$status"; then
            path="api_key"; evidence="codex_login_status_text"; detail="$(head -n 1 <<<"$status")"
          fi
        fi
        if [[ "$path" == unknown && -n "${CODEX_ACCESS_TOKEN:-}" ]]; then path="access_token_env"; evidence="env:CODEX_ACCESS_TOKEN"
        elif [[ "$path" == unknown && -n "${OPENAI_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:OPENAI_API_KEY"; fi
      fi
      ;;
    grok)
      if [[ -n "${XAI_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:XAI_API_KEY"
      else path="oauth_env_heuristic"; evidence="absence_of_XAI_API_KEY"; fi
      ;;
    gemini)
      if [[ -n "${GEMINI_API_KEY:-}" ]]; then path="api_key_env"; evidence="env:GEMINI_API_KEY"
      else path="oauth_env_heuristic"; evidence="absence_of_GEMINI_API_KEY"; fi
      ;;
  esac
  jq -cn --arg path "$path" --arg evidence "$evidence" --arg detail "$detail" \
    '{schema_version:1,path:$path,evidence:$evidence,detail:$detail}'
}

billing_auth_principal() {
  [[ "$1" == codex ]] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  codex login status 2>&1 | sed -nE '/^[[:space:]]*(Account|Logged in as)[[:space:]]*:/Ip' | head -1 || true
}

billing_cost_currency() {
  case "$1" in
    chatgpt_subscription|subscription_env_heuristic|oauth_env_heuristic) printf 'quota\n' ;;
    api_key|auth_token|access_token_env|api_key_env) printf 'usd\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Emit a QuotaObservation v1 envelope. The clawmeter contract is deliberately
# narrow and checked at the parsing boundary; it is never a launch gate.
quota_observation_v1() {
  local provider="$1" provider_key raw version usage_error stale state reason source observation
  case "$provider" in codex) provider_key=openai ;; claude) provider_key=claude ;; *)
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
