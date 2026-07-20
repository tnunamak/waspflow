#!/usr/bin/env bash
# Owner-run privileged/live proof that Docker Sandboxes' NATIVE host-side
# OAuth/credential proxy is the correct auth substrate for Federation v0's
# Codex and Claude jobs — NOT a custom Waspflow gateway or OpenAI-compatible
# endpoint. See inbox correction (auth architecture correction, 2026-07-20)
# and docs/design/FEDERATION_V0_UAT_REPORT.md's "Auth architecture" section.
#
# This script requires: sbx installed and on PATH, a real Docker account, and
# (for Codex) willingness to complete a one-time host-side OAuth login. It is
# NOT run by CI or scripts/verify.sh — it consumes real provider quota and
# needs an interactive login step. Run it by hand on a machine with sbx.
#
# What it proves, matching the six numbered requirements in the auth
# correction:
#   1. Login via Docker's documented flow (sbx secret set -g openai --oauth
#      for Codex; /login inside the sandbox for Claude).
#   2. Codex/Claude executes entirely inside the sandbox.
#   3. No reusable OAuth token / host auth dir is readable inside the
#      sandbox — a hostile guest search of env, files, process args, and
#      config finds only proxy-managed placeholders.
#   4. A real task consumes the host owner's intended subscription
#      allowance (operator eyeballs their own usage dashboard/CLI quota
#      display before/after — this script cannot observe billing state from
#      outside the provider's own account).
#   5. Cancellation kills the process and the sandbox.
#   6. Removing the sandbox destroys guest state WITHOUT deleting the host
#      credential (a second sandbox can authenticate without re-login).
#
# Usage:
#   bash scripts/federation-auth-proof-live-run.sh codex
#   bash scripts/federation-auth-proof-live-run.sh claude
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent="${1:-}"

usage() {
  echo "usage: $0 {codex|claude}" >&2
  echo "  codex  — proves sbx secret set -g openai --oauth stays host-side" >&2
  echo "  claude — proves Claude Code's /login stays proxy-mediated, not guest-held" >&2
  exit 2
}
[[ "$agent" == "codex" || "$agent" == "claude" ]] || usage

if ! command -v sbx >/dev/null 2>&1; then
  echo "ERROR: sbx is not installed. Install from https://docs.docker.com/ai/sandboxes/get-started/" >&2
  exit 1
fi

sandbox_a="wf-auth-proof-${agent}-a-$$"
sandbox_b="wf-auth-proof-${agent}-b-$$"
scratch_a="$(mktemp -d)"
scratch_b="$(mktemp -d)"
cleanup() {
  sbx rm "$sandbox_a" >/dev/null 2>&1 || true
  sbx rm "$sandbox_b" >/dev/null 2>&1 || true
  rm -rf "$scratch_a" "$scratch_b"
}
trap cleanup EXIT

echo "=== [1/6] Login via Docker's documented flow ==="
if [[ "$agent" == "codex" ]]; then
  echo "Run this yourself first, once, if not already done on this host:"
  echo "  sbx secret set -g openai --oauth"
  echo "This opens a HOST-side browser login. The resulting token is stored in the"
  echo "host's credential store, never written into any sandbox filesystem."
  read -r -p "Press Enter once 'sbx secret set -g openai --oauth' has completed on this host... "
else
  echo "Claude Code's /login is typed INSIDE the sandbox's interactive session, but per"
  echo "Docker's credential-isolation docs, the OAuth flow and resulting session are"
  echo "proxy-mediated: the sandbox sees a sentinel, real credential material is not"
  echo "guest-resident. This script starts the sandbox; complete /login when it opens,"
  echo "then detach (the sandbox stays up for the rest of this proof)."
fi

echo
echo "=== [2/6] Codex/Claude executes entirely inside the sandbox ==="
sbx run --name "$sandbox_a" "$scratch_a" "$agent"
echo "Sandbox '$sandbox_a' created with the built-in '$agent' agent template."
echo "PASS-CANDIDATE (manual confirmation required): the agent CLI is running inside"
echo "  the sandbox's microVM, not on the host — confirm via:"
echo "    sbx ls | grep -F '$sandbox_a'"
sbx ls | grep -F "$sandbox_a" || echo "FAIL-CANDIDATE: sandbox '$sandbox_a' not listed by sbx ls"

echo
echo "=== [3/6] Hostile guest search for a reusable OAuth token / host auth dir ==="
echo "Searching guest env, common credential file locations, process args, and agent"
echo "config for anything that looks like a raw reusable token rather than a proxy"
echo "sentinel (e.g. 'proxy-managed', 'sbx-cs-<rand>')."

search_targets_codex=(
  'env'
  'cat ~/.codex/auth.json 2>/dev/null || echo NOT_PRESENT'
  'cat ~/.config/openai/* 2>/dev/null || echo NOT_PRESENT'
  'ps aux'
)
search_targets_claude=(
  'env'
  'cat ~/.claude/.credentials.json 2>/dev/null || echo NOT_PRESENT'
  'cat ~/.config/anthropic/* 2>/dev/null || echo NOT_PRESENT'
  'ps aux'
)
if [[ "$agent" == "codex" ]]; then targets=("${search_targets_codex[@]}"); else targets=("${search_targets_claude[@]}"); fi

