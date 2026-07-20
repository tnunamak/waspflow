#!/usr/bin/env bash
# Owner-run privileged/live proof of the six-column auth matrix for a Federation
# v0 harness, per the auth-model-tightening correction (2026-07-20). Supersedes
# scripts/federation-auth-proof-live-run.sh, which treated auth as one solved
# case (a single Docker-native-OAuth proof shared by Codex and Claude, with no
# distinction between "token extractable" and "subscription usable
# indefinitely", and no third custom-harness extensibility proof).
#
# This script is HARNESS-PARAMETERIZED. It does not itself encode "the" answer
# for Codex/Claude — the answer is declared per-harness in
# lib/federation-harnesses.mjs (a HarnessSpec) and this script drives whatever
# that spec says: its install method, its login-status probe, its declared
# auth_strategy. Read lib/federation-harness-spec.mjs's module doc before
# touching this script — it explains why "a request succeeded through a
# compatible endpoint" is NOT proof of subscription billing, and why "a token
# was read from a host file" is NOT proof that refresh works.
#
# Six-column matrix produced per harness (the exact columns requested):
#   1. existing host login detected
#   2. extra login required
#   3. credential stays outside VM
#   4. refresh works
#   5. subscription allowance used
#   6. full CLI runs in VM
#
# Usage:
#   bash scripts/federation-harness-auth-proof-live-run.sh codex
#   bash scripts/federation-harness-auth-proof-live-run.sh claude-code               # subscription (default, product intent)
#   bash scripts/federation-harness-auth-proof-live-run.sh claude-code-api-key       # usage-billed, smoother (operator opt-in)
#   bash scripts/federation-harness-auth-proof-live-run.sh gh-cli
#
# Claude Code has two real auth paths — a product tradeoff the OPERATOR
# chooses, this script does not silently pick one (owner steer, 2026-07-20).
# Confirmed against a real sbx v0.35.0 install: `sbx secret set --oauth` is
# openai-only ("anthropic OAuth cannot be started from `sbx secret set`; sign
# in from inside the Claude sandbox" is the CLI's own error for
# `-g anthropic --oauth`). So:
#   claude-code           — subscription billing (the product intent: pooling
#                            wasted SUBSCRIPTION capacity). Login is `/login`
#                            typed inside an attached sandbox session —
#                            UNAVOIDABLE friction in v0, an sbx limitation,
#                            not a Waspflow design choice.
#   claude-code-api-key   — usage-billed at standard API rates, but host-side
#                            and waspflow-drivable, same smooth shape as
#                            Codex's OAuth. Requires ANTHROPIC_API_KEY set on
#                            the host before running this script.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${1:-}"

usage() {
  echo "usage: $0 {codex|claude-code|claude-code-api-key|gh-cli}" >&2
  echo "  codex               — Docker built-in agent, docker-native-oauth strategy" >&2
  echo "  claude-code         — Docker built-in agent, docker-native-oauth (subscription, default; unavoidable in-sandbox /login)" >&2
  echo "  claude-code-api-key — Docker built-in agent, docker-stored-secret (usage-billed, smoother; requires ANTHROPIC_API_KEY on host)" >&2
  echo "  gh-cli              — Waspflow custom kit (kits/wf-gh-cli/spec.yaml), host-env-proxy strategy (extensibility proof)" >&2
  exit 2
}
[[ "$harness" == "codex" || "$harness" == "claude-code" || "$harness" == "claude-code-api-key" || "$harness" == "gh-cli" ]] || usage

if ! command -v sbx >/dev/null 2>&1; then
  echo "ERROR: sbx is not installed. Install from https://docs.docker.com/ai/sandboxes/get-started/" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node is required to read the HarnessSpec from lib/federation-harnesses.mjs" >&2
  exit 1
fi

