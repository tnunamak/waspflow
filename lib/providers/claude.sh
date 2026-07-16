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

# Claude's model set is small and stable (opus/sonnet/haiku aliases + dated ids)
# and there's no auth-scoped cache to read, so we don't second-guess --model here:
# echo nothing (rc 1) → spawn skips validation (fail OPEN). The claude CLI rejects a
# genuinely bad model itself. Defined for provider-contract parity.
claude_valid_models() { printf 'source=non_enumerable\n'; }

# Claude supports a strict empty MCP configuration. Keep this detail in the
# adapter: generic orchestration only handles the resolved command description.
claude_mcp_policy() {
  case "$1" in
    inherit) printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}' ;;
    auto|none)
      jq -cn --arg config '{"mcpServers":{}}' \
        '{resolved:"none",warning:"",argv:["--strict-mcp-config","--mcp-config",$config],env:{ENABLE_CLAUDEAI_MCP_SERVERS:"false"}}'
      ;;
    *) return 1 ;;
  esac
}

# Claude combines repeated --mcp-config values. Do not let a caller append a
# server-bearing config while waspflow is claiming auto/none isolation.
claude_mcp_validate_extra() {
  local requested="$1"; shift
  [[ "$requested" == "inherit" ]] && return 0
  local arg
  for arg in "$@"; do
    case "$arg" in --mcp-config|--mcp-config=*) return 1 ;; esac
  done
  return 0
}

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
  mcp_policy_load_lane "$lane"
  local effort_args=() effort
  effort="$(lane_get "$lane" effort)"
  [[ -n "$effort" ]] && effort_args=(--effort "$effort")

  # Build the command run INSIDE the tmux window. We pass the prompt as a
  # positional arg (interactive claude reads the PTY, not piped stdin) and do
  # NOT redirect output (claude owns the PTY; tmux pipe-pane captures the
  # transcript). --dangerously-skip-permissions because the lane is unattended.
  #
  # We assemble an argv array and quote it for the tmux shell.
  local argv=(env "${MCP_ENV[@]}" claude
    "${model_args[@]}"
    "${effort_args[@]}"
    --session-id "$session_id"
    --name "$lane"
    --dangerously-skip-permissions
    "${extra[@]}"
    "${MCP_ARGV[@]}"
    --
    "$prompt")

  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  local target
  target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc${quoted:+ }$(printf '%q' "${quoted# }")")" \
    || return 1
  # Capture a live transcript via pipe-pane (parity with codex).
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  # Clear Claude's folder-trust gate if it appears. --dangerously-skip-permissions
  # governs TOOL permissions, NOT the "Is this a project you trust?" folder gate,
  # which still blocks startup in an unfamiliar dir. The task prompt was passed as
  # a positional arg, so it auto-runs once trust is cleared — no separate submit.
  _claude_clear_trust_prompt "$target"
  # Confirm the task actually submitted (prompt lands as a user event). Propagate
  # the result so cmd_spawn can warn loudly on a dead-on-arrival lane instead of
  # reporting a false success.
  _claude_verify_started "$lane" "$target"
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

# Confirm the task ACTUALLY SUBMITTED — not just that a window exists. A silent
# dead-on-arrival lane (fresh banner, task never injected because a modal stole
# focus) is the worst failure: the orchestrator thinks work is in flight when it
# isn't. So this returns SUCCESS only once the prompt appears as a `user` message
# in the session JSONL, and it actively clears the modals that block submission:
#   - the folder-trust gate ("Is this a project you trust?")
#   - the MCP-auth banner is passive (doesn't block), but if a blocking /mcp or
#     other prompt appears we send Enter/Escape to dismiss and let the task run.
# Returns 0 if submission confirmed, 1 if not (caller surfaces this loudly).
_claude_verify_started() {
  local lane="$1" target="$2" expected_prompt="${3:-$(lane_get "$1" prompt)}" sid="${4:-}" nonce="${5:-}" jsonl i pane
  [[ -n "$sid" ]] || sid="$(claude_discover_session "$lane")"
  [[ -n "$sid" ]] || return 1
  # Attempts are env-tunable so tests can exercise the failure path fast; default
  # 30 (~30s) gives a real spawn ample time to submit past startup modals.
  local attempts="${WASPFLOW_SUBMIT_ATTEMPTS:-30}"
  for i in $(seq 1 "$attempts"); do
    jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)"
    # Submission confirmed: a user event carries the task. Use a distinctive slice
    # of the prompt so we match the real submission, not an echo of the composer.
    if [[ -n "$jsonl" && -s "$jsonl" ]]; then
      if jq -rc 'select(.type=="user") | (.message.content // .message // "" | tostring)' "$jsonl" 2>/dev/null \
           | grep -qF "${nonce:-${expected_prompt:0:40}}"; then
        return 0
      fi
    fi
    pane="$(_claude_pane "$target")"
    # Re-clear the trust gate if it (re)appeared.
    if grep -qiE "trust this folder|Is this a project you" <<<"$pane"; then
      tmux send-keys -t "$target" "1"; sleep 1; tmux send-keys -t "$target" Enter
    fi
    sleep 1
  done
  return 1
}

