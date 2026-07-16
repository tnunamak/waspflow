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
# The Grok CLI keeps a live, auth-scoped model cache here (like Codex's).
GROK_MODELS_CACHE="${GROK_MODELS_CACHE:-$GROK_HOME/models_cache.json}"

# Valid model ids for the current Grok auth, one per line, from the CLI's own live
# cache. Echoes nothing (rc 1) when absent — callers fail OPEN (see codex_valid_models).
grok_valid_models() {
  [[ -r "$GROK_MODELS_CACHE" ]] || { printf 'source=none\n'; return 0; }
  local out
  out="$(jq -r '.models[].info.id // .models[].id // empty' "$GROK_MODELS_CACHE" 2>/dev/null)"
  [[ -n "$out" ]] || { printf 'source=none\n'; return 0; }
  printf 'source=local_cache\n%s\n' "$out"
}

# Grok has no supported strict/empty MCP launch contract. `auto` is honest
# inheritance with a durable warning; explicit `none` fails before launch.
grok_mcp_policy() {
  case "$1" in
    inherit) printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}' ;;
    auto) printf '%s\n' '{"resolved":"inherit","warning":"Grok MCP auto resolves to inherit: this Grok CLI has no supported MCP-minimal mode.","argv":[],"env":{}}' ;;
    none)
      err "grok: --mcp none is unsupported; refusing to launch with an unverified MCP boundary"
      return 1
      ;;
    *) return 1 ;;
  esac
}

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
  mcp_policy_load_lane "$lane"
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

  local target
  target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc${quoted:+ }$(printf '%q' "${quoted# }")")" \
    || return 1
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
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- \
      grok -p "$message" --resume "$session_id" \
      --always-approve "${model_args[@]}" "${effort_args[@]}" \
      --cwd "${cwd:-$PWD}" </dev/null >"$tmp" 2>&1 || rc=$?
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

# Args: lane escalation_prompt [fresh].  This mirrors Grok's supported
# interactive resume syntax and leaves ownership provisional for the transition
# state machine to adopt only after the turn start is observable.
grok_resume_with_arm() {
  local lane="$1" prompt="$2" fresh="${3:-false}" transition arm model effort cwd sid target ownership quoted="" a
  transition="$(lane_get "$lane" pending_transition)"
  arm="$(jq -c '.to_arm // {}' <<<"$transition" 2>/dev/null)"
  model="$(jq -r '.model // ""' <<<"$arm")"; effort="$(jq -r '.effort // ""' <<<"$arm")"
  cwd="$(lane_get "$lane" cwd)"; sid="$(jq -r '.provisional_session.session_id // empty' <<<"$transition")"
  [[ -n "$sid" ]] || sid="$(lane_get "$lane" session_id)"
  ownership="$(jq -c '.provisional_session.ownership // null' <<<"$transition")"
  target="$(tmux_window_if_owned "$ownership")" || { err "grok escalation: provisional window is not owned"; return 1; }
  [[ -n "$sid" ]] || { err "grok escalation: no resumable session"; return 1; }
  local model_args=() effort_args=() resume_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  case "$effort" in "") ;; none|minimal|low|medium|high|xhigh|max) effort_args=(--effort "$effort") ;; *) err "grok escalation: unsupported effort '$effort'"; return 1 ;; esac
  [[ "$fresh" == true ]] && resume_args=(--session-id "$sid") || resume_args=(--resume "$sid")
  local argv=(grok "${model_args[@]}" "${effort_args[@]}" "${resume_args[@]}" --always-approve --cwd "$cwd" "$prompt")
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done
  tmux_send_owned_window_shell_command "$ownership" "bash -lc $(printf '%q' "${quoted# }")" || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$(lane_transcript "$lane")")" 2>/dev/null || true
  local before=0 events i
  events="$(_grok_events_file "$sid" || true)"; before="$(wc -l <"$events" 2>/dev/null || echo 0)"
  for i in $(seq 1 "${WASPFLOW_SUBMIT_ATTEMPTS:-20}"); do
    events="$(_grok_events_file "$sid" || true)"
    [[ "$(wc -l <"$events" 2>/dev/null || echo 0)" -gt "$before" ]] && break
    sleep 1
  done
  if [[ "$(wc -l <"$events" 2>/dev/null || echo 0)" -le "$before" ]]; then
    return 1
  fi
  WASPFLOW_PROVISIONAL_SESSION_ID="$sid"
  WASPFLOW_PROVISIONAL_ROLLOUT=""
}