# --- pull the declared HarnessSpec so this script drives the spec, not the
#     other way around. A change to the spec (e.g. reclassifying a harness's
#     auth_strategy) changes what this script attempts without editing bash.
harness_spec_snippet="import { CODEX_HARNESS, CLAUDE_CODE_SUBSCRIPTION_HARNESS, CLAUDE_CODE_API_KEY_HARNESS, GH_CLI_HARNESS } from '$root/lib/federation-harnesses.mjs'; const specs = { codex: CODEX_HARNESS, 'claude-code': CLAUDE_CODE_SUBSCRIPTION_HARNESS, 'claude-code-api-key': CLAUDE_CODE_API_KEY_HARNESS, 'gh-cli': GH_CLI_HARNESS }; const spec = specs['$harness'];"
spec_json="$(node --input-type=module -e "$harness_spec_snippet process.stdout.write(JSON.stringify(spec));")"
field() { node -e "process.stdout.write(String(JSON.parse(process.argv[1])$1 ?? ''))" "$spec_json"; }

install="$(field '.install')"
entrypoint="$(field '.entrypoint')"
auth_strategy="$(field '.auth_strategy')"
login_command="$(field '.credential_discovery.login_command')"
env_var="$(field '.credential_discovery.env_var')"
status_command="$(field '.login_status_probe.command')"
mode_hint="$(field '.login_status_probe.mode_field_hint')"

echo "=== HarnessSpec for '$harness' ==="
echo "install=$install entrypoint=\"$entrypoint\" auth_strategy=$auth_strategy"
echo

# --- matrix bookkeeping ----------------------------------------------------
declare -A MATRIX
record() { local col="$1" value="$2"; MATRIX["$col"]="$value"; printf '  [%s] %s\n' "$col" "$value"; }

sandbox_a="wf-auth-proof-${harness}-a-$$"
sandbox_b="wf-auth-proof-${harness}-b-$$"
sandbox_c="wf-auth-proof-${harness}-c-$$"
scratch_a="$(mktemp -d)"; scratch_b="$(mktemp -d)"; scratch_c="$(mktemp -d)"
cleanup() {
  sbx rm "$sandbox_a" >/dev/null 2>&1 || true
  sbx rm "$sandbox_b" >/dev/null 2>&1 || true
  sbx rm "$sandbox_c" >/dev/null 2>&1 || true
  rm -rf "$scratch_a" "$scratch_b" "$scratch_c"
}
trap cleanup EXIT

