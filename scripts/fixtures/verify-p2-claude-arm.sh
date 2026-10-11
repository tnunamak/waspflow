# An intentional in-place arm switch starts model evidence at its user marker.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-claude-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib" CLAUDE_PROJECTS_DIR="$fixture/projects"
  source "$root/lib/core.sh"; source "$root/lib/providers/claude.sh"
  mkdir -p "$CLAUDE_PROJECTS_DIR/p"
  file="$CLAUDE_PROJECTS_DIR/p/session.jsonl"
  lane_set arm provider claude session_id session arm_generation 1 model_requested claude-sonnet-5 runtime_settings_submission_nonce 'WASPFLOW_ESCALATION_TRANSITION:test'
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"WASPFLOW_ESCALATION_TRANSITION:test"}]}}' >"$file"
  printf '%s\n' '{"type":"user","message":{"content":"WASPFLOW_ESCALATION_TRANSITION:test task"}}' >>"$file"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5"}}' >>"$file"
  claude_refresh_runtime_settings arm
  [[ "$(lane_get arm runtime_settings_match_requested)" == true ]]
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5"}}' >>"$file"
  claude_refresh_runtime_settings arm
  [[ "$(lane_get arm runtime_settings_match_requested)" == false && "$(lane_get arm runtime_settings_error)" == multiple-models-observed ]]
  lane_set arm runtime_settings_submission_nonce absent-marker
  claude_refresh_runtime_settings arm
  [[ "$(lane_get arm runtime_refresh_state)" == unknown ]]
)
