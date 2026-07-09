#!/usr/bin/env bash
#
# grok.sh — waspflow provider adapter for the Grok Build CLI (`grok`).
#
# Mechanics (verified against Grok Build TUI + user-guide, 2026-07-09):
#   - Interactive (resumable) grok = drop -p/--single, pass a positional prompt,
#     mint --session-id <uuid>, and pass --always-approve for unattended lanes.
#   - Session dir at  ~/.grok/sessions/<url-encoded-cwd>/<session-id>/
#     (override base with $GROK_HOME; override sessions root with $GROK_SESSIONS_DIR).
#     Authoritative turn log: events.jsonl (turn_started / turn_ended).
#   - IDLE when the last turn_* event is turn_ended (MCP noise can follow).
#   - Headless one-shot:  grok -p "<msg>" --always-approve
#   - Headless revise:    grok -p "<msg>" --resume <session-id> --always-approve
#   - Effort: --reasoning-effort / --effort (none|minimal|low|medium|high|xhigh|max)
#
# Contract functions (called by core): grok_preflight, grok_spawn,
# grok_is_idle, grok_revise, grok_discover_session, grok_session_resumable.

# Prefer explicit sessions dir; else $GROK_HOME/sessions; else ~/.grok/sessions.
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
GROK_SESSIONS_DIR="${GROK_SESSIONS_DIR:-$GROK_HOME/sessions}"

# Preflight: grok on PATH. Grok reaches its model via OAuth cache or XAI_API_KEY;
# no mandatory local-proxy gate.
grok_preflight() {
  command -v grok >/dev/null 2>&1 || { err "grok not found on PATH"; return 1; }
  billing_preflight_provider grok || return 1
  return 0
}

# Session id is minted by us and passed via --session-id, so discovery is the
# recorded value (same pattern as Claude).
grok_discover_session() {
  local lane="$1"
  lane_get "$lane" session_id
}

# Resolve the events.jsonl path for a session id (newest match if duplicates).
_grok_events_file() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 1
  find "$GROK_SESSIONS_DIR" -mindepth 2 -maxdepth 3 -type f \
    -path "*/${session_id}/events.jsonl" -printf '%T@\t%p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -f2-
}

# Spawn an interactive, resumable grok into the lane's tmux window.
# Args: lane cwd model session_id transcript prompt [extra...]
grok_spawn() {
  local lane="$1" cwd="$2" model="$3" session_id="$4" transcript="$5" prompt="$6"
  shift 6
  local extra=("$@")

  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  local effort_args=() effort
  effort="$(lane_get "$lane" effort)"
  # Pass effort through; unsupported non-empty values hard-fail (no silent drop).
  case "$effort" in
    "" ) ;;
    none|minimal|low|medium|high|xhigh|max) effort_args=(--effort "$effort") ;;
    *)
      err "grok: unsupported effort '$effort' (use none|minimal|low|medium|high|xhigh|max)"
      return 1
      ;;
  esac

  # Interactive grok: positional prompt auto-starts the first turn. --always-approve
  # is the unattended equivalent of Claude's --dangerously-skip-permissions.
  # --session-id makes the resume handle known up front (must be a fresh UUID).
  local argv=(grok
    "${model_args[@]}"
    "${effort_args[@]}"
    --session-id "$session_id"
    --always-approve
    --cwd "$cwd"
    "${extra[@]}"
    "$prompt")

  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  tmux_ensure_session
  tmux new-window -d -t "$WASPFLOW_TMUX_SESSION" -n "$lane" -c "$cwd" "bash -lc${quoted:+ }$(printf '%q' "${quoted# }")"
  local target; target="$(tmux_window_target "$lane")"
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  # Best-effort: wait for the session dir / first turn to appear.
  _grok_verify_started "$lane" "$target"
  return 0
}

_grok_pane() { tmux capture-pane -p -t "$1" -S -60 2>/dev/null | strip_ansi; }

# Ensure events.jsonl appears (turn started). Best-effort; wait/idle is the real gate.
_grok_verify_started() {
  local lane="$1" target="$2" sid events i
  sid="$(grok_discover_session "$lane")"
  [[ -n "$sid" ]] || return 0
  for i in $(seq 1 20); do
    events="$(_grok_events_file "$sid" || true)"
    if [[ -n "$events" && -s "$events" ]]; then
      # Prefer seeing turn_started, but any events file means the session is live.
      if grep -q '"type":"turn_started"' "$events" 2>/dev/null \
         || grep -q '"type":"turn_ended"' "$events" 2>/dev/null \
         || grep -q 'turn_started\|phase_changed' "$events" 2>/dev/null; then
        return 0
      fi
      return 0
    fi
    sleep 1
  done
  warn "grok spawn: session events not visible yet for lane '$lane' (sid=$sid). Inspect: waspflow attach $lane"
  return 0
}