run_sandbox() {
  # $1 = sandbox name, $2 = scratch dir
  # `sbx run [flags] [AGENT] [PATH...]` — the AGENT positional comes BEFORE
  # the workspace path (confirmed against a real, detached sbx run; the
  # earlier reversed order made sbx read the path as an unknown agent name
  # and fail with "'<path>' is not a sandbox or known agent"). For a
  # kind:sandbox kit, AGENT must equal the kit's own manifest `name` (sbx
  # errors explicitly otherwise) — `install` already carries that value for
  # gh-cli.
  if [[ "$harness" == "gh-cli" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo "ERROR: GH_TOKEN must be set on the HOST for the gh-cli extensibility proof (host-env-proxy strategy)." >&2
      echo "This is intentionally a static PAT, not a refreshing credential — see kits/wf-gh-cli/spec.yaml." >&2
      exit 1
    fi
    sbx run --name "$1" "$install" "$2" --kit "$root/kits/$install"
  else
    sbx run --name "$1" "$install" "$2"
  fi
}

echo "=== [1/6] existing host login detected / extra login required ==="
echo "Per the auth UX reframe: WASPFLOW runs the auth command itself and does"
echo "detect-first — it never tells the operator to type a command. The operator"
echo "does only the browser step when (and only when) one is actually needed."
case "$auth_strategy" in
  docker-native-oauth)
    flow_shape="$(field '.credential_discovery.flow_shape')"
    if [[ "$flow_shape" == "host-url-flow" ]]; then
      # federation-auth-flow.mjs does detect-first (isProviderSecretSet) and,
      # only if unset, drives the login itself (startAuthFlow) — printing ONLY
      # the structured {url} it parses out, never the raw sbx command. v0's
      # terminal harness renders that URL as text; a future non-terminal UI
      # would render the same {url, waitForCompletion} shape differently
      # without any change to federation-auth-flow.mjs itself.
      node --input-type=module -e "
        $harness_spec_snippet
        import { isProviderSecretSet, startAuthFlow } from '$root/lib/federation-auth-flow.mjs';
        const { alreadySet } = await isProviderSecretSet(spec);
        if (alreadySet) {
          console.log('DETECT_RESULT already_set');
          process.exit(0);
        }
        console.log('DETECT_RESULT needs_login');
        const handle = startAuthFlow(spec);
        const urlWait = setInterval(() => {
          if (handle.url) { clearInterval(urlWait); console.log('AUTH_URL ' + handle.url); }
        }, 50);
        const result = await handle.waitForCompletion();
        clearInterval(urlWait);
        console.log('FLOW_RESULT ' + result.status + ' ' + result.detail.replace(/\\n/g, ' | '));
        process.exit(result.status === 'complete' ? 0 : 1);
      " > /tmp/wf-auth-flow-$$.out 2>&1
      flow_rc=$?
      cat /tmp/wf-auth-flow-$$.out
      if grep -q "DETECT_RESULT already_set" /tmp/wf-auth-flow-$$.out; then
        record "existing_host_login_detected" "yes (detected via isProviderSecretSet — no login command run)"
        record "extra_login_required" "no"
      elif [[ "$flow_rc" -eq 0 ]]; then
        record "existing_host_login_detected" "no"
        record "extra_login_required" "yes — waspflow drove the login itself; operator only completed the browser step at the printed AUTH_URL"
      else
        record "existing_host_login_detected" "no"
        record "extra_login_required" "FAIL-CANDIDATE — waspflow-driven login flow did not complete; see output above"
      fi
      rm -f /tmp/wf-auth-flow-$$.out
    else
      # interactive-session-flow (Claude Code): honestly not drivable
      # host-side — describeAuthRequirement() explains why (no URL exists to
      # capture; /login must run inside an attached sandbox session).
      instruction="$(node --input-type=module -e "$harness_spec_snippet import { describeAuthRequirement } from '$root/lib/federation-auth-flow.mjs'; console.log(describeAuthRequirement(spec).instruction);")"
      echo "NOTE: '$harness' uses an interactive-session-flow login (not a host-side URL)."
      echo "$instruction"
      read -r -p "Once '$login_command' has been completed inside an attached sandbox session, press Enter... "
      record "existing_host_login_detected" "n/a (interactive-session-flow; waspflow cannot detect this host-side)"
      record "extra_login_required" "operator-attested — see describeAuthRequirement() instruction above"
    fi
    ;;
  host-env-proxy)
    if [[ -n "${!env_var:-}" ]]; then
      record "existing_host_login_detected" "yes ($env_var is set on host)"
      record "extra_login_required" "no"
    else
      record "existing_host_login_detected" "no"
      record "extra_login_required" "yes ($env_var must be set on host before this run — see usage above)"
    fi
    ;;
  docker-stored-secret)
    # Smooth, host-side, waspflow-drivable path (e.g. claude-code-api-key):
    # `sbx secret ls` detect-first, then `sbx secret set -g <service>` via
    # stdin if unset — same detect-first discipline as startAuthFlow's
    # host-url-flow, just without a browser step since a static API key
    # needs no user interaction at all beyond having exported it on the host.
    secret_name="$(field '.credential_discovery.secret_name')"
    if [[ "$harness" == "claude-code-api-key" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "ERROR: ANTHROPIC_API_KEY must be set on the HOST for claude-code-api-key (docker-stored-secret strategy)." >&2
      echo "This is the usage-billed alternative to the default subscription harness — see usage above for the tradeoff." >&2
      exit 1
    fi
    ls_output="$(sbx secret ls -g --service "$secret_name" 2>&1 || true)"
    if grep -qi "No secrets found" <<<"$ls_output"; then
      record "existing_host_login_detected" "no"
      echo "Setting the '$secret_name' secret via stdin (waspflow drives this; the operator never types the raw sbx command)..."
      if echo "${ANTHROPIC_API_KEY:-}" | sbx secret set -g "$secret_name" >/dev/null 2>&1; then
        record "extra_login_required" "yes — waspflow drove 'sbx secret set -g $secret_name' via stdin from the host's ANTHROPIC_API_KEY; no browser/interactive step needed"
      else
        record "extra_login_required" "FAIL-CANDIDATE — sbx secret set -g $secret_name did not succeed"
      fi
    else
      record "existing_host_login_detected" "yes (detected via sbx secret ls — no login triggered)"
      record "extra_login_required" "no"
    fi
    ;;
esac

echo
echo "=== [2/6] full CLI runs in VM ==="
run_sandbox "$sandbox_a" "$scratch_a"
if sbx ls | grep -qF "$sandbox_a"; then
  record "full_cli_runs_in_vm" "PASS-CANDIDATE — sandbox '$sandbox_a' created and listed by sbx ls"
else
  record "full_cli_runs_in_vm" "FAIL-CANDIDATE — sandbox '$sandbox_a' not listed after sbx run"
fi

echo
echo "=== [3/6] credential stays outside VM (hostile guest search) ==="
echo "Searching guest env, process args, and common credential file locations for a"
echo "reusable token rather than a proxy sentinel (e.g. 'proxy-managed')."
search_output="$(sbx exec "$sandbox_a" -- sh -c 'env; ps aux; cat ~/.codex/auth.json 2>/dev/null || true; cat ~/.claude/.credentials.json 2>/dev/null || true; echo "GH_TOKEN=$GH_TOKEN"' 2>&1 || true)"
echo "$search_output"
if grep -qE '"(access_token|refresh_token)"\s*:\s*"[A-Za-z0-9_.\-]{40,}"|gh[a-z]_[A-Za-z0-9]{30,}' <<<"$search_output" && ! grep -qiE 'proxy-managed|sbx-cs-' <<<"$search_output"; then
  record "credential_stays_outside_vm" "FAIL-CANDIDATE — output above contains what looks like a real, non-sentinel token"
else
  record "credential_stays_outside_vm" "PASS-CANDIDATE — no non-sentinel reusable-token pattern found (operator must still eyeball the raw output above; this heuristic is not exhaustive)"
fi

echo
echo "=== [4/6] refresh works (only meaningful where a refresh cycle exists) ==="
case "$auth_strategy" in
  docker-native-oauth)
    echo "This strategy claims docker-builtin refresh (see lib/federation-harnesses.mjs's"
    echo "oauth_refresh.evidence for this harness). Proof requires a task that spans past a"
    echo "token's natural expiry window and confirms the CLI still works without a new login."
    echo "This is NOT automated here (would require holding a sandbox open for the token's"
    echo "real expiry window, ~1h for OAuth access tokens) — record as a manual follow-up:"
    record "refresh_works" "NOT EXERCISED THIS RUN — requires a long-duration follow-up holding the sandbox open past token expiry; short-run proof cannot distinguish 'never needed refresh' from 'refresh works'"
    ;;
  host-env-proxy)
    record "refresh_works" "N/A — $harness's credential ($env_var) is static and does not refresh (oauth_refresh.supports_refresh=false in the HarnessSpec); this column does not apply"
    ;;
  docker-stored-secret)
    record "refresh_works" "N/A — $harness's credential ($secret_name) is a static API key and does not refresh (oauth_refresh.supports_refresh=false in the HarnessSpec); this column does not apply"
    ;;