# Escalation is intentionally a new interactive window even when the provider
# session is retained.  It does not claim lane ownership: the transition CAS in
# bin/waspflow adopts this provisional window only after submission is proven.
# Args: lane escalation_prompt [fresh]
claude_resume_with_arm() {
  local lane="$1" prompt="$2" fresh="${3:-false}" transition arm model effort cwd sid target ownership nonce quoted="" a
  transition="$(lane_get "$lane" pending_transition)"
  arm="$(jq -c '.to_arm // {}' <<<"$transition" 2>/dev/null)"
  model="$(jq -r '.model // ""' <<<"$arm")"; effort="$(jq -r '.effort // ""' <<<"$arm")"
  cwd="$(lane_get "$lane" cwd)"; sid="$(jq -r '.provisional_session.session_id // empty' <<<"$transition")"
  [[ -n "$sid" ]] || sid="$(lane_get "$lane" session_id)"
  ownership="$(jq -c '.provisional_session.ownership // null' <<<"$transition")"
  target="$(tmux_window_if_owned "$ownership")" || { err "claude escalation: provisional window is not owned"; return 1; }
  nonce="$(jq -r '.submission_nonce // empty' <<<"$transition")"
  [[ -n "$sid" ]] || { err "claude escalation: no resumable session"; return 1; }
  mcp_policy_load_lane "$lane"
  local model_args=() effort_args=() resume_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")
  [[ -n "$effort" ]] && effort_args=(--effort "$effort")
  [[ "$fresh" == true ]] && resume_args=(--session-id "$sid") || resume_args=(--resume "$sid")
  local argv=(env "${MCP_ENV[@]}" claude "${resume_args[@]}" "${model_args[@]}" "${effort_args[@]}" --name "$lane" --dangerously-skip-permissions "${MCP_ARGV[@]}" -- "$prompt")
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done
  tmux_send_owned_window_shell_command "$ownership" "bash -lc $(printf '%q' "${quoted# }")" || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$(lane_transcript "$lane")")" 2>/dev/null || true
  _claude_clear_trust_prompt "$target"
  if ! _claude_verify_started "$lane" "$target" "$prompt" "$sid" "$nonce"; then
    return 1
  fi
  WASPFLOW_PROVISIONAL_SESSION_ID="$sid"
  WASPFLOW_PROVISIONAL_ROLLOUT=""
}

claude_confirm_escalation_submission() {
  local lane="$1" prompt="$2" _fresh="${3:-false}" transition ownership target sid nonce
  transition="$(lane_get "$lane" pending_transition)"
  ownership="$(jq -c '.provisional_session.ownership // null' <<<"$transition")"
  target="$(tmux_window_if_owned "$ownership")" || return 1
  sid="$(jq -r '.provisional_session.session_id // empty' <<<"$transition")"
  nonce="$(jq -r '.submission_nonce // empty' <<<"$transition")"
  _claude_verify_started "$lane" "$target" "$prompt" "$sid" "$nonce" || return 1
  WASPFLOW_PROVISIONAL_SESSION_ID="$sid"
  WASPFLOW_PROVISIONAL_ROLLOUT=""
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

# How recently a subagent transcript must have been written to count as "still
# active". A running subagent flushes events continuously; once it finishes (or
# dies) its file goes cold. This bounds the wait so a killed/hung child can't
# block reaping forever, while being generous enough to survive slow model turns.
CLAUDE_SUBAGENT_ACTIVE_SECS="${CLAUDE_SUBAGENT_ACTIVE_SECS:-45}"

# Are any of the parent session's Task/subagents still running?
#
# Signal (ground-truthed against real ~/.claude/projects files, 2026-07):
#   Claude Code writes each subagent's transcript to a SEPARATE file at
#     <projects>/<slug>/<session-id>/subagents/agent-*.jsonl
#   Every such file carries "isSidechain":true and the SAME sessionId as the
#   parent. The parent's own JSONL does NOT reliably inline subagent events, and
#   in the modern schema the parent's Task tool_use/tool_result pairing is often
#   pruned/compacted away — so the parent file alone cannot tell us a child is
#   live. The child FILES are the observable signal.
#
# A subagent is treated as ACTIVE when its transcript was modified within
# CLAUDE_SUBAGENT_ACTIVE_SECS AND its last event is not a clean terminal turn
# (assistant/end_turn). The mtime gate ignores children that already finished
# (cold files); the terminal-state gate ignores a child that finished cleanly
# but whose file is coincidentally fresh.
#
# Reliability, stated honestly: this is a heuristic, biased toward the SAFE side
# (waiting too long beats reaping an empty worktree). A subagent that stalls
# without writing for >ACTIVE_SECS reads as done; conversely a child mid-turn
# always reads as active. It cannot see subagents that never wrote a file yet
# (sub-second race right after spawn) — the parent's end_turn gate below plus
# wait's polling covers that in practice. Returns 0 if any child looks active.
_claude_children_active() {
  local session_id="$1" subdir sub last_mtime now age
  # Parent transcript dir: <projects>/<slug>/<session-id>/subagents/
  # Locate it via the parent jsonl's dir so we don't guess the slug.
  local parent_jsonl parent_dir
  parent_jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" 2>/dev/null | head -1)"
  [[ -n "$parent_jsonl" ]] || return 1
  parent_dir="$(dirname "$parent_jsonl")"
  subdir="$parent_dir/${session_id}/subagents"
  [[ -d "$subdir" ]] || return 1

  now="$(date +%s)"
  while IFS= read -r sub; do
    [[ -n "$sub" && -f "$sub" ]] || continue
    last_mtime="$(stat -c %Y "$sub" 2>/dev/null || echo 0)"
    age=$(( now - last_mtime ))
    # Cold file → that child is done (or dead); skip it.
    [[ "$age" -le "$CLAUDE_SUBAGENT_ACTIVE_SECS" ]] || continue
    # Fresh file: active unless its last assistant turn already ended cleanly.
    local child_reason
    child_reason="$(jq -rc 'select(.type=="assistant") | .message.stop_reason // empty' "$sub" 2>/dev/null | tail -1)"
    [[ "$child_reason" == "end_turn" ]] || return 0
  done < <(find "$subdir" -maxdepth 1 -type f -name 'agent-*.jsonl' 2>/dev/null)
  return 1
}

# IDLE predicate: the parent's last assistant event ended its turn AND no child
# subagent is still active. A Claude parent that spawned Task/subagents ends its
# OWN turn (end_turn) while the children keep writing the deliverable; gating on
# the parent alone reaps a partial/empty worktree. See _claude_children_active.
# Args: lane
claude_is_idle() {
  local lane="$1" session_id jsonl last_reason
  session_id="$(claude_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" \
            -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
  [[ -n "$jsonl" && -f "$jsonl" ]] || return 1
  last_reason="$(jq -rc 'select(.type=="assistant") | .message.stop_reason // empty' "$jsonl" 2>/dev/null | tail -1)"
  [[ "$last_reason" == "end_turn" ]] || return 1
  # Parent turn ended — but hold IDLE while any spawned subagent is still writing.
  if _claude_children_active "$session_id"; then
    return 2   # distinct nonzero: "parent done, children still active" (not idle)
  fi
  return 0
}

# turn_mark: count of COMPLETED assistant turns (assistant events with
# stop_reason == end_turn) in the session. This is the correct barrier signal:
# it advances ONLY when a turn finishes, not on the pasted user message or the
# file-history-snapshot/system events that trail a turn. `wait` records this at
# revise time and honors idle only once it INCREASES — i.e. the revised turn
# actually completed. (A line-count mark was wrong: snapshots advance it without
# a turn completing, clearing the barrier prematurely — verified live 2026-07-09.)
# Echoes 0 if the session isn't found yet.
claude_turn_mark() {
  local lane="$1" session_id jsonl
  session_id="$(claude_discover_session "$lane")"
  [[ -n "$session_id" ]] || { echo 0; return 0; }
  jsonl="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${session_id}.jsonl" 2>/dev/null | head -1)"
  [[ -n "$jsonl" && -f "$jsonl" ]] || { echo 0; return 0; }
  jq -rc 'select(.type=="assistant" and .message.stop_reason=="end_turn") | 1' "$jsonl" 2>/dev/null | wc -l
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

  # Billing guard BEFORE the live-vs-headless branch: revising an already-live
  # pane bills API turns too, so the guard must cover that path — not just the
  # headless resume below. (Fixes the "$1,800-trap" bypass on live-pane steering.)
  billing_preflight_provider claude || return 1

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
  mcp_policy_load_lane "$lane"
  local tmp; tmp="${out_file:-$(mktemp)}"
  local attempt rc
  for attempt in 1 2 3 4 5; do
    rc=0
    # Resume from the lane's cwd: claude --resume is scoped to the project dir.
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- \
      env "${MCP_ENV[@]}" claude --resume "$session_id" --print "${model_args[@]}" \
      --dangerously-skip-permissions "${MCP_ARGV[@]}" -- "$message" </dev/null >"$tmp" 2>&1 || rc=$?
    if grep -q "No conversation found" "$tmp" 2>/dev/null; then
      sleep $(( attempt * 2 ))
      continue
    fi
    break
  done
  [[ -n "$out_file" ]] || { cat "$tmp"; rm -f "$tmp"; }
  return "${rc:-0}"
}

# Runtime attestation from Claude's own session log (~/.claude/projects/*/
# <sid>.jsonl): the authoritative record of which model actually served each
# message. Claude does not expose a per-session effort in the log, so
# runtime_effort stays empty (receipts record null — observed, not guessed).
# v1 observes only; no drift comparison (requested aliases like "opus" resolve
# to canonical ids like "claude-opus-4-8", so naive equality would false-alarm).
# The (arm_generation, session_id) snapshot mirrors codex: a refresh that
# straddles an escalation must never commit stale evidence.
claude_refresh_runtime_settings() {
  local lane="$1" sid file model expected_generation expected_session
  expected_generation="$(lane_get "$lane" arm_generation)"
  expected_session="$(lane_get "$lane" session_id)"
  _claude_runtime_refresh_health() {
    lane_update_if "$lane" "$expected_generation" "$expected_session" runtime_refresh_state "$1" runtime_refresh_error "${2:-}" runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  }
  sid="$expected_session"
  [[ -n "$sid" ]] || { _claude_runtime_refresh_health unknown no-session; return 0; }
  file="$(find "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" -maxdepth 2 -name "${sid}.jsonl" 2>/dev/null | head -1)"
  [[ -n "$file" && -f "$file" && ! -p "$file" && -r "$file" ]] || { _claude_runtime_refresh_health unknown no-session-log; return 0; }
  # Typed extraction, not raw grep: task/tool content can embed forged
  # "model":"claude-…" strings, and attestation feeding flywheel eligibility
  # must not be forgeable from untrusted content. grep narrows candidate lines
  # (logs reach hundreds of MB), jq types them: only top-level assistant
  # records count. timeout guards reap against pathological files.
  local models grep_cmd=(grep -a '"model":"claude-' "$file")
  # When timeout exists it is the ONLY grep we run: a fallback rerun after an
  # expiry would be exactly the unbounded scan the guard exists to prevent.
  command -v timeout >/dev/null 2>&1 && grep_cmd=(timeout 15 "${grep_cmd[@]}")
  models="$("${grep_cmd[@]}" 2>/dev/null \
    | jq -r 'select(type == "object" and .type? == "assistant") | .message.model // empty' 2>/dev/null | sort -u)"
  [[ -n "$models" ]] || { _claude_runtime_refresh_health unknown no-model-events; return 0; }
  if [[ "$(wc -l <<<"$models")" -gt 1 ]]; then
    # More than one model served this session (provider fallback, /model switch
    # outside waspflow) — the arm axis was NOT stable. Observed, but mismatched.
    lane_update_if "$lane" "$expected_generation" "$expected_session" \
      runtime_settings_state observed runtime_settings_error "multiple-models-observed" \
      runtime_model "$(tail -1 <<<"$models")" runtime_effort "" \
      runtime_settings_match_requested false \
      runtime_refresh_state observed runtime_refresh_error "" \
      runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
    return 0
  fi
  model="$models"
  # Alias-tolerant corroboration: requested "opus" serves as "claude-opus-4-8".
  local requested match
  requested="$(lane_get "$lane" model_requested)"
  [[ -n "$requested" ]] || requested="$(lane_get "$lane" model)"
  # Token-boundary containment: alias "opus" matches "claude-opus-4-8", but
  # "grok-4" must NOT match "grok-4.5" (that is drift, not an alias).
  if [[ -z "$requested" || "$model" == "$requested" || "-$model-" == *"-$requested-"* ]]; then
    match=true
  else
    match=false
  fi
  lane_update_if "$lane" "$expected_generation" "$expected_session" \
    runtime_settings_state observed runtime_settings_error "" \
    runtime_model "$model" runtime_effort "" \
    runtime_settings_match_requested "$match" \
    runtime_refresh_state observed runtime_refresh_error "" \
    runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
}
