#!/usr/bin/env bash
# Offline regressions for adversarial review findings #8 and #9 (Codex).

(
  fixture_home="$(mktemp -d "$scratch/waspflow-r2-c-XXXXXX")"
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
  _codex_discover_session_cached() { printf '%s\n' "$fixture_sid"; }

  fixture_sid='12345678-1234-1234-1234-123456789abc'
  rollout="$CODEX_SESSIONS_DIR/rollout-2026-10-07-$fixture_sid.jsonl"
  key_log="$fixture_home/keys"
  fixture_pane=''
  event_case=''
  reset_lane() {
    jq -cn --arg sid "$fixture_sid" --arg cwd "$fixture_home/cwd" \
      '{type:"session_meta",payload:{id:$sid,cwd:$cwd}}' >"$rollout"
    jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"old"}}' >>"$rollout"
    jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"old"}}' >>"$rollout"
    lane_set revise provider codex status live cwd "$fixture_home/cwd" session_id "$fixture_sid" rollout "$rollout"
    : >"$key_log"
  }
  tmux_paste_text() { printf 'paste\n' >>"$key_log"; }
  tmux() {
    case "$1" in
      capture-pane) printf '%s\n' "$fixture_pane" ;;
      display-message) return 0 ;;
      send-keys)
        printf 'key:%s\n' "${!#}" >>"$key_log"
        if [[ "${!#}" == Enter ]]; then
          case "$event_case" in
            other-message)
              jq -cn '{type:"event_msg",payload:{type:"user_message",message:"OTHER",turn_id:"U"}}' >>"$rollout"
              jq -cn '{type:"event_msg",payload:{type:"task_started",turn_id:"U"}}' >>"$rollout"
              jq -cn '{type:"event_msg",payload:{type:"task_complete",turn_id:"U"}}' >>"$rollout"
              ;;
            message-seen)
              jq -cn --arg message 'revise message' '{type:"event_msg",payload:{type:"user_message",message:$message,turn_id:"U"}}' >>"$rollout"
              ;;
          esac
        fi
        ;;
    esac
  }
  export WASPFLOW_CODEX_REVISE_ATTEMPTS=2 WASPFLOW_CODEX_REVISE_POLLS=1

  # #8: another user's complete turn after our rollout boundary cannot confirm
  # this revise. The pre-fix fallback accepted its task_started event.
  reset_lane; fixture_pane='› Ask Codex to do anything'; event_case=other-message
  if codex_revise revise 'revise message' >/dev/null 2>&1; then
    echo 'r2-c #8: unrelated user_message confirmed this revise' >&2
    exit 1
  fi
  [[ "$(lane_get revise revise_submission_state)" == unconfirmed-no-task-started ]]

)