esac

echo
echo "=== [5/6] subscription allowance used (REPORTED auth mode, not just request success) ==="
echo "Per the correction: a successful request through a compatible endpoint is NOT"
echo "sufficient proof of subscription billing. Checking the harness's OWN reported mode:"
echo "  $status_command"
echo "  Expected: $mode_hint"
status_output="$(sbx exec "$sandbox_a" -- sh -c "$status_command" 2>&1 || echo "STATUS_COMMAND_FAILED")"
echo "$status_output"
case "$harness" in
  codex)
    if grep -qiE '"auth_mode"\s*:\s*"(chatgpt|chatgptAuthTokens)"' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE — auth_mode reports chatgpt/chatgptAuthTokens (subscription), not apiKey"
    elif grep -qi '"auth_mode"\s*:\s*"apiKey"' <<<"$status_output"; then
      record "subscription_allowance_used" "FAIL-CANDIDATE — auth_mode reports apiKey (usage-billed API), not subscription"
    else
      record "subscription_allowance_used" "INCONCLUSIVE — could not parse auth_mode from status output above; operator must inspect manually"
    fi
    ;;
  claude-code)
    if grep -qi 'CLAUDE_CODE_OAUTH_TOKEN' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE — Auth token field reports CLAUDE_CODE_OAUTH_TOKEN (subscription)"
    elif grep -qi 'ANTHROPIC_API_KEY' <<<"$status_output"; then
      record "subscription_allowance_used" "FAIL-CANDIDATE — Auth token field reports ANTHROPIC_API_KEY (usage-billed), not subscription"
    else
      record "subscription_allowance_used" "INCONCLUSIVE — could not parse the Auth token field from /status output above; operator must inspect manually"
    fi
    ;;
  claude-code-api-key)
    # Inverted expectation vs claude-code: THIS harness's whole point is the
    # usage-billed path, so ANTHROPIC_API_KEY reporting is the CORRECT
    # result, not a failure — flag CLAUDE_CODE_OAUTH_TOKEN as unexpected
    # instead (would mean the sandbox fell back to a stray subscription
    # login rather than the configured API key).
    if grep -qi 'ANTHROPIC_API_KEY' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE (usage-billed, as intended for this harness) — Auth token field reports ANTHROPIC_API_KEY, not subscription. This is the expected/correct result for claude-code-api-key, not a failure."
    elif grep -qi 'CLAUDE_CODE_OAUTH_TOKEN' <<<"$status_output"; then
      record "subscription_allowance_used" "FAIL-CANDIDATE — Auth token field reports CLAUDE_CODE_OAUTH_TOKEN (subscription); expected ANTHROPIC_API_KEY for this harness"
    else
      record "subscription_allowance_used" "INCONCLUSIVE — could not parse the Auth token field from /status output above; operator must inspect manually"
    fi
    ;;
  gh-cli)
    record "subscription_allowance_used" "N/A — gh-cli has no subscription billing distinction; this column does not apply to the extensibility proof"
    ;;
