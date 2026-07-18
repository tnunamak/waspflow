#!/usr/bin/env bash
# Deterministic adversarial conformance tests for the host-side runner boundary.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$root/bin/waspflow-federation-runner"
injector="$root/bin/waspflow-federation-injector"
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
cas="$scratch/cas"; mkdir -p "$cas" "$scratch/runtime"
export WASPFLOW_FEDERATION_CAS="$cas" WASPFLOW_FEDERATION_RUNTIME_DIR="$scratch/runtime"
put() { local input="$1" digest; digest="$(sha256sum "$input" | awk '{print $1}')"; cp "$input" "$cas/$digest"; printf '%s\n' "$digest"; }
make_task() {
  local source="$1" prompt="$2" profile task_json
  profile="$($runner profile | jq -r .digest)"
  task_json="$(jq -cn --arg profile_digest "$profile" --arg source "$source" --arg prompt "$prompt" '{schema_version:1,profile:"wf-federation-linux-v0",profile_digest:$profile_digest,source_digest:$source,prompt_digest:$prompt,gateway_ref:"owner-gateway",route:"coding",network:"on",oracle_ref:null,result_verdict:null,settlement:null,limits:{wall_seconds:60}}')"
  jq -cS . <<<"$task_json" >"$scratch/task.json"
  put "$scratch/task.json"
}
printf 'source\n' >"$scratch/source"; source_digest="$(put "$scratch/source")"
printf 'prompt\n' >"$scratch/prompt"; prompt_digest="$(put "$scratch/prompt")"
task_digest="$(make_task "$source_digest" "$prompt_digest")"
$runner preflight "$task_digest" >/dev/null

# M3: a claim cannot select a different gateway/route, and no owner key appears
# in the guest-facing plan.
printf 'delegated-key-that-must-never-enter-a-guest\n' >"$scratch/key"; chmod 600 "$scratch/key"
jq -cn --arg task "$task_digest" --arg key "$scratch/key" '{claim_id:"claim-a",task_digest:$task,gateway_ref:"owner-gateway",route:"coding",key_file:$key,expires_at:"2099-01-01T00:00:00Z"}' >"$scratch/claim.json"
plan="$($runner launch-plan "$task_digest" "$scratch/claim.json")"
jq -e '.guest_selectors == false and (. | tostring | contains("delegated-key") | not)' <<<"$plan" >/dev/null
jq '.gateway_ref="other"' "$scratch/claim.json" >"$scratch/bad-claim.json"
if $runner launch-plan "$task_digest" "$scratch/bad-claim.json" >/dev/null 2>&1; then echo 'gateway confusion was accepted' >&2; exit 1; fi

# Unsafe fields and malformed ingress stop at the host boundary.
jq '.privileged=true' "$scratch/task.json" >"$scratch/evil-task.json"; evil_digest="$(put "$scratch/evil-task.json")"
if $runner preflight "$evil_digest" >/dev/null 2>&1; then echo 'privileged task field was accepted' >&2; exit 1; fi
mkdir "$scratch/archive"; printf nope >"$scratch/archive/file"; tar -C "$scratch/archive" -cf "$scratch/escape.tar" --transform='s,^,../,' file
escape_digest="$(put "$scratch/escape.tar")"
if $runner inspect-artifact "$escape_digest" >/dev/null 2>&1; then echo 'path traversal archive was accepted' >&2; exit 1; fi

# The injector requires a private owner key and pinned HTTPS endpoint.
jq -cn --arg key "$scratch/key" --arg socket "$scratch/injector.sock" '{claim_id:"claim-a",task_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",gateway_ref:"owner-gateway",route:"coding",key_file:$key,expires_at:"2099-01-01T00:00:00Z",socket:$socket,max_requests:2,max_body_bytes:1024,max_concurrent:1}' >"$scratch/inject.json"
jq -n '{gateways:{"owner-gateway":{url:"https://gateway.example.invalid",routes:{coding:{model:"route-pinned"}}}}}' >"$scratch/registry.json"
$injector check-config "$scratch/inject.json" "$scratch/registry.json" | jq -e '.status == "valid" and .key_exposed_to_guest == false' >/dev/null
chmod 644 "$scratch/key"
if $injector check-config "$scratch/inject.json" "$scratch/registry.json" >/dev/null 2>&1; then echo 'world-readable owner key was accepted' >&2; exit 1; fi
chmod 600 "$scratch/key"

# Missing Firecracker assets cannot degrade to Docker or namespaces.
set +e
backend="$($runner execute "$task_digest" "$scratch/claim.json" 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 && "$backend" == *'refusing namespace/container fallback'* ]] || { printf '%s\n' "$backend" >&2; echo 'backend fail-closed contract missing' >&2; exit 1; }
$runner compatibility-plan claude | jq -e '.harness == "claude" and .required_env.ANTHROPIC_API_KEY == "wf-vm-launch-bound-sentinel"' >/dev/null
$runner compatibility-plan codex | jq -e '.harness == "codex" and .required_env.OPENAI_API_KEY == "wf-vm-launch-bound-sentinel"' >/dev/null
echo 'federation runner conformance: ok'
