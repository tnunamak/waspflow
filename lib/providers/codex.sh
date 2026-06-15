#!/usr/bin/env bash
#
# codex.sh — waspflow provider adapter for OpenAI Codex CLI.
#
# Mechanics verified by the 2026-06-15 live spike (see waspflow/docs/spike.md):
#   - Interactive TUI requires a REAL PTY. `codex | tee` fails ("stdout is not a
#     terminal") — so transcripts use `tmux pipe-pane`, never a pipe.
#   - `--skip-git-repo-check` is an `exec`-only flag, NOT valid on bare `codex`.
#   - Bare `codex` in a non-trusted dir blocks on a TRUST prompt
#     ("Do you trust the contents of this directory?"). We pre-trust by git-init'ing
#     a throwaway cwd, but also auto-answer the prompt via send-keys as a belt.
#   - The rollout JSONL  ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
#     is created LAZILY ON FIRST TURN (not at boot). Its filename encodes the
#     session UUID — that's the resume handle.
#   - IDLE when the last rollout event is  event_msg / payload.type == task_complete.
#   - Revise headlessly:  codex exec resume <SID> "<msg>" -o <FILE>
#     (re-enters the SAME session with full context; -o gives a clean last-message).
#   - If Codex is configured to route model calls through a local proxy, spawning
#     without it up yields a turn that never completes — so we PREFLIGHT a
#     configurable health URL ($WASPFLOW_CODEX_BACKEND_HEALTH_URL) when set.

CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"

