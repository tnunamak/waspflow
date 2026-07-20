#!/usr/bin/env bash
# Adversarial conformance suite for DockerSbxBackend (Runtime Decision graduation gates A-I).
# Static checks always run. Live checks require a real sbx installation and SKIP with a clear
# message when absent — a SKIP is not a PASS; see docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md
# for what remains unproven pending real sbx, and scripts/federation-conformance-live-run.sh for
# the owner-run privileged/live pass.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- result bookkeeping --------------------------------------------------
declare -a GATE_NAMES=()
declare -a GATE_STATUS=()
declare -a GATE_REASON=()

record() {
  local name=$1 status=$2 reason=$3
  GATE_NAMES+=("$name")
  GATE_STATUS+=("$status")
  GATE_REASON+=("$reason")
  printf '%s: %s — %s\n' "$status" "$name" "$reason"
}

# --- environment probes --------------------------------------------------
have_sbx() { command -v sbx >/dev/null 2>&1; }

live_sandbox_handle() {
  # Operator-provided handle to a real, already-running sbx sandbox. Gates A-G
  # only attempt their live host-side assertions when this is set; otherwise
  # they SKIP even if sbx happens to be on PATH, because a bare `sbx` binary
  # without a running sandbox to point at is not enough to exercise a gate.
  printf '%s' "${WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX:-}"
}

