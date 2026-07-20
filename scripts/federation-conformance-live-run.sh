#!/usr/bin/env bash
# Owner-run privileged/live pass for the Docker Sandboxes graduation gates
# (A-I, inbox/2026-07-20-chatgpt-sandbox.md). This is NOT run by CI or by
# `scripts/verify.sh` — it requires a real, authenticated `sbx` installation
# and, for gate C, personal Docker Sandboxes already configured on the same
# machine with realistic developer credentials. Run this by hand on a machine
# that has sbx installed; do not attempt to automate it in this repo's
# hermetic test environment.
#
# Usage:
#   1. Install and authenticate sbx: https://docs.docker.com/ai/sandboxes/get-started/
#   2. For gate C only: configure your personal sbx with real credentials you
#      would not want a hostile guest to read (SSH agent forwarding on, a
#      registry login, etc) — testing a clean machine is insufficient.
#   3. Create a Waspflow-scoped sandbox and export its name:
#        export WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX=<sandbox-name>
#   4. (Gate A) export WASPFLOW_FEDERATION_SBX_PROFILE_DIR=<isolated profile dir>
#   5. (Gate D) create a second job's scratch dir and export
#        WASPFLOW_FEDERATION_CONFORMANCE_SIBLING_SCRATCH=<path>
#   6. Run this script. It runs tests/federation-docker-conformance.sh with
#      those variables set, then performs the additional checks that suite
#      documents as "structural only" so they can become real evidence.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_env() {
  local var=$1
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var must be set. See the usage comment at the top of this script." >&2
    exit 1
  fi
}

if ! command -v sbx >/dev/null 2>&1; then
  echo "ERROR: sbx is not installed. This script only runs on a machine with a real" >&2
  echo "Docker Sandboxes installation: https://docs.docker.com/ai/sandboxes/get-started/" >&2
  exit 1
fi

require_env WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX

echo "=== sbx version ==="
sbx version || sbx --version

echo
echo "=== Running tests/federation-docker-conformance.sh with live sandbox wired in ==="
bash "$root/tests/federation-docker-conformance.sh"

echo
echo "=== Gate F: bomb fixtures (measured) ==="
echo "Recording sandbox resource state before bombs..."
sbx inspect "$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX" || true

echo "--- fork bomb (bounded 5s attempt, then verify sandbox is still controllable) ---"
timeout 5 sbx exec "$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX" -- sh -c ':(){ :|:& };:' >/dev/null 2>&1 || true
if sbx exec "$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX" -- echo alive >/dev/null 2>&1; then
  echo "PASS-CANDIDATE: sandbox remained controllable after fork bomb attempt"
else
  echo "FAIL-CANDIDATE: sandbox became uncontrollable after fork bomb attempt"
fi

echo "--- memory exhaustion (bounded attempt) ---"
if timeout 10 sbx exec "$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX" -- sh -c 'python3 -c "b=bytearray(10**11)"' >/dev/null 2>&1; then
  echo "FAIL-CANDIDATE: 100GB allocation inside the guest did not fail — memory limit not enforced"
else
  echo "PASS-CANDIDATE: oversized allocation was rejected or killed"
fi

echo "--- disk fill (bounded attempt, 1TB request against declared storage_mib) ---"
if timeout 20 sbx exec "$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX" -- sh -c 'dd if=/dev/zero of=/tmp/fill bs=1M count=1000000' >/dev/null 2>&1; then
  echo "FAIL-CANDIDATE: 1TB write inside the guest did not fail — disk limit not enforced"
else
  echo "PASS-CANDIDATE: oversized write was rejected"
fi

echo
echo "=== Gate G: daemon-restart / reboot survival ==="
echo "Manual step required: restart the sbx daemon (or reboot this host), then run:"
echo "  sbx ls | grep -F \"$WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX\""
echo "A Waspflow orphan reaper on Waspflow startup should reconcile any sandbox found"
echo "here against active jobs and force-remove orphans. That reaper does not exist"
echo "in this checkout yet — this is a documented gap, not a passing gate."

echo
echo "=== Gate I reminder ==="
echo "This script cannot answer Docker's 8 outstanding legal/product questions."
echo "See docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md — they remain unanswered."

echo
echo "Live pass complete. Update docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md by hand"
echo "with the PASS-CANDIDATE/FAIL-CANDIDATE results above before claiming any gate PASS."
