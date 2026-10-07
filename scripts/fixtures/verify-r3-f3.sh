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
)
