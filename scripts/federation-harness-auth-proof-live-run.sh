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
#   bash scripts/federation-harness-auth-proof-live-run.sh claude-code
#   bash scripts/federation-harness-auth-proof-live-run.sh gh-cli
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${1:-}"

usage() {
  echo "usage: $0 {codex|claude-code|gh-cli}" >&2
  echo "  codex       — Docker built-in agent, docker-native-oauth strategy" >&2
  echo "  claude-code — Docker built-in agent, docker-native-oauth strategy" >&2
  echo "  gh-cli      — Waspflow custom kit (kits/wf-gh-cli.kit.yaml), host-env-proxy strategy (extensibility proof)" >&2
  exit 2
}
[[ "$harness" == "codex" || "$harness" == "claude-code" || "$harness" == "gh-cli" ]] || usage

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
spec_json="$(node --input-type=module -e "
import { CODEX_HARNESS, CLAUDE_CODE_HARNESS, GH_CLI_HARNESS } from '$root/lib/federation-harnesses.mjs';
const specs = { codex: CODEX_HARNESS, 'claude-code': CLAUDE_CODE_HARNESS, 'gh-cli': GH_CLI_HARNESS };
process.stdout.write(JSON.stringify(specs['$harness']));
")"
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
  if [[ "$harness" == "gh-cli" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo "ERROR: GH_TOKEN must be set on the HOST for the gh-cli extensibility proof (host-env-proxy strategy)." >&2
      echo "This is intentionally a static PAT, not a refreshing credential — see kits/wf-gh-cli.kit.yaml." >&2
      exit 1
    fi
    sbx run --name "$1" "$2" --kit "$root/kits/wf-gh-cli.kit.yaml"
  else
    sbx run --name "$1" "$2" "$install"
  fi
}

echo "=== [1/6] existing host login detected / extra login required ==="
case "$auth_strategy" in
  docker-native-oauth)
    echo "Checking for a pre-existing host-side credential for this service before this run."
    echo "If '$login_command' has already been completed on this host, no extra login is needed."
    read -r -p "Has '$login_command' already been completed on this host? [y/N] " already_done
    if [[ "${already_done,,}" == "y" ]]; then
      record "existing_host_login_detected" "yes (operator-confirmed)"
      record "extra_login_required" "no"
    else
      echo "Run this now, once, on the HOST: $login_command"
      read -r -p "Press Enter once that command has completed... "
      record "existing_host_login_detected" "no (fresh login performed this run)"
      record "extra_login_required" "yes (one-time host login)"
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
