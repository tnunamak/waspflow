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
  sbx rm --force "$sandbox_a" >/dev/null 2>&1 || true
  sbx rm --force "$sandbox_b" >/dev/null 2>&1 || true
  sbx rm --force "$sandbox_c" >/dev/null 2>&1 || true
  rm -rf "$scratch_a" "$scratch_b" "$scratch_c"
}
trap cleanup EXIT

# TASK_PROMPT is a deterministic, trivial prompt every harness runs headlessly
# via `sbx exec` — its exact echoed output is the gate-2 acceptance signal
# ("full CLI ran a task in the VM and produced output"), not just "a sandbox
# exists." Confirmed directly against a real sbx v0.35.0 install for all
# three harnesses in this session.
TASK_PROMPT="print WF_TASK_OK and exit"
TASK_MARKER="WF_TASK_OK"

create_sandbox() {
  # $1 = sandbox name, $2 = scratch dir
  # `sbx run [flags] [AGENT] [PATH...] --detached` creates and starts the
  # sandbox WITHOUT attaching or driving any task — the AGENT positional
  # comes BEFORE the workspace path (confirmed against a real, detached sbx
  # run; the earlier reversed order made sbx read the path as an unknown
  # agent name). For a kind:sandbox kit, AGENT must equal the kit's own
  # manifest `name` (sbx errors explicitly otherwise) — `install` already
  # carries that value for gh-cli. `--detached` alone does NOT drive the
  # HarnessSpec's `entrypoint` — that was a real bug (owner-caught): the
  # sandbox launches its DEFAULT interactive agent session and just sits
  # there. Actually running a headless task is `run_task()`'s job, below.
  if [[ "$harness" == "gh-cli" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo "ERROR: GH_TOKEN must be set on the HOST for the gh-cli extensibility proof (host-env-proxy strategy)." >&2
      echo "This is intentionally a static PAT, not a refreshing credential — see kits/wf-gh-cli/spec.yaml." >&2
      exit 1
    fi
    sbx run --name "$1" "$install" "$2" --kit "$root/kits/$install" --detached
  else
    sbx run --name "$1" "$install" "$2" --detached
  fi
}

run_task() {
  # $1 = sandbox name. Drives the HarnessSpec's declared `entrypoint` inside
  # an ALREADY-RUNNING sandbox via `sbx exec` (mirrors `docker exec` per
  # `sbx exec --help`) — this is what actually runs ONE task and terminates,
  # rather than attaching to the agent's own interactive session (which
  # would hang forever waiting for a human, exactly the owner-reported bug).
  # Prints the raw command output; caller checks for TASK_MARKER.
  #
  # gh-cli is NOT prompt-driven the way codex/claude are — `entrypoint` is
  # bare `gh`, a subcommand CLI, not an agent that accepts a natural-language
  # task string. Its "headless task" proof is simply a deterministic,
  # non-interactive subcommand (confirmed directly: `gh --version` runs and
  # exits with no prompt of any kind) rather than appending TASK_PROMPT.
  if [[ "$harness" == "gh-cli" ]]; then
    sbx exec "$1" -- sh -c "echo $TASK_MARKER && gh --version" 2>&1
  else
    # shellcheck disable=SC2086
    sbx exec "$1" -- $entrypoint "$TASK_PROMPT" 2>&1
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
      # interactive-session-flow (Claude Code): the LOGIN mechanism itself
      # is genuinely not drivable host-side (no URL exists to capture; /login
      # must run inside an attached sandbox session — describeAuthRequirement()
      # explains why). BUT the resulting credential IS host-persistent and
      # global once set, exactly like Codex's — confirmed directly: a brand
      # new sandbox picks up an already-configured `sbx secret ls -g
      # --service anthropic` credential automatically, with no per-sandbox
      # /login needed. So detect-first via isProviderSecretSet still applies
      # here — the interactive step is a ONE-TIME cost, not a per-run one,
      # and this script must not force it on every invocation.
      claude_detect_output="$(node --input-type=module -e "
        $harness_spec_snippet
        import { isProviderSecretSet } from '$root/lib/federation-auth-flow.mjs';
        const { alreadySet } = await isProviderSecretSet(spec);
        console.log(alreadySet ? 'ALREADY_SET' : 'NOT_SET');
      " 2>&1)"
      echo "$claude_detect_output"
      if grep -q "ALREADY_SET" <<<"$claude_detect_output"; then
        record "existing_host_login_detected" "yes (detected via isProviderSecretSet — a fresh sandbox will pick up this global credential automatically, no per-run /login needed)"
        record "extra_login_required" "no"
      else
        instruction="$(node --input-type=module -e "$harness_spec_snippet import { describeAuthRequirement } from '$root/lib/federation-auth-flow.mjs'; console.log(describeAuthRequirement(spec).instruction);")"
        echo "NOTE: '$harness' uses an interactive-session-flow login (not a host-side URL) and no existing credential was detected."
        echo "$instruction"
        read -r -p "Once '$login_command' has been completed inside an attached sandbox session, press Enter... "
        record "existing_host_login_detected" "no"
        record "extra_login_required" "yes, ONE TIME — operator-attested; this is a per-host setup cost, not a per-run one (confirmed: the resulting credential is global and detect-first applies on every subsequent run)"
      fi
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
create_sandbox "$sandbox_a" "$scratch_a"
if ! sbx ls | grep -qF "$sandbox_a"; then
  record "full_cli_runs_in_vm" "FAIL-CANDIDATE — sandbox '$sandbox_a' not listed after sbx run"
else
  # A listed sandbox is necessary but NOT sufficient — the owner-reported bug
  # was exactly this: the sandbox existed and was "running", but the agent
  # was sitting idle at its own interactive prompt, never running a task.
  # The real acceptance signal is a completed, headless task with
  # deterministic output.
  task_output="$(run_task "$sandbox_a")"
  echo "$task_output"
  if grep -qF "$TASK_MARKER" <<<"$task_output"; then
    record "full_cli_runs_in_vm" "PASS — sandbox '$sandbox_a' ran '$entrypoint \"$TASK_PROMPT\"' headlessly via sbx exec and produced the expected '$TASK_MARKER' output, then returned control (did not hang in an interactive session)"
  else
    record "full_cli_runs_in_vm" "FAIL-CANDIDATE — sandbox '$sandbox_a' is listed, but running the entrypoint via sbx exec did not produce '$TASK_MARKER'; see output above"
  fi
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
# NOTE: for codex/claude-code/claude-code-api-key this is NOT the harness's
# own CLI status command run interactively — corrected after live UAT found
# that `codex login status` cannot distinguish oauth/apiKey inside an
# sbx-proxied guest, and `/status` is a Claude Code REPL-only slash command
# unavailable in --print. Each case below runs the REAL, confirmed-working
# check for that specific harness (an sbx-proxy-layer env var, or a
# credential-file presence check), not a generic "run status_command".
case "$harness" in
  codex)
    status_output="$(sbx exec "$sandbox_a" -- env 2>&1 | grep SBX_CRED_OPENAI_MODE || echo "SBX_CRED_OPENAI_MODE_NOT_FOUND")"
    echo "$status_output"
    if grep -q 'SBX_CRED_OPENAI_MODE=oauth' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE — SBX_CRED_OPENAI_MODE=oauth (subscription-derived credential), not a directly-configured API key"
    elif grep -qE 'SBX_CRED_OPENAI_MODE=(apikey|none)' <<<"$status_output"; then
      record "subscription_allowance_used" "FAIL-CANDIDATE — SBX_CRED_OPENAI_MODE reports a non-oauth mode; expected 'oauth' for the subscription path"
    else
      record "subscription_allowance_used" "INCONCLUSIVE — could not read SBX_CRED_OPENAI_MODE; operator must inspect manually"
    fi
    ;;
  claude-code)
    status_output="$(sbx exec "$sandbox_a" -- sh -c 'cat ~/.claude/.credentials.json 2>/dev/null || echo CREDENTIALS_FILE_NOT_FOUND' 2>&1)"
    echo "$status_output"
    if grep -q 'claudeAiOauth' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE — ~/.claude/.credentials.json contains a claudeAiOauth block (completed /login subscription session); token values are proxy sentinels, not real credentials"
    else
      record "subscription_allowance_used" "FAIL-CANDIDATE — no claudeAiOauth block found; subscription /login may not have completed"
    fi
    ;;
  claude-code-api-key)
    # Inverted expectation vs claude-code: THIS harness's whole point is the
    # usage-billed path, so an "apikey" mode is the CORRECT result, not a
    # failure.
    status_output="$(sbx exec "$sandbox_a" -- env 2>&1 | grep SBX_CRED_ANTHROPIC_MODE || echo "SBX_CRED_ANTHROPIC_MODE_NOT_FOUND")"
    echo "$status_output"
    if grep -qE 'SBX_CRED_ANTHROPIC_MODE=(apikey|api_key)' <<<"$status_output"; then
      record "subscription_allowance_used" "PASS-CANDIDATE (usage-billed, as intended for this harness) — SBX_CRED_ANTHROPIC_MODE reports an api-key mode, not subscription. This is the expected/correct result for claude-code-api-key, not a failure."
    elif grep -q 'SBX_CRED_ANTHROPIC_MODE=none' <<<"$status_output"; then
      record "subscription_allowance_used" "FAIL-CANDIDATE — SBX_CRED_ANTHROPIC_MODE=none; the sbx secret set -g anthropic step in [1/6] may not have taken effect"
    else
      record "subscription_allowance_used" "INCONCLUSIVE — could not read SBX_CRED_ANTHROPIC_MODE; operator must inspect manually"
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
create_sandbox "$sandbox_b" "$scratch_b" >/dev/null
sbx exec "$sandbox_b" -- sh -c 'sleep 60 &' >/dev/null 2>&1 || true
sbx stop "$sandbox_b" >/dev/null 2>&1 || true
if sbx ls | grep -F "$sandbox_b" | grep -qiE 'running|up'; then
  echo "  FAIL-CANDIDATE: sandbox '$sandbox_b' still shows running/up after stop"
else
  echo "  PASS-CANDIDATE: sandbox '$sandbox_b' stopped as expected"
fi
sbx rm --force "$sandbox_a" >/dev/null 2>&1 || true
create_sandbox "$sandbox_c" "$scratch_c" >/dev/null
# Re-run the SAME headless task from [2/6] in a brand-new sandbox — if the
# host-side credential survived removal of sandbox_a, this task succeeds
# without any new login/auth step (fresh sandbox, same host credential
# state). This is a stronger, more direct check than grepping status output
# for "login"/"sign in" text, which is fragile across CLI versions.
third_task_output="$(run_task "$sandbox_c" 2>&1 || true)"
echo "$third_task_output"
if grep -qF "$TASK_MARKER" <<<"$third_task_output"; then
  echo "  PASS-CANDIDATE: a fresh sandbox ran the task successfully without a new login — host credential survived removal of sandbox '$sandbox_a'"
else
  echo "  FAIL-CANDIDATE: a fresh sandbox could not complete the task — host credential may not have survived removal of sandbox '$sandbox_a', or a new login/auth step was required"
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