found_reusable_token=0
for cmd in "${targets[@]}"; do
  echo "--- guest\$ $cmd ---"
  output="$(sbx exec "$sandbox_a" -- sh -c "$cmd" 2>&1 || true)"
  echo "$output"
  # A real OAuth access/refresh token is long, high-entropy, and NOT one of the
  # documented sentinel shapes. This is a heuristic, not a proof of absence —
  # an operator must eyeball the raw output above, not just trust this grep.
  if grep -qE '"(access_token|refresh_token)"\s*:\s*"[A-Za-z0-9_.\-]{40,}"' <<<"$output"; then
    if ! grep -qiE 'proxy-managed|sbx-cs-' <<<"$output"; then
      found_reusable_token=1
      echo "FAIL-CANDIDATE: output above contains what looks like a real, non-sentinel token"
    fi
  fi
done
if [[ "$found_reusable_token" -eq 0 ]]; then
  echo "PASS-CANDIDATE: no non-sentinel reusable token pattern found in the searched surfaces"
  echo "  (operator must still eyeball the raw output above — this heuristic can miss"
  echo "  provider-specific token formats it wasn't written to recognize)"
fi

echo
echo "=== [4/6] A real task consumes the host owner's subscription allowance ==="
echo "This script cannot observe your provider account's usage/quota from outside your"
echo "own authenticated session. Manual step:"
echo "  a) Note your current usage (e.g. 'clawmeter' for Claude/Codex quota, or the"
echo "     provider's own dashboard) BEFORE this step."
if [[ "$agent" == "codex" ]]; then
  sbx exec "$sandbox_a" -- codex exec "Say the word PROOF_TASK_COMPLETE and nothing else." || echo "FAIL-CANDIDATE: codex exec did not run in sandbox"
else
  sbx exec "$sandbox_a" -- claude --print "Say the word PROOF_TASK_COMPLETE and nothing else." || echo "FAIL-CANDIDATE: claude did not run in sandbox"
fi
echo "  b) Note your usage AFTER this step. An increase confirms the task consumed the"
echo "     host owner's own subscription allowance (not a Waspflow-mediated credential)."

echo
echo "=== [5/6] Cancellation kills the process and the sandbox ==="
sbx run --name "$sandbox_b" "$scratch_b" "$agent" >/dev/null
long_running_pid_check() { sbx exec "$sandbox_b" -- sh -c 'sleep 60 & echo $!'; }
bg_pid="$(long_running_pid_check || true)"
echo "Started a background sleep in '$sandbox_b' (guest pid: ${bg_pid:-unknown})."
sbx stop "$sandbox_b" >/dev/null 2>&1 || true
if sbx ls | grep -F "$sandbox_b" | grep -qiE 'running|up'; then
  echo "FAIL-CANDIDATE: sandbox '$sandbox_b' still shows running/up after stop"
else
  echo "PASS-CANDIDATE: sandbox '$sandbox_b' is no longer running after stop"
fi

echo
echo "=== [6/6] Removing the sandbox destroys guest state WITHOUT deleting the host credential ==="
sbx rm "$sandbox_a" >/dev/null 2>&1 || true
if sbx ls | grep -qF "$sandbox_a"; then
  echo "FAIL-CANDIDATE: sandbox '$sandbox_a' still listed after rm"
else
  echo "PASS-CANDIDATE: sandbox '$sandbox_a' is gone after rm"
fi
echo "Now confirm the HOST credential survived: create a THIRD sandbox and check whether"
echo "it can authenticate without a fresh login prompt."
third_sandbox="wf-auth-proof-${agent}-c-$$"
third_scratch="$(mktemp -d)"
sbx run --name "$third_sandbox" "$third_scratch" "$agent" >/dev/null
if [[ "$agent" == "codex" ]]; then
  third_out="$(sbx exec "$third_sandbox" -- codex exec "Say READY" 2>&1 || true)"
else
  third_out="$(sbx exec "$third_sandbox" -- claude --print "Say READY" 2>&1 || true)"
fi
echo "$third_out"
if grep -qiE 'login|sign.?in|not authenticated' <<<"$third_out"; then
  echo "FAIL-CANDIDATE: third sandbox required a fresh login — host credential did not survive rm"
else
  echo "PASS-CANDIDATE: third sandbox authenticated without a new login prompt — host credential survived guest removal"
fi
sbx rm "$third_sandbox" >/dev/null 2>&1 || true
rm -rf "$third_scratch"

echo
echo "=== Auth proof run complete ($agent) ==="
echo "Every PASS-CANDIDATE/FAIL-CANDIDATE above requires operator eyeball confirmation"
echo "against the raw output — this script surfaces evidence, it does not itself grade"
echo "a passing security claim. Record the results in"
echo "docs/design/FEDERATION_V0_UAT_REPORT.md's auth architecture section."
