# Qwen configured models use the same evidence protocol as both consumers.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-qwen-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/state" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"; source "$root/lib/selection.sh"; source "$root/lib/providers/qwen.sh"
  mkdir -p "$fixture/.qwen"
  printf '%s\n' '{"modelProviders":{"openai":[{"id":"configured-model"}]}}' >"$fixture/.qwen/settings.json"
  definition="$(declare -f qwen_valid_models)"
  definition="${definition//\$HOME/\$fixture}"
  eval "$definition"
  fixture_evidence="$(qwen_valid_models)"
  [[ "$fixture_evidence" == $'source=local_cache\nconfigured-model' ]]
  qwen_valid_models() { printf '%s\n' "$fixture_evidence"; }
  validate_model qwen configured-model exec
  [[ "$MODEL_VALIDATION_STATE" == available && "$MODEL_VALIDATION_SOURCE" == local_cache ]]
  selection_observe_availability qwen configured-model default | jq -e '.state == "available" and .evidence_source == "local_cache"' >/dev/null
  qwen_valid_models() { printf 'source=invalid\nconfigured-model\n'; }
  selection_observe_availability qwen configured-model default | jq -e '.state == "unknown" and .evidence_source == "none"' >/dev/null
)
