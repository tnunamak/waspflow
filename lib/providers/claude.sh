#!/usr/bin/env bash
#
# claude.sh — waspflow provider adapter for Claude Code.
#
# Mechanics verified empirically against an interactive `claude` session and the
# 2026-06-15 live spike:
#   - Interactive (resumable) claude = drop --print AND --no-session-persistence,
#     add --session-id <uuid> (the addressable resume handle) and --name <lane>.
#     (--session-name does NOT exist; -n/--name is cosmetic.)
#   - Transcript at  ~/.claude/projects/<project-slug>/<session-id>.jsonl
#   - IDLE when the last `assistant` event has stop_reason == "end_turn"
#     (NOT the genuinely-last line — mid-turn it's tool_use + user tool-results).
#   - Revise after the pane exits:  claude --resume <session-id> --print "<msg>"
#
# Contract functions (called by core): claude_preflight, claude_spawn,
# claude_is_idle, claude_revise, claude_discover_session.

CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# Preflight: claude on PATH. Claude reaches its model directly by default, so
# there's no mandatory local-proxy gate like Codex's. NOTE: on some setups
# `claude` is itself wrapped to route through a local proxy; such a wrapper owns
# its own health and is transparent to us, so we do not gate on it here.
claude_preflight() {
  command -v claude >/dev/null 2>&1 || { err "claude not found on PATH"; return 1; }
  billing_preflight_provider claude || return 1
  return 0
}

# The session id IS minted by us and passed via --session-id, so discovery is
# trivial: it's whatever we recorded in lane state at spawn.
claude_discover_session() {
  local lane="$1"
  lane_get "$lane" session_id
}

# Spawn an interactive, resumable claude into the lane's tmux window.
# Globals expected from the caller (spawn verb): lane, cwd, model, prompt,
# session_id, transcript, extra_args (array).
# Args: none (reads the spawn_* locals exported by the caller).
claude_spawn() {
  local lane="$1" cwd="$2" model="$3" session_id="$4" transcript="$5" prompt="$6"
  shift 6
  local extra=("$@")

  local model_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")
  local effort_args=() effort
  effort="$(lane_get "$lane" effort)"
  [[ -n "$effort" ]] && effort_args=(--effort "$effort")

  # Build the command run INSIDE the tmux window. We pass the prompt as a
  # positional arg (interactive claude reads the PTY, not piped stdin) and do
  # NOT redirect output (claude owns the PTY; tmux pipe-pane captures the
  # transcript). --dangerously-skip-permissions because the lane is unattended.
  #
  # We assemble an argv array and quote it for the tmux shell.
  local argv=(claude
    "${model_args[@]}"
    "${effort_args[@]}"
    --session-id "$session_id"
    --name "$lane"
    --dangerously-skip-permissions
    "${extra[@]}"
    "$prompt")

  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  tmux_ensure_session
  tmux new-window -d -t "$WASPFLOW_TMUX_SESSION" -n "$lane" -c "$cwd" "bash -lc${quoted:+ }$(printf '%q' "${quoted# }")"
  local target; target="$(tmux_window_target "$lane")"
  # Capture a live transcript via pipe-pane (parity with codex).
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  # Clear Claude's folder-trust gate if it appears. --dangerously-skip-permissions
  # governs TOOL permissions, NOT the "Is this a project you trust?" folder gate,
  # which still blocks startup in an unfamiliar dir. The task prompt was passed as
  # a positional arg, so it auto-runs once trust is cleared — no separate submit.
  _claude_clear_trust_prompt "$target"
  # Verify the session actually started (JSONL appears) — the trust prompt may
  # arrive a beat late; re-answer once if needed.
  _claude_verify_started "$lane" "$target"
  return 0
}

# Pane snapshot, de-escaped.
_claude_pane() { tmux capture-pane -p -t "$1" -S -60 2>/dev/null | strip_ansi; }

# Answer Claude's folder-trust prompt ("Yes, I trust this folder" = option 1)
# if/when it appears. No-op for already-trusted dirs.
_claude_clear_trust_prompt() {
  local target="$1" i pane
  for i in $(seq 1 20); do
    pane="$(_claude_pane "$target")"
    if grep -qiE "trust this folder|Is this a project you" <<<"$pane"; then
      tmux send-keys -t "$target" "1"
      sleep 1
      tmux send-keys -t "$target" Enter
      local j
      for j in $(seq 1 10); do
        grep -qiE "trust this folder|Is this a project you" <<<"$(_claude_pane "$target")" || return 0
        sleep 1
      done
      return 0
    fi
    # Composer already up (no trust gate) → nothing to clear.
    grep -qiE "bypass permissions|/effort|Welcome back" <<<"$pane" && return 0
    sleep 1
  done
  return 0
}

# Ensure the session JSONL appears (the turn started). If not within the window,
# re-answer a possibly-late trust prompt once. Best-effort; wait/idle is the real
# gate the caller uses next.
_claude_verify_started() {
  local lane="$1" target="$2" sid jsonl i
  sid="$(claude_discover_session "$lane")"
  [[ -n "$sid" ]] || return 0
  for i in $(seq 1 15); do
    jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)"
    [[ -n "$jsonl" ]] && return 0
    if grep -qiE "trust this folder|Is this a project you" <<<"$(_claude_pane "$target")"; then
      tmux send-keys -t "$target" "1"; sleep 1; tmux send-keys -t "$target" Enter
    fi
    sleep 1
  done
  return 0
}

