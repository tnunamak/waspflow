#!/usr/bin/env bash
# Offline provider regressions for campaign slice r3-f3.

(
  fixture="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r3-f3-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" CODEX_SESSIONS_DIR="$fixture/sessions"
  source "$root/lib/core.sh"
  source "$root/lib/providers/codex.sh"
  mkdir -p "$fixture/cwd" "$CODEX_SESSIONS_DIR"

  # B5: after a new user turn is queued, a delayed completion for the preceding
  # turn must not make the lane idle or advance wait's completion barrier.
  sid=11111111-2222-3333-4444-555555555555
  rollout="$CODEX_SESSIONS_DIR/rollout-r3-f3-$sid.jsonl"
  printf '%s\n' \
    '{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}' \
    '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"old"}}' \
    '{"type":"event_msg","payload":{"type":"user_message","turn_id":"new","message":"next"}}' \
    '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"old"}}' >"$rollout"
  lane_set b5 provider codex status live cwd "$fixture/cwd" session_id "$sid" rollout "$rollout"
  if codex_is_idle b5; then
    echo 'r3-f3 B5: late old Codex completion made a queued turn idle' >&2; exit 1
  fi
  [[ "$(codex_turn_mark b5)" == 1 ]] \
    || { echo 'r3-f3 B5: late old Codex completion advanced the turn mark' >&2; exit 1; }

  # B8: Codex can serialize task_started before its matching user event. That
  # ordering is still a confirmed submission when both records name one turn.
  printf '%s\n' \
    '{"type":"event_msg","payload":{"type":"task_started","turn_id":"same-id"}}' \
    '{"type":"event_msg","payload":{"type":"user_message","turn_id":"same-id","message":"ordered"}}' >"$rollout"
  [[ "$(_codex_revise_submission_state "$rollout" ordered 0)" == confirmed ]] \
    || { echo 'r3-f3 B8: same-ID start-before-user receipt was not confirmed' >&2; exit 1; }

  # B6: another user's turn_started cannot confirm this prompt merely because
  # the requested prompt appeared earlier in the event suffix.
  source "$root/lib/providers/grok.sh"
  grok_events="$fixture/grok-events.jsonl"
  printf '%s\n' \
    '{"type":"user","content":"requested"}' \
    '{"type":"user","content":"other"}' \
    '{"type":"turn_started","prompt":"other"}' >"$grok_events"
  if _grok_submission_receipt_present "$grok_events" requested 0; then
    echo 'r3-f3 B6: Grok accepted another user turn as the requested prompt' >&2; exit 1
  fi
  printf '%s\n' '{"type":"turn_started","prompt":"requested"}' >>"$grok_events"
  _grok_submission_receipt_present "$grok_events" requested 0 \
    || { echo 'r3-f3 B6: Grok rejected prompt evidence on its turn start' >&2; exit 1; }

  # B7: generic assistant commentary is progress, not provider-terminal proof.
  source "$root/lib/providers/antigravity.sh"
  agy_log="$fixture/agy.log"
  printf '%s\n' \
    '{"type":"assistant","text":"I will investigate"}' \
    '{"type":"tool","name":"search"}' >"$agy_log"
  lane_set b7 provider antigravity report ''
  if _antigravity_output_has_deliverable b7 "$agy_log"; then
    echo 'r3-f3 B7: Antigravity accepted non-terminal assistant commentary' >&2; exit 1
  fi
  printf '%s\n' '{"type":"final","text":"completed"}' >>"$agy_log"
  _antigravity_output_has_deliverable b7 "$agy_log" \
    || { echo 'r3-f3 B7: Antigravity rejected a typed terminal result' >&2; exit 1; }

  # B11: terminal classification consumes one validated snapshot. Reopening a
  # live JSONL after validation can let a malformed concurrent append reuse an
  # older terminal event.
  source "$root/lib/providers/claude.sh"
  claude_log="$fixture/claude.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$claude_log"
  real_jq="$(command -v jq)"; jq_calls="$fixture/jq-calls"
  : >"$jq_calls"
  jq() {
    local arg
    for arg in "$@"; do
      [[ "$arg" == "$claude_log" || "$arg" == "${grok_idle_events:-}" ]] && printf x >>"$jq_calls"
    done
    "$real_jq" "$@"
  }
  _claude_transcript_settled "$claude_log" \
    || { echo 'r3-f3 B11: Claude rejected a valid terminal snapshot' >&2; exit 1; }
  [[ "$(wc -c <"$jq_calls")" == 1 ]] \
    || { echo 'r3-f3 B11: Claude reopened its transcript after validation' >&2; exit 1; }
  grok_idle_events="$fixture/grok-idle-events.jsonl"
  printf '%s\n' '{"type":"turn_ended"}' >"$grok_idle_events"
  _grok_events_file() { printf '%s\n' "$grok_idle_events"; }
  lane_set b11 provider grok session_id b11 cwd "$fixture/cwd"
  : >"$jq_calls"
  grok_is_idle b11 || { echo 'r3-f3 B11: Grok rejected a valid terminal snapshot' >&2; exit 1; }
  [[ "$(wc -c <"$jq_calls")" == 1 ]] \
    || { echo 'r3-f3 B11: Grok reopened its events after validation' >&2; exit 1; }

  # MEDIUM-1: known provider-active work suppresses the generic quiet-pane
  # stall heuristic, but wait still times out normally and never suggests an
  # interactive answer for that healthy background shell.
  active_socket="wf-r3-f3-$$"; active_session="r3-f3-active"
  tmux -L "$active_socket" new-session -d -s "$active_session" -n active \
    "printf '1 shell still running\\n'; exec sleep 10"
  trap 'tmux -L "$active_socket" kill-session -t "$active_session" 2>/dev/null || true; rm -rf "$fixture"' EXIT
  active_window="$(tmux -L "$active_socket" display-message -p -t "$active_session:active" '#{window_id}')"
  active_pid="$(tmux -L "$active_socket" display-message -p -t "$active_window" '#{pane_pid}')"
  active_uuid=11111111-2222-3333-4444-555555555556
  active_home="$(cd "$WASPFLOW_HOME" && pwd -P)"
  tmux -L "$active_socket" set-option -w -t "$active_window" @waspflow_home "$active_home"
  tmux -L "$active_socket" set-option -w -t "$active_window" @waspflow_lane_uuid "$active_uuid"
  lane_set active provider claude status live session_id active-session cwd "$fixture/cwd" \
    lane_uuid "$active_uuid" tmux_session "$active_session" tmux_window "$active_window" tmux_pane_pid "$active_pid"
  mkdir -p "$fixture/projects/project"
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' \
    >"$fixture/projects/project/active-session.jsonl"
  : >"$(lane_transcript active)"
  if CLAUDE_PROJECTS_DIR="$fixture/projects" WASPFLOW_TMUX_SOCKET="$active_socket" \
      WASPFLOW_TMUX_SESSION="$active_session" WASPFLOW_STALL_SECONDS=1 \
      "$root/bin/waspflow" wait active --timeout 3 --interval 1 >"$fixture/active-wait.out" 2>&1; then
    echo 'r3-f3 MEDIUM-1: wait unexpectedly succeeded while background shell ran' >&2; exit 1
  else
    active_wait_rc=$?
  fi
  [[ "$active_wait_rc" == 1 ]] \
    || { echo "r3-f3 MEDIUM-1: active shell returned rc $active_wait_rc, expected timeout" >&2; exit 1; }
  [[ "$(lane_get active wait_state)" == active ]] \
    || { echo 'r3-f3 MEDIUM-1: wait did not record provider-active evidence' >&2; exit 1; }
  ! grep -q 'STALLED\|answer a prompt' "$fixture/active-wait.out" \
    || { echo 'r3-f3 MEDIUM-1: active shell received stalled/prompt advice' >&2; exit 1; }
  tmux -L "$active_socket" kill-session -t "$active_session" 2>/dev/null || true
)
