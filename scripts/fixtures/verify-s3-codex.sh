#!/usr/bin/env bash
# Offline Codex adapter regressions for hardening slice S3.

(
  fixture_home="$(mktemp -d "$scratch/waspflow-s3-codex-XXXXXX")"
  trap 'rm -rf "$fixture_home"' EXIT
  export WASPFLOW_HOME="$fixture_home/home" CODEX_SESSIONS_DIR="$fixture_home/sessions"
  source "$root/lib/core.sh"
  source "$root/lib/providers/codex.sh"
  mkdir -p "$CODEX_SESSIONS_DIR" "$fixture_home/cwd"
  sleep() { :; }
  billing_preflight_provider() { return 0; }
  codex_refresh_runtime_settings() { :; }
  tmux_window_exists() { return 0; }
  tmux_window_target() { printf 'fixture:0\n'; }
  tmux_paste_text() { :; }

  sid='12345678-1234-1234-1234-123456789abc'
  rollout="$CODEX_SESSIONS_DIR/rollout-2026-10-07-$sid.jsonl"
  reset_rollout() {
    jq -cn --arg sid "$sid" --arg cwd "$fixture_home/cwd" '{type:"session_meta",payload:{id:$sid,cwd:$cwd}}' >"$rollout"
    jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"old"}}' >>"$rollout"
    jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"old"}}' >>"$rollout"
    lane_set revise provider codex status live cwd "$fixture_home/cwd" session_id "$sid" rollout "$rollout"
  }
  event_case=none
  tmux() {
    [[ "${!#}" == Enter ]] || return 0
    case "$event_case" in
      unrelated)
        jq -cn --arg message 'revise message' '{type:"event_msg",payload:{type:"user_message",message:$message,turn_id:"message-turn"}}' >>"$rollout"
        jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"unrelated-turn"}}' >>"$rollout"
        ;;
      matching)
        jq -cn --arg message 'revise message' '{type:"event_msg",payload:{type:"user_message",message:$message,turn_id:"message-turn"}}' >>"$rollout"
        jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"message-turn"}}' >>"$rollout"
        ;;
    esac
  }
  export WASPFLOW_CODEX_REVISE_ATTEMPTS=1 WASPFLOW_CODEX_REVISE_POLLS=1
  reset_rollout; event_case=unrelated
  if codex_revise revise 'revise message' >/dev/null 2>&1; then
    echo 'S3 revise: unrelated started turn confirmed the message' >&2; exit 1
  fi
  [[ "$(lane_get revise revise_submission_state)" == unconfirmed-no-task-started ]]
  reset_rollout; event_case=matching
  codex_revise revise 'revise message' >/dev/null
  [[ "$(lane_get revise revise_submission_state)" == confirmed-task-started ]]

  # Current-turn order is authoritative; old completions and pending tools do
  # not make a new turn idle, and a partial/aborted event never succeeds.
  lane_set idle provider codex status live cwd "$fixture_home/cwd" session_id "$sid" rollout "$rollout"
  reset_rollout
  jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"new"}}' >>"$rollout"
  jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"new"}}' >>"$rollout"
  jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"old"}}' >>"$rollout"
  codex_is_idle idle
  jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"newer"}}' >>"$rollout"
  jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"old"}}' >>"$rollout"
  ! codex_is_idle idle
  jq -cn '{type:"event_msg",payload:{type:"exec_command_begin",call_id:"call"}}' >>"$rollout"
  ! codex_is_idle idle
  jq -cn '{type:"event_msg",payload:{type:"exec_command_end",call_id:"call"}}' >>"$rollout"
  jq -cn '{type:"event_msg",payload:{type:"turn_aborted",turn_id:"newer"}}' >>"$rollout"
  jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"newer"}}' >>"$rollout"
  ! codex_is_idle idle
  printf '%s' '{"type":"event_msg"' >>"$rollout"
  ! codex_is_idle idle

  # A bounded discovery cannot hang a launch. A timed-out live query reports
  # the cache state, never a fabricated available model.
  mkdir -p "$fixture_home/bin"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$fixture_home/bin/codex"
  chmod +x "$fixture_home/bin/codex"
  PATH="$fixture_home/bin:$PATH" WASPFLOW_CODEX_MODEL_DISCOVERY_TIMEOUT_SECONDS=1 \
    CODEX_MODELS_CACHE="$fixture_home/no-cache" codex_valid_models | grep -qx 'source=none'

  # A zero exit code alone is not a completed headless turn. The adapter keeps
  # the provider's argv narrow and rejects empty or explicit denial output.
  tmux_window_exists() { return 1; }
  codex_load_process_mcp_policy() { MCP_ARGV=(); }
  output_case=empty
  tmux_run_owned_lane_command() {
    local arg output="" next=false
    for arg in "$@"; do
      if [[ "$next" == true ]]; then output="$arg"; break; fi
      [[ "$arg" == -o ]] && next=true
    done
    case "$output_case" in
      denied) printf 'request denied\n' >"$output" ;;
      answer) printf 'completed turn\n' >"$output" ;;
      empty) : >"$output" ;;
    esac
  }
  lane_set headless provider codex status live cwd "$fixture_home/cwd" session_id "$sid" rollout "$rollout"
  for output_case in empty denied; do
    if codex_revise headless 'headless message' >/dev/null 2>&1; then
      echo "S3 headless: $output_case output was accepted" >&2; exit 1
    fi
  done
  output_case=answer
  codex_revise headless 'headless message' >/dev/null
)