# Is the session resumable yet? After a window is killed, the JSONL may not be
# flushed; `claude --resume` then says "No conversation found". True once the
# transcript exists with real content. Args: lane
claude_session_resumable() {
  local lane="$1" session_id jsonl
  session_id="$(claude_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" 2>/dev/null | head -1)"
  [[ -n "$jsonl" && -s "$jsonl" ]]
}

# IDLE predicate: last assistant event's stop_reason == end_turn.
# Args: lane
claude_is_idle() {
  local lane="$1" session_id jsonl last_reason
  session_id="$(claude_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" \
            -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
  [[ -n "$jsonl" && -f "$jsonl" ]] || return 1
  last_reason="$(jq -rc 'select(.type=="assistant") | .message.stop_reason // empty' "$jsonl" 2>/dev/null | tail -1)"
  [[ "$last_reason" == "end_turn" ]]
}

# Revise: re-enter the session and run one turn. Two paths:
#   - If the lane's tmux window is still live, steer in-pane via paste-buffer.
#   - Otherwise resume headlessly:  claude --resume <session-id> --print "<msg>"
# Writes the headless reply to $out_file when resuming; for in-pane steering the
# reply lands in the pane transcript. Args: lane message out_file
claude_revise() {
  local lane="$1" message="$2" out_file="${3:-}"
  local session_id model cwd
  session_id="$(claude_discover_session "$lane")"
  [[ -n "$session_id" ]] || { err "no session_id recorded for lane '$lane'"; return 1; }
  model="$(lane_get "$lane" model)"
  cwd="$(lane_get "$lane" cwd)"   # claude --resume is cwd-scoped — MUST resume from here

  if tmux_window_exists "$lane"; then
    # Live in-pane steer. The Enter can race the composer (esp. through hook
    # output), so VERIFY the turn started by watching the JSONL grow, re-sending
    # Enter if it didn't take. Text is pasted literally; send-keys can mangle
    # long prompts or special characters.
    local target jsonl before after attempt j
    target="$(tmux_window_target "$lane")"
    jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" 2>/dev/null | head -1)"
    before="$(wc -l <"$jsonl" 2>/dev/null || echo 0)"
    tmux send-keys -t "$target" C-u
    sleep 0.3
    tmux_paste_text "$target" "$message"
    sleep 1
    for attempt in 1 2 3 4 5; do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 6); do
        [[ -z "$jsonl" ]] && jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" 2>/dev/null | head -1)"
        after="$(wc -l <"$jsonl" 2>/dev/null || echo 0)"
        [[ "$after" -gt "$before" ]] && return 0
        sleep 1
      done
      warn "claude revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    warn "claude revise: message may not have submitted for lane '$lane' (transcript did not grow)"
    return 0
  fi

  billing_preflight_provider claude || return 1

  # Headless resume after the pane exited. Redirect stdin from /dev/null:
  # `claude --print` reads stdin even when the prompt is a positional arg, and
  # blocks ~3s waiting for it otherwise. The message is the positional prompt.
  #
  # A session killed moments ago may not be registered for --resume yet even
  # though its JSONL is on disk ("No conversation found"). Retry with backoff —
  # the file-existence check alone is insufficient; the real signal is the
  # resume succeeding. Args already validated above.
  local model_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")
  local tmp; tmp="${out_file:-$(mktemp)}"
  local attempt rc
  for attempt in 1 2 3 4 5; do
    rc=0
    # Resume from the lane's cwd: claude --resume is scoped to the project dir.
    ( cd "${cwd:-$PWD}" && claude --resume "$session_id" --print "${model_args[@]}" \
        --dangerously-skip-permissions "$message" </dev/null ) >"$tmp" 2>&1 || rc=$?
    if grep -q "No conversation found" "$tmp" 2>/dev/null; then
      sleep $(( attempt * 2 ))
      continue
    fi
    break
  done
  [[ -n "$out_file" ]] || { cat "$tmp"; rm -f "$tmp"; }
  return "${rc:-0}"
}