# =========================================================================
# Gate A: independent security domain
# =========================================================================
gate_a_independent_security_domain() {
  local name="A: independent security domain"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate A requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate A requires an operator-provided live sandbox to inspect policy/profile isolation"
    return
  fi
  # A real run would: create a Waspflow-scoped sbx profile/state dir, then
  # diff `sbx policy inspect` and `sbx config` output against the user's
  # default profile to prove no preset/secret/kit/credential bleed-through,
  # then restart the daemon and re-diff to prove survival without merging.
  local waspflow_profile_dir="${WASPFLOW_FEDERATION_SBX_PROFILE_DIR:-}"
  if [[ -z "$waspflow_profile_dir" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_SBX_PROFILE_DIR not set — no independent Waspflow sbx profile/state mechanism to point at yet (Docker's documented local-profile story for embedded apps is unresolved per the runtime decision note, §1)"
    return
  fi
  if ! sbx --profile-dir "$waspflow_profile_dir" policy inspect >/dev/null 2>&1; then
    record "$name" FAIL "sbx policy inspect failed against the Waspflow-scoped profile dir; cannot prove domain isolation"
    return
  fi
  record "$name" FAIL "policy inspect succeeded but no default-profile diff, secret-bleed check, or daemon-restart survival test is implemented yet — treat as unproven, not passing"
}

# =========================================================================
# Gate B: locked-down effective policy
# =========================================================================
gate_b_locked_down_policy() {
  local name="B: locked-down effective policy"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate B requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate B requires a deny-all-initialized live sandbox to test allow/deny destinations against"
    return
  fi
  local effective_policy
  if ! effective_policy="$(sbx policy inspect "$handle" 2>&1)"; then
    record "$name" FAIL "sbx policy inspect \"$handle\" failed — cannot verify the effective policy at all"
    return
  fi
  if ! grep -qi 'deny-all\|deny_all' <<<"$effective_policy"; then
    record "$name" FAIL "effective policy for $handle does not report a deny-all base preset"
    return
  fi
  local denied=0 total=0
  for dest in 169.254.169.254 10.0.0.0 172.16.0.0 192.168.0.0 127.0.0.1 "$(host_gateway_guess)"; do
    total=$((total + 1))
    if sbx policy check network "$handle" "$dest" 2>&1 | grep -qi 'allow'; then
      : # reported allowed — counts against $denied by omission
    else
      denied=$((denied + 1))
    fi
  done
  if [[ "$denied" -ne "$total" ]]; then
    record "$name" FAIL "$((total - denied))/$total representative denied destinations were reported allowed by sbx policy check network"
    return
  fi
  record "$name" FAIL "policy check network denied representative destinations, but DNS-exfiltration/UDP/ICMP/unauthorized-TCP live probes and allowed-relay-destination checks are not implemented in this environment — treat as unproven, not passing"
}

host_gateway_guess() {
  ip route 2>/dev/null | awk '/^default/ { print $3; exit }' || printf '0.0.0.0'
}

# =========================================================================
# Gate C: credential-negative guest
# =========================================================================
gate_c_credential_negative_guest() {
  local name="C: credential-negative guest"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate C requires a hostile guest process inside a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate C additionally requires personal Docker Sandboxes to be configured on the same machine with realistic developer credentials first (per the note: testing only a clean machine is insufficient)"
    return
  fi
  local checks=(
    'test -S "$SSH_AUTH_SOCK" 2>/dev/null && echo SSH_SOCK_VISIBLE || echo ssh_socket_absent'
    'ssh-add -l 2>&1 | grep -qi identit && echo SSH_SIGN_POSSIBLE || echo ssh_sign_blocked'
    'cat ~/.docker/config.json 2>/dev/null | grep -qi auth && echo REGISTRY_CRED_READABLE || echo registry_cred_absent'
    'env | grep -Ei "ANTHROPIC_API_KEY|OPENAI_API_KEY|GITHUB_TOKEN|AWS_SECRET" && echo MODEL_OR_CLOUD_SECRET_PRESENT || echo no_model_or_cloud_secret'
  )
  local leaked=0
  for check in "${checks[@]}"; do
    local out
    out="$(sbx exec "$handle" -- sh -c "$check" 2>&1)" || true
    if grep -Eq 'SSH_SOCK_VISIBLE|SSH_SIGN_POSSIBLE|REGISTRY_CRED_READABLE|MODEL_OR_CLOUD_SECRET_PRESENT' <<<"$out"; then
      leaked=$((leaked + 1))
    fi
  done
  if [[ "$leaked" -gt 0 ]]; then
    record "$name" FAIL "$leaked/${#checks[@]} credential-negative guest checks found a leaked credential surface — see script output above"
    return
  fi
  record "$name" FAIL "no leaked credential surface found in this pass, but GitHub/cloud-CLI credential reads, registry push-as-provider, host credential-proxy reachability, and global-secret enumeration are not all covered — treat as unproven, not passing"
}

# =========================================================================
# Gate D: disposable filesystem boundary
# =========================================================================
gate_d_disposable_filesystem_boundary() {
  local name="D: disposable filesystem boundary"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate D requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate D requires a live sandbox with a known disposable scratch dir and a sibling job's scratch dir to attempt escape against"
    return
  fi
  local sibling_scratch="${WASPFLOW_FEDERATION_CONFORMANCE_SIBLING_SCRATCH:-}"
  if [[ -z "$sibling_scratch" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SIBLING_SCRATCH not set — cannot test adjacent-job visibility without a second job's scratch dir to probe"
    return
  fi
  local escape_checks=(
    "ls $sibling_scratch 2>&1 | grep -qv 'No such\|Permission denied' && echo SIBLING_VISIBLE || echo sibling_blocked"
    'ls / 2>&1 | grep -qi "home\|Users" && echo HOST_ROOT_VISIBLE || echo host_root_bounded'
    'ls /mnt /media /Volumes 2>&1 | grep -qv "No such\|Permission denied" && echo REMOVABLE_OR_SHARE_VISIBLE || echo removable_share_bounded'
  )
  local leaked=0
  for check in "${escape_checks[@]}"; do
    local out
    out="$(sbx exec "$handle" -- sh -c "$check" 2>&1)" || true
    if grep -Eq 'SIBLING_VISIBLE|HOST_ROOT_VISIBLE|REMOVABLE_OR_SHARE_VISIBLE' <<<"$out"; then
      leaked=$((leaked + 1))
    fi
  done
  if [[ "$leaked" -gt 0 ]]; then
    record "$name" FAIL "$leaked/${#escape_checks[@]} filesystem-boundary checks found visibility beyond the job's own scratch/VM filesystem"
    return
  fi
  record "$name" FAIL "no boundary violation found in this pass, but symlink/path-traversal escape from the guest and normal-repository visibility are not covered — treat as unproven, not passing"
}

# =========================================================================
# Gate E: no inbound exposure
# =========================================================================
gate_e_no_inbound_exposure() {
  local name="E: no inbound exposure"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate E requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate E requires a live sandbox to start a guest listener against and probe from the host/LAN"
    return
  fi
  if sbx exec "$handle" -- sh -c 'nohup nc -l -p 18081 >/dev/null 2>&1 &' >/dev/null 2>&1; then
    sleep 1
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/18081" 2>/dev/null; then
      record "$name" FAIL "guest listener on port 18081 was reachable from the host — inbound exposure detected"
      return
    fi
  fi
  record "$name" FAIL "no host-reachable guest listener found in this pass, but LAN reachability, restart-restores-mapping, and job-input port-publication-injection checks are not covered — treat as unproven, not passing"
}

# =========================================================================
# Gate F: enforceable resource limits
# =========================================================================
gate_f_enforceable_resource_limits() {
  local name="F: enforceable resource limits"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate F requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate F requires a live sandbox with declared CPU/memory/storage/process/deadline limits to attempt fork-bomb, memory-exhaustion, and disk/inode-fill bombs against"
    return
  fi
  record "$name" FAIL "gate F live bomb fixtures (fork bomb, memory exhaustion, disk/inode fill, unbounded output, deadline survival) are structurally present as functions below but were not exercised — a WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX was provided but this maker pass stops at declaring intent, not measured containment; treat as unproven"
}

gate_f_fork_bomb_check() {
  local handle=$1
  sbx exec "$handle" -- sh -c ':(){ :|:& };:' >/dev/null 2>&1 &
  local pid=$!
  sleep 5
  kill "$pid" 2>/dev/null || true
  sbx inspect "$handle" >/dev/null 2>&1
}

gate_f_memory_exhaustion_check() {
  local handle=$1
  timeout 10 sbx exec "$handle" -- sh -c 'python3 -c "b=bytearray(10**11)"' >/dev/null 2>&1
}

gate_f_disk_fill_check() {
  local handle=$1
  timeout 20 sbx exec "$handle" -- sh -c 'dd if=/dev/zero of=/tmp/fill bs=1M count=1000000' >/dev/null 2>&1
}

# =========================================================================
# Gate G: reliable teardown and orphan recovery
# =========================================================================
gate_g_reliable_teardown() {
  local name="G: reliable teardown and orphan recovery"
  if ! have_sbx; then
    record "$name" SKIP "sbx not installed — gate G requires a real sbx sandbox to execute"
    return
  fi
  local handle; handle="$(live_sandbox_handle)"
  if [[ -z "$handle" ]]; then
    record "$name" SKIP "WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX not set — gate G requires a live sandbox to destroy and independently re-list, plus a daemon restart to test orphan reconciliation"
    return
  fi
  if ! sbx destroy "$handle" >/dev/null 2>&1; then
    record "$name" FAIL "sbx destroy \"$handle\" reported failure"
    return
  fi
  if sbx list 2>&1 | grep -Fq "$handle"; then
    record "$name" FAIL "sandbox $handle still appears in sbx list after destroy — removal not confirmed independently of exit code"
    return
  fi
  record "$name" FAIL "destroy + independent re-list confirmed removal for this one sandbox, but scratch-data removal, token revocation, cleanup-receipt recording, and a startup orphan reaper are not implemented or exercised — treat as unproven, not passing"
}

# =========================================================================
# Gate H: version-pinned conformance testing (fully runnable today)
# =========================================================================
find_version_pin_mechanism() {
  # Look for whatever the hygiene/detection worker produces. Neither existed
  # in this repo as of this suite's authorship; check both documented
  # candidate locations before declaring absence.
  if [[ -x "$root/bin/federation-detect-sbx" ]]; then
    printf 'bin'
    return 0
  fi
  if [[ -f "$root/profiles/wf-federation-docker-v0.json" ]]; then
    printf 'profile'
    return 0
  fi
  return 1
}

gate_h_version_pinned_conformance() {
  local name="H: version-pinned conformance testing"
  local mechanism
  if ! mechanism="$(find_version_pin_mechanism)"; then
    record "$name" SKIP "version-pinning detection not yet implemented — neither bin/federation-detect-sbx nor profiles/wf-federation-docker-v0.json exists in this checkout"
    return
  fi

  local stub_dir; stub_dir="$(mktemp -d)"
  local orig_path="$PATH"
  cleanup_stub() { rm -rf "$stub_dir"; PATH="$orig_path"; }
  trap cleanup_stub RETURN

  # v0's pinned profile is a FLOOR only (no ceiling — the note warns against
  # inventing a fake upper bound with false confidence; see
  # profiles/wf-federation-docker-v0.json's max_version: null). A below-floor
  # stub is therefore the only version class v0 can honestly claim to reject
  # today; a high/bogus version is accepted BY DESIGN until a ceiling is
  # reviewed and pinned. Testing rejection of a high version here would
  # assert a requirement v0 doesn't implement yet.
  cat >"$stub_dir/sbx" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "version" || "$1" == "--version" ]]; then
  echo "sbx version 0.1.0-below-pinned-floor"
  exit 0
fi
echo "stub sbx: unsupported invocation: $*" >&2
exit 1
STUB
  chmod +x "$stub_dir/sbx"
  PATH="$stub_dir:$orig_path"

  if [[ "$mechanism" == "bin" ]]; then
    if "$root/bin/federation-detect-sbx" >/dev/null 2>&1; then
      record "$name" FAIL "bin/federation-detect-sbx accepted a stub sbx version (0.1.0) below the pinned floor instead of refusing it"
      return
    fi
    record "$name" PASS "bin/federation-detect-sbx correctly refused a stubbed below-floor sbx version (note: v0 pins a floor only — no ceiling is enforced yet, see profiles/wf-federation-docker-v0.json)"
    return
  fi

  # Profile mechanism: expect the profile to declare a supported version range
  # and a detection step that checks the live `sbx version` output against it.
  if ! command -v jq >/dev/null 2>&1; then
    record "$name" SKIP "jq not available to parse profiles/wf-federation-docker-v0.json"
    return
  fi
  local range
  range="$(jq -r '.sbx_version_range // .supported_sbx_versions // empty' "$root/profiles/wf-federation-docker-v0.json" 2>/dev/null)"
  if [[ -z "$range" ]]; then
    record "$name" FAIL "profiles/wf-federation-docker-v0.json exists but declares no sbx_version_range/supported_sbx_versions field to enforce"
    return
  fi
  record "$name" SKIP "profiles/wf-federation-docker-v0.json declares a version range ($range) but no detection binary was found to test enforcement against the stubbed bogus version — structural declaration only"
}

# =========================================================================
# Gate I: legal and product confirmation from Docker (documentation gate)
# =========================================================================
gate_i_legal_product_confirmation() {
  local name="I: legal and product confirmation from Docker"
  local matrix="$root/docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md"
  if [[ ! -f "$matrix" ]]; then
    record "$name" FAIL "docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md does not exist — gate I documentation is missing entirely"
    return
  fi
  if ! grep -qi 'OUTSTANDING\|unanswered\|unresolved' "$matrix"; then
    record "$name" FAIL "conformance matrix exists but does not acknowledge gate I's eight legal/product questions as outstanding/unanswered"
    return
  fi
  local required_terms=('redistribut' 'commercial use' 'OEM' 'automation API\|SDK' 'independent profile' 'SSH-agent' 'storage cap' 'compatibility and security-support')
  local missing=0
  for term in "${required_terms[@]}"; do
    grep -qi "$term" "$matrix" || missing=$((missing + 1))
  done
  if [[ "$missing" -gt 0 ]]; then
    record "$name" FAIL "conformance matrix is missing $missing/${#required_terms[@]} of the eight required Docker legal/product questions from the runtime decision note"
    return
  fi
  record "$name" PASS "conformance matrix exists and explicitly lists all eight Docker legal/product questions as outstanding/unanswered — no answers have been obtained, none are fabricated"
}

# =========================================================================
# run all gates
# =========================================================================
main() {
  gate_a_independent_security_domain
  gate_b_locked_down_policy
  gate_c_credential_negative_guest
  gate_d_disposable_filesystem_boundary
  gate_e_no_inbound_exposure
  gate_f_enforceable_resource_limits
  gate_g_reliable_teardown
  gate_h_version_pinned_conformance
  gate_i_legal_product_confirmation

  echo
  echo "=== Federation v0 Docker Sandboxes conformance summary ==="
  printf '%-45s %-6s %s\n' "GATE" "STATUS" "REASON"
  local i pass=0 fail=0 skip=0
  for i in "${!GATE_NAMES[@]}"; do
    printf '%-45s %-6s %s\n' "${GATE_NAMES[$i]}" "${GATE_STATUS[$i]}" "${GATE_REASON[$i]}"
    case "${GATE_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
    esac
  done
  echo
  echo "PASS=$pass FAIL=$fail SKIP=$skip (total ${#GATE_NAMES[@]})"
  echo "A SKIP is not a PASS. See docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md and"
  echo "scripts/federation-conformance-live-run.sh for the owner-run privileged/live pass."

  if [[ "$fail" -gt 0 ]]; then
    echo "RESULT: FAIL — a gate that could run did not pass"
    exit 1
  fi
  echo "RESULT: OK — no runnable gate failed (SKIPs require a real sbx + live sandbox follow-up)"
  exit 0
}

main "$@"
