# TERM-resistant verification must still finish with a timeout receipt.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-deadline-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  lane_set deadline cwd "$fixture" provider fake
  state="$(_artifacts_run_command deadline "$fixture/verify" resistant "trap '' TERM; while :; do :; done" "$fixture" 0.1)"
  [[ "$state" == timeout ]]
  jq -e '.state == "timeout" and .exit_code == 137' "$fixture/verify-result.json" >/dev/null
)