esac
echo "Also confirm via the provider's OWN usage dashboard (or 'clawmeter' for Claude/Codex"
echo "quota) that usage increased after a real task — REPORTED mode plus an observed usage"
echo "delta together are the proof; neither alone is sufficient."

echo
echo "=== [6/6] cancellation + teardown (process+sandbox killed, host credential survives) ==="
run_sandbox "$sandbox_b" "$scratch_b" >/dev/null
sbx exec "$sandbox_b" -- sh -c 'sleep 60 &' >/dev/null 2>&1 || true
sbx stop "$sandbox_b" >/dev/null 2>&1 || true
if sbx ls | grep -F "$sandbox_b" | grep -qiE 'running|up'; then
  echo "  FAIL-CANDIDATE: sandbox '$sandbox_b' still shows running/up after stop"
else
  echo "  PASS-CANDIDATE: sandbox '$sandbox_b' stopped as expected"
fi
sbx rm "$sandbox_a" >/dev/null 2>&1 || true
run_sandbox "$sandbox_c" "$scratch_c" >/dev/null
third_status="$(sbx exec "$sandbox_c" -- sh -c "$status_command" 2>&1 || true)"
if grep -qiE 'login|sign.?in|not authenticated|unauthenticated' <<<"$third_status"; then
  echo "  FAIL-CANDIDATE: a fresh sandbox required a new login — host credential did not survive prior sandbox removal"
else
  echo "  PASS-CANDIDATE: a fresh sandbox authenticated without a new login prompt — host credential survived removal of sandbox '$sandbox_a'"
fi

echo
echo "=== Six-column matrix summary for harness '$harness' ==="
for col in existing_host_login_detected extra_login_required credential_stays_outside_vm refresh_works subscription_allowance_used full_cli_runs_in_vm; do
  printf '%-30s %s\n' "$col" "${MATRIX[$col]:-NOT RECORDED}"
done
echo
echo "Every PASS-CANDIDATE/FAIL-CANDIDATE/INCONCLUSIVE above requires operator eyeball"
echo "confirmation against the raw output — this script surfaces evidence, it does not"
echo "itself grade a passing security claim. Record results in"
echo "docs/design/FEDERATION_V0_UAT_REPORT.md's per-harness auth matrix."
