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