# Session is resumable once its events file exists with content.
# Args: lane
grok_session_resumable() {
  local lane="$1" session_id events
  session_id="$(grok_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  events="$(_grok_events_file "$session_id" || true)"
  [[ -n "$events" && -s "$events" ]]
}

# IDLE predicate: last turn_* event is turn_ended.
# Args: lane
grok_is_idle() {
  local lane="$1" session_id events last_turn
  session_id="$(grok_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  events="$(_grok_events_file "$session_id" || true)"
  [[ -n "$events" && -f "$events" ]] || return 1
  # Ignore MCP/lifecycle noise that can land after turn_ended.
  last_turn="$(jq -rc 'select(.type=="turn_started" or .type=="turn_ended") | .type' \
                "$events" 2>/dev/null | tail -1)"
  [[ "$last_turn" == "turn_ended" ]]
}

# turn_mark: count of COMPLETED turns (turn_ended events) in events.jsonl. Like
# claude/codex, advances ONLY when a turn finishes — not on the turn_started a
# revise triggers — so the wait barrier clears exactly when the revised turn ends.
grok_turn_mark() {
  local lane="$1" session_id events
  session_id="$(grok_discover_session "$lane")"
  [[ -n "$session_id" ]] || { echo 0; return 0; }
  events="$(_grok_events_file "$session_id" || true)"
  [[ -n "$events" && -f "$events" ]] || { echo 0; return 0; }
  jq -rc 'select(.type=="turn_ended") | 1' "$events" 2>/dev/null | wc -l
}

# Revise: re-enter the session and run one turn. Two paths:
#   - Live tmux window: steer in-pane via paste-buffer.
#   - Exited: headless  grok -p "<msg>" --resume <session-id> --always-approve
# Args: lane message out_file
grok_revise() {
  local lane="$1" message="$2" out_file="${3:-}"
  local session_id model cwd
  session_id="$(grok_discover_session "$lane")"
  [[ -n "$session_id" ]] || { err "no session_id recorded for lane '$lane'"; return 1; }
  model="$(lane_get "$lane" model)"
  cwd="$(lane_get "$lane" cwd)"

  billing_preflight_provider grok || return 1

  if tmux_window_exists "$lane"; then
    local target events before after attempt j
    target="$(tmux_window_target "$lane")"
    events="$(_grok_events_file "$session_id" || true)"
    before="$(wc -l <"$events" 2>/dev/null || echo 0)"
    tmux send-keys -t "$target" C-u
    sleep 0.3
    tmux_paste_text "$target" "$message"
    sleep 1
    for attempt in 1 2 3 4 5; do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 6); do
        [[ -z "$events" ]] && events="$(_grok_events_file "$session_id" || true)"
        after="$(wc -l <"$events" 2>/dev/null || echo 0)"
        # A new turn appends turn_started (and more); line count growing is enough.
        if [[ "$after" -gt "$before" ]]; then
          # Prefer an actual turn_started after our before-mark when possible.
          return 0
        fi
        sleep 1
      done
      warn "grok revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    warn "grok revise: message may not have submitted for lane '$lane' (events did not grow)"
    return 0
  fi

  # Headless resume after the pane exited. Run from the lane's cwd so project
  # discovery (AGENTS.md, skills, session group) resolves correctly.
  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  local effort_args=() effort
  effort="$(lane_get "$lane" effort)"
  case "$effort" in
    "" ) ;;
    none|minimal|low|medium|high|xhigh|max) effort_args=(--effort "$effort") ;;
    *)
      err "grok: unsupported effort '$effort' (use none|minimal|low|medium|high|xhigh|max)"
      return 1
      ;;
  esac
  local tmp; tmp="${out_file:-$(mktemp)}"
  local attempt rc=0
  for attempt in 1 2 3 4 5; do
    rc=0
    ( cd "${cwd:-$PWD}" && grok -p "$message" --resume "$session_id" \
        --always-approve "${model_args[@]}" "${effort_args[@]}" \
        --cwd "${cwd:-$PWD}" </dev/null ) >"$tmp" 2>&1 || rc=$?
    # Retry when the session file is not visible yet right after a kill.
    if grep -qiE "session not found|couldn't (find|load|start) session|No conversation" "$tmp" 2>/dev/null; then
      sleep $(( attempt * 2 ))
      continue
    fi
    break
  done
  [[ -n "$out_file" ]] || { cat "$tmp"; rm -f "$tmp"; }
  return "${rc:-0}"
}
