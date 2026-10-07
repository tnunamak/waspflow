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

)
