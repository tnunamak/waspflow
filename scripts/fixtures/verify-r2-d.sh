# r2-d: provider transcript, escalation, and Antigravity evidence hardening.
(
  r2d="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r2-d-XXXXXX")"
  trap 'rm -rf "$r2d"' EXIT
  export WASPFLOW_HOME="$r2d/state" WASPFLOW_LIB="$root/lib" CLAUDE_PROJECTS_DIR="$r2d/claude-projects"
  source "$root/lib/core.sh"
  source "$root/lib/providers/claude.sh"
  source "$root/lib/providers/grok.sh"
  source "$root/lib/providers/antigravity.sh"

  # A resumed child is live until its new turn reaches end_turn; its earlier
  # completed turn must not make the parent eligible for automatic reap.
  sid=11111111-2222-3333-4444-555555555555
  parent_dir="$CLAUDE_PROJECTS_DIR/project"
  mkdir -p "$parent_dir/$sid/subagents"
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$parent_dir/$sid.jsonl"
  child="$parent_dir/$sid/subagents/agent-live.jsonl"
  printf '%s\n' \
    '{"type":"assistant","message":{"stop_reason":"end_turn"}}' \
    '{"type":"user","message":{"content":"resume this task"}}' \
    '{"type":"assistant","message":{"stop_reason":null}}' >"$child"
  lane_set claude-r2d provider claude session_id "$sid" cwd "$r2d"
  if ! _claude_children_active claude-r2d "$sid"; then
    echo 'r2-d: resumed Claude child was treated as settled' >&2; exit 1
  fi
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >>"$child"
  if _claude_children_active claude-r2d "$sid"; then
    echo 'r2-d: completed Claude child stayed active' >&2; exit 1
  fi

  # A partial JSON append is uncertain, never the previous terminal event.
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' '{"type":"assistant"' >"$parent_dir/$sid.jsonl"
  if claude_is_idle claude-r2d; then
    echo 'r2-d: Claude accepted a malformed transcript tail' >&2; exit 1
  fi

  grok_events="$r2d/grok-events.jsonl"
  printf '%s\n' '{"type":"turn_ended"}' '{"type":"turn_started"' >"$grok_events"
  _grok_events_file() { printf '%s\n' "$grok_events"; }
  lane_set grok-r2d provider grok session_id grok-r2d cwd "$r2d"
  if grok_is_idle grok-r2d; then
    echo 'r2-d: Grok accepted a malformed transcript tail' >&2; exit 1
  fi

  # Historical events cannot confirm an escalation: only the exact prompt
  # appended after the pre-launch snapshot is valid evidence.
  printf '%s\n' '{"type":"turn_started","prompt":"old escalation"}' '{"type":"turn_ended"}' >"$grok_events"
  lane_set grok-escalation pending_transition '{"provisional_session":{"session_id":"grok-r2d","submission_event_before":2}}'
  if grok_confirm_escalation_submission grok-escalation 'current escalation'; then
    echo 'r2-d: Grok escalation accepted historical events' >&2; exit 1
  fi
  printf '%s\n' '{"type":"user","content":"current escalation"}' '{"type":"turn_started","prompt":"current escalation"}' >>"$grok_events"
  grok_confirm_escalation_submission grok-escalation 'current escalation' \
    || { echo 'r2-d: Grok rejected current escalation receipt' >&2; exit 1; }

  # A single allowed Antigravity raw flag must not inherit the post-increment's
  # nonzero status as the function return code.
  _antigravity_extra_args --sandbox \
    || { echo 'r2-d: Antigravity rejected --sandbox' >&2; exit 1; }
  [[ "${ANTIGRAVITY_EXTRA_ARGS[*]}" == --sandbox ]] \
    || { echo 'r2-d: Antigravity lost --sandbox' >&2; exit 1; }
  _antigravity_extra_args --project="$r2d/project" \
    || { echo 'r2-d: Antigravity rejected --project=value' >&2; exit 1; }

  # Connection diagnostics without a typed final result are not a deliverable.
  diagnostic_log="$r2d/agy-diagnostic.log"
  printf '%s\n' 'Created conversation 11111111-2222-3333-4444-555555555555' 'Connected to service' >"$diagnostic_log"
  lane_set agy-r2d provider antigravity report ''
  if _antigravity_output_has_deliverable agy-r2d "$diagnostic_log"; then
    echo 'r2-d: Antigravity accepted diagnostic-only output' >&2; exit 1
  fi
  printf '%s\n' '{"type":"result","text":"delivered"}' >>"$diagnostic_log"
  _antigravity_output_has_deliverable agy-r2d "$diagnostic_log" \
    || { echo 'r2-d: Antigravity rejected a typed final result' >&2; exit 1; }

)