# Preflight: codex on PATH + the model backend reachable (else turns hang).
codex_preflight() {
  command -v codex >/dev/null 2>&1 || { err "codex not found on PATH"; return 1; }
  local url="$WASPFLOW_CODEX_BACKEND_HEALTH_URL"
  if [[ -n "$url" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      warn "curl not found; cannot verify Codex backend at $url (continuing)"
      return 0
    fi
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || echo 000)"
    if [[ "$code" != "200" ]]; then
      err "Codex model proxy not healthy ($url -> $code). Start the proxy Codex is configured to use,"
      err "  or unset WASPFLOW_CODEX_BACKEND_HEALTH_URL to skip this check when Codex talks to a model directly."
      return 1
    fi
  fi
  return 0
}

# Discover the session UUID + rollout file for a lane. Prefer the recorded value;
# otherwise locate the rollout by matching the lane's cwd against each candidate
# file's session_meta.cwd. We match on CWD, never mtime: a background collector
# re-touches old rollout files (bumping mtime), so "newest by mtime" is wrong —
# and the per-session rollout records the originating cwd in its first line,
# which is exact. The filename embeds the session start time, used only as a
# coarse pre-filter to skip clearly-older files cheaply.
codex_discover_session() {
  local lane="$1" recorded lane_cwd
  recorded="$(lane_get "$lane" session_id)"
  if [[ -n "$recorded" ]]; then echo "$recorded"; return 0; fi

  lane_cwd="$(lane_get "$lane" cwd)"
  [[ -n "$lane_cwd" ]] || { echo ""; return 0; }

  # The rollout for this lane is the newest file whose session_meta.cwd matches
  # the lane's cwd. cwd equality is the selector (never mtime — a background
  # collector bumps mtimes on old files). Shared with the spawn-verify step.
  local match sid
  match="$(_codex_find_rollout_for_cwd "$lane_cwd" || true)"
  [[ -n "$match" ]] || { echo ""; return 0; }
  sid="$(head -1 "$match" 2>/dev/null | jq -rc '.payload.id // empty' 2>/dev/null)"
  [[ -n "$sid" ]] || sid="$(basename "$match" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  if [[ -n "$sid" ]]; then
    lane_set "$lane" session_id "$sid" rollout "$match"
    echo "$sid"
  else
    echo ""
  fi
}

# Spawn an interactive codex into the lane's tmux window (real PTY).
# Args: lane cwd model session_id(unused; codex mints its own) transcript prompt [extra...]
codex_spawn() {
  local lane="$1" cwd="$2" model="$3" _session_id="$4" transcript="$5" prompt="$6"
  shift 6
  local extra=("$@")

  # Pre-trust the cwd by ensuring it's a git repo (codex trusts repos it can read).
  # We do NOT modify a real project repo — only git-init if the dir isn't a repo yet.
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$cwd" init -q 2>/dev/null || true
  fi

  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")

  # Bare interactive codex (NO --skip-git-repo-check — that's exec-only).
  local argv=(codex "${model_args[@]}" "${extra[@]}")
  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  tmux_ensure_session
  tmux new-window -d -t "$WASPFLOW_TMUX_SESSION" -n "$lane" -c "$cwd" "bash -lc $(printf '%q' "${quoted# }")"
  local target; target="$(tmux_window_target "$lane")"
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  # Drive the TUI deterministically. The startup is racy (trust prompt, hook
  # output, "model: loading"), so we synchronize on observable pane state at each
  # step instead of fixed sleeps, then VERIFY submission by waiting for a rollout
  # file to appear for THIS cwd — re-sending Enter if it didn't take.
  _codex_clear_trust_prompt "$target"
  _codex_wait_composer_ready "$target"
  _codex_submit_prompt "$lane" "$cwd" "$target" "$prompt"
}

# A pane snapshot, de-escaped, for state checks.
_codex_pane() { tmux capture-pane -p -t "$1" -S -60 2>/dev/null | strip_ansi; }

# Clear the "Do you trust this directory?" prompt if/when it appears. We poll up
# to ~20s; the prompt may appear a beat after launch. Selecting "1" + Enter =
# "Yes, continue". If it never appears (already-trusted dir), this is a no-op.
_codex_clear_trust_prompt() {
  local target="$1" i pane
  for i in $(seq 1 20); do
    pane="$(_codex_pane "$target")"
    if grep -qi "Do you trust" <<<"$pane"; then
      tmux send-keys -t "$target" "1"
      sleep 1
      tmux send-keys -t "$target" Enter
      # Wait for the prompt to actually clear before returning.
      local j
      for j in $(seq 1 10); do
        grep -qi "Do you trust" <<<"$(_codex_pane "$target")" || return 0
        sleep 1
      done
      return 0
    fi
    # If the composer is already up (no trust prompt), nothing to clear.
    grep -qiE "OpenAI Codex|/model to change" <<<"$pane" && return 0
    sleep 1
  done
  return 0
}

# Wait until the composer is genuinely ready: the model line shows a model (not
# "loading") and the trust prompt is gone. Best-effort with a cap.
_codex_wait_composer_ready() {
  local target="$1" i pane
  for i in $(seq 1 30); do
    pane="$(_codex_pane "$target")"
    if ! grep -qi "Do you trust" <<<"$pane" \
       && grep -qiE "model: *gpt-|gpt-[0-9].* (medium|low|high|default) " <<<"$pane"; then
      return 0
    fi
    sleep 1
  done
  return 0  # proceed regardless; the submit step verifies real success
}

# Type the prompt and submit, then VERIFY by polling for a rollout file whose
# session_meta.cwd == our cwd. If none appears, re-send Enter (the most common
# failure is the Enter racing hook output). Up to a few attempts.
_codex_submit_prompt() {
  local lane="$1" cwd="$2" target="$3" prompt="$4" attempt
  # Type the prompt once (separate from Enter to avoid composer races).
  tmux send-keys -t "$target" -- "$prompt"
  sleep 1
  for attempt in 1 2 3 4 5; do
    tmux send-keys -t "$target" Enter
    # Give the turn a moment to start + write its session_meta line.
    local j
    for j in $(seq 1 6); do
      if _codex_find_rollout_for_cwd "$cwd" >/dev/null; then
        return 0
      fi
      sleep 1
    done
    warn "codex spawn: submit attempt $attempt did not start a turn for lane '$lane'; retrying Enter"
  done
  warn "codex spawn: prompt may not have submitted for lane '$lane' (no rollout for $cwd). Inspect: waspflow attach $lane"
  return 0
}

# Echo the rollout file path whose session_meta.cwd == $1, newest-first by
# filename (session start time). Non-zero if none. Reads only line 1 per file.
_codex_find_rollout_for_cwd() {
  local cwd="$1" f fcwd
  # Materialize the candidate list first so an early `return` doesn't SIGPIPE the
  # find|sort|cut producer (which prints harmless "broken pipe" to stderr).
  local listing; listing="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -printf '%f\t%p\n' 2>/dev/null | sort -rn | cut -f2-)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fcwd="$(head -1 "$f" 2>/dev/null | jq -rc 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null)"
    if [[ "$fcwd" == "$cwd" ]]; then echo "$f"; return 0; fi
  done <<<"$listing"
  return 1
}

# IDLE predicate: last rollout event is task_complete.
# Args: lane
codex_is_idle() {
  local lane="$1" sid rollout last
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || return 1
  rollout="$(lane_get "$lane" rollout)"
  if [[ -z "$rollout" || ! -f "$rollout" ]]; then
    rollout="$(find "$CODEX_SESSIONS_DIR" -type f -name "*${sid}.jsonl" 2>/dev/null | head -1)"
  fi
  [[ -n "$rollout" && -f "$rollout" ]] || return 1
  last="$(tail -1 "$rollout" 2>/dev/null \
          | jq -rc '(.payload.type // .type) // empty' 2>/dev/null)"
  [[ "$last" == "task_complete" ]]
}

# Revise. If the tmux window is live, steer in-pane via send-keys; otherwise
# resume headlessly via `codex exec resume <SID> "<msg>" -o <FILE>`.
# Args: lane message out_file
codex_revise() {
  local lane="$1" message="$2" out_file="${3:-}"
  local sid cwd model
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || { err "no session_id for lane '$lane' (has it run a turn yet?)"; return 1; }
  cwd="$(lane_get "$lane" cwd)"
  model="$(lane_get "$lane" model)"

  if tmux_window_exists "$lane"; then
    # Live in-pane steer. The Enter can race pane state, so VERIFY the turn
    # actually started by watching the rollout grow, re-sending Enter if not.
    local target rollout before after attempt j
    target="$(tmux_window_target "$lane")"
    rollout="$(lane_get "$lane" rollout)"
    [[ -n "$rollout" && -f "$rollout" ]] || rollout="$(_codex_find_rollout_for_cwd "$cwd" || true)"
    before="$(wc -l <"$rollout" 2>/dev/null || echo 0)"
    tmux send-keys -t "$target" -- "$message"
    sleep 1
    for attempt in 1 2 3 4 5; do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 6); do
        after="$(wc -l <"$rollout" 2>/dev/null || echo 0)"
        # A new turn appends a task_started + the user message; line count grows.
        [[ "$after" -gt "$before" ]] && return 0
        sleep 1
      done
      warn "codex revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    warn "codex revise: message may not have submitted for lane '$lane' (rollout did not grow)"
    return 0
  fi

  # Headless resumed turn. Run from the lane's cwd so any repo context resolves.
  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  local tmp; tmp="${out_file:-$(mktemp)}"
  ( cd "${cwd:-$PWD}" && codex exec resume "$sid" "$message" "${model_args[@]}" -o "$tmp" ) \
    >/dev/null 2>&1
  if [[ -z "$out_file" ]]; then cat "$tmp"; rm -f "$tmp"; fi
  return 0
}
