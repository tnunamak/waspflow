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
}

billing_preflight_provider() {
  local provider="$1"
  case "$provider" in
    claude) billing_preflight_claude ;;
    codex) billing_preflight_codex ;;
    grok) billing_preflight_grok ;;
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