grok_confirm_escalation_submission() {
  local lane="$1" _prompt="$2" _fresh="${3:-false}" transition sid events
  transition="$(lane_get "$lane" pending_transition)"
  sid="$(jq -r '.provisional_session.session_id // empty' <<<"$transition")"
  [[ -n "$sid" ]] || return 1
  events="$(_grok_events_file "$sid" || true)"
  [[ -n "$events" && -s "$events" ]] || return 1
  grep -q '"type":"turn_started"\|"type":"turn_ended"\|turn_started\|phase_changed' "$events" 2>/dev/null || return 1
  WASPFLOW_PROVISIONAL_SESSION_ID="$sid"
  WASPFLOW_PROVISIONAL_ROLLOUT=""
}

# Runtime attestation from Grok's session summary
# (~/.grok/sessions/<urlencoded-cwd>/<sid>/summary.json): carries BOTH
# current_model_id and reasoning_effort, authoritative for the session. v1
# observes only (no drift comparison). Snapshot discipline mirrors codex:
# stale (generation, session) evidence never commits across an escalation.
grok_refresh_runtime_settings() {
  local lane="$1" sid dir summary model effort expected_generation expected_session
  expected_generation="$(lane_get "$lane" arm_generation)"
  expected_session="$(lane_get "$lane" session_id)"
  _grok_runtime_refresh_health() {
    lane_update_if "$lane" "$expected_generation" "$expected_session" runtime_refresh_state "$1" runtime_refresh_error "${2:-}" runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  }
  sid="$expected_session"
  [[ -n "$sid" ]] || { _grok_runtime_refresh_health unknown no-session; return 0; }
  dir="$(find "${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}" -maxdepth 2 -type d -name "$sid" 2>/dev/null | head -1)"
  summary="$dir/summary.json"
  [[ -n "$dir" && -f "$summary" && ! -p "$summary" && -r "$summary" ]] || { _grok_runtime_refresh_health unknown no-session-summary; return 0; }
  # Single read: two independent jq passes could pair a model from one write
  # of summary.json with the effort of a concurrent later write.
  local pair
  pair="$(jq -r '[(.current_model_id // ""), (.reasoning_effort // "")] | @tsv' "$summary" 2>/dev/null)"
  model="${pair%%$'\t'*}"; effort="${pair#*$'\t'}"; [[ "$effort" == "$pair" ]] && effort=""
  [[ -n "$model" ]] || { _grok_runtime_refresh_health unknown no-model-in-summary; return 0; }
  local requested requested_effort match
  requested="$(lane_get "$lane" model_requested)"
  [[ -n "$requested" ]] || requested="$(lane_get "$lane" model)"
  requested_effort="$(lane_get "$lane" effort_requested)"
  [[ -n "$requested_effort" ]] || requested_effort="$(lane_get "$lane" effort)"
  # Token-boundary containment: alias "opus" matches "claude-opus-4-8", but
  # "grok-4" must NOT match "grok-4.5" (that is drift, not an alias). Grok
  # attests BOTH axes, so a requested-but-not-served effort is drift too.
  if [[ -z "$requested" || "$model" == "$requested" || "-$model-" == *"-$requested-"* ]]; then
    match=true
  else
    match=false
  fi
  # Grok attests BOTH axes (SCHEMAS_V1). A requested effort the session summary
  # does NOT confirm is unattested, not a match — fail CLOSED, as codex does on
  # an unobserved effort. (F4: the old `-n "$effort"` guard let an effort-less
  # summary keep match=true and produce an eligible receipt attributing an
  # effort that was never observed.)
  if [[ "$match" == true && -n "$requested_effort" && "$effort" != "$requested_effort" ]]; then
    match=false
  fi
  lane_update_if "$lane" "$expected_generation" "$expected_session" \
    runtime_settings_state observed runtime_settings_error "" \
    runtime_model "$model" runtime_effort "$effort" \
    runtime_settings_match_requested "$match" \
    runtime_refresh_state observed runtime_refresh_error "" \
    runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
}
