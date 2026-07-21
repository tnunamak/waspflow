#!/usr/bin/env bash
#
# gemini.sh — waspflow provider adapter for Google's Gemini CLI (`gemini`).
#
# Mechanics verified against a real, installed `gemini` CLI (v0.50.0 and
# v0.51.0, 2026-07-21):
#   - Interactive (resumable) gemini = mint --session-id <uuid> (the addressable
#     resume handle, same pattern as Claude's --session-id — NOT auto-assigned).
#     Resume an existing session with --resume <uuid> (or --resume latest).
#   - Headless one-shot: `gemini -p "<msg>" -o json --approval-mode yolo`.
#     -o/--output-format json is required to get a parseable final response
#     instead of raw TTY-formatted text.
#   - First-run TRUST GATE: an untrusted directory blocks even --approval-mode
#     yolo with "Gemini CLI is not running in a trusted directory... use
#     --skip-trust". This is a SEPARATE gate from tool-call approval (yolo)
#     — confirmed directly: yolo alone does not clear it. --skip-trust clears
#     both non-interactively; the interactive TUI's numbered trust prompt
#     ("Do you trust this folder?") is the same gate encountered live.
#   - Session transcript: ~/.gemini/tmp/<basename-of-launch-cwd>/chats/
#       session-<ISO8601-with-dashes>-<8charhex>.jsonl
#     The FIRST line is a JSON object carrying "sessionId" (our minted UUID) —
#     this is the authoritative session<->file correlation, not the filename
#     (the filename's suffix is Gemini's own short id fragment, not ours).
#   - IDLE / turn-complete: gemini's chat JSONL is an append-only sequence of
#     `{"$set":{"messages":[...]}}` snapshots, not per-event turn markers like
#     Codex/Grok. The transcript is authoritative for CONTENT but not a clean
#     turn_started/turn_ended boundary; -o json's PROCESS EXIT is the real
#     headless completion signal (mirrors --print for Claude), so is_idle for
#     an interactive lane is judged the same way Claude's is: the last
#     `model`-role message in the chat log settled (no further tool-call
#     entries queued) — see _gemini_last_message_is_final below.
#   - Revise after the pane exits: `gemini --resume <session-id> -p "<msg>"
#     -o json --approval-mode yolo` (headless resume).
#
# KNOWN LIMITATION, STATED HONESTLY: this adapter has NOT been proven against
# a real task run to completion. This machine's linked Google account is
# rejected outright by both gemini-cli 0.50.0 and 0.51.0 with
# IneligibleTierError ("This client is no longer supported for Gemini Code
# Assist for individuals... migrate to Antigravity") — a server-side
# account-tier check, not a flag/version issue (confirmed: identical error
# with --skip-trust, GEMINI_API_KEY env override, and a local
# gemini-api-key auth-type override; unresolved by upgrading the CLI).
# Every mechanic above was verified as far as this account allows: real flag
# parsing, the trust gate, and the transcript file layout under
# ~/.gemini/tmp/ were all observed directly from real (pre-auth-failure)
# process behavior. What was NOT observed: a real turn completing, real
# in-session steering, or real model/effort attestation. See
# docs/design/FEDERATION_V0_UAT_REPORT.md.
#
# Contract functions (called by core): gemini_preflight, gemini_spawn,
# gemini_is_idle, gemini_revise, gemini_discover_session,
# gemini_session_resumable, gemini_turn_mark, gemini_valid_models,
# gemini_mcp_policy.

GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
GEMINI_TMP_DIR="${GEMINI_TMP_DIR:-$GEMINI_HOME/tmp}"

# Gemini's model set (2.5/3.x family + aliases) has no auth-scoped live-query
# command like Codex's `codex debug models`; there is no local cache either.
# Fail OPEN (rc 1, no lines) so spawn skips validation — the gemini CLI
# rejects a genuinely bad --model itself. Parity with claude_valid_models.
gemini_valid_models() { printf 'source=non_enumerable\n'; }

# Gemini's `mcp` subcommand manages persistent config, not a per-launch
# strict/empty flag. There is no confirmed strict-empty-MCP launch mode for
# this CLI (unlike Claude's --strict-mcp-config). `auto` is honest
# inheritance with a durable warning, matching Grok's pattern; explicit
# `none` fails closed rather than claiming an isolation boundary unproven.
gemini_mcp_policy() {
  case "$1" in
    inherit) printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}' ;;
    auto) printf '%s\n' '{"resolved":"inherit","warning":"Gemini MCP auto resolves to inherit: this Gemini CLI has no confirmed MCP-minimal launch mode.","argv":[],"env":{}}' ;;
    none)
      err "gemini: --mcp none is unsupported; refusing to launch with an unverified MCP boundary"
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Preflight: gemini on PATH. Billing follows GEMINI_API_KEY vs OAuth exactly
# like Grok's XAI_API_KEY / Codex's OPENAI_API_KEY pattern (soft notice, not a
# hard stop — see lib/billing.sh billing_preflight_gemini).
gemini_preflight() {
  command -v gemini >/dev/null 2>&1 || { err "gemini not found on PATH"; return 1; }
  billing_preflight_provider gemini || return 1
  return 0
}

# The session id IS minted by us and passed via --session-id (confirmed a
# real, accepted flag against gemini --help), so discovery is the recorded
# value — same pattern as Claude and Grok.
gemini_discover_session() {
  local lane="$1"
  lane_get "$lane" session_id
}

# Resolve the chat transcript path for a session id. Gemini's per-project
# tmp dir is named for the launch cwd's basename (confirmed empirically:
# /tmp/gemini-probe2 -> ~/.gemini/tmp/gemini-probe2/chats/session-*.jsonl),
# NOT a hash — but since a hashed variant could exist for other install
# configs, and the basename is not guaranteed unique across different full
# paths, correctness comes from matching sessionId inside the file content,
# never the filename or directory alone.
_gemini_chats_dir() {
  local cwd="$1"
  printf '%s/%s/chats\n' "$GEMINI_TMP_DIR" "$(basename "$cwd")"
}

# Echo the chat transcript file whose first-line sessionId matches. Newest
# first by mtime; correctness comes from the sessionId match, not ordering.
_gemini_find_session_file() {
  local cwd="$1" session_id="$2" dir f fsid
  [[ -n "$session_id" ]] || return 1
  dir="$(_gemini_chats_dir "$cwd")"
  [[ -d "$dir" ]] || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fsid="$(head -1 "$f" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)"
    [[ "$fsid" == "$session_id" ]] || continue
    echo "$f"
    return 0
  done < <(find "$dir" -maxdepth 1 -type f -name 'session-*.jsonl' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
  return 1
}

# Spawn an interactive, resumable gemini into the lane's tmux window.
# Args: lane cwd model session_id transcript prompt [extra...]
gemini_spawn() {
  local lane="$1" cwd="$2" model="$3" session_id="$4" transcript="$5" prompt="$6"
  shift 6
  local extra=("$@")

  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  mcp_policy_load_lane "$lane"
  # gemini has no distinct --effort flag (confirmed via --help); it is not
  # in the CLI's option surface at all, unlike Codex/Claude/Grok. Rather than
  # silently drop a requested effort, hard-fail — the same "never silently
  # remap/drop" discipline codex_spawn applies to an unsupported value.
  local effort
  effort="$(lane_get "$lane" effort)"
  [[ -z "$effort" ]] || die "gemini: effort is not supported by this CLI (no --effort/--reasoning-effort flag exists); do not request one for a gemini lane"

  # --approval-mode yolo clears TOOL-CALL approval only; it is a SEPARATE gate
  # from the first-run directory-trust prompt (confirmed directly: yolo alone
  # left an untrusted-dir headless run blocked). --skip-trust clears the trust
  # gate non-interactively so an unattended lane never stalls on either.
  local argv=(gemini
    "${model_args[@]}"
    --session-id "$session_id"
    --approval-mode yolo
    --skip-trust
    "${extra[@]}"
    "${MCP_ARGV[@]}"
    "$prompt")

  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  local target
  target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc${quoted:+ }$(printf '%q' "${quoted# }")")" \
    || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  _gemini_verify_started "$lane" "$cwd" "$target" "$session_id"
}

_gemini_pane() { tmux capture-pane -p -t "$1" -S -60 2>/dev/null | strip_ansi; }

# Confirm the task ACTUALLY SUBMITTED, not just that a window exists — same
# dead-on-arrival concern _claude_verify_started guards against. Success is
# the chat transcript file appearing with our sessionId as its first line.
# --skip-trust means there is no trust-gate modal left to clear here (unlike
# claude/codex, whose trust prompts survive their own bypass flags); this
# only polls for the file, it does not attempt to answer any prompt.
_gemini_verify_started() {
  local lane="$1" cwd="$2" target="$3" session_id="$4" i file
  local attempts="${WASPFLOW_SUBMIT_ATTEMPTS:-30}"
  for i in $(seq 1 "$attempts"); do
    file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
    if [[ -n "$file" && -s "$file" ]]; then
      lane_set "$lane" gemini_chat_file "$file"
      return 0
    fi
    sleep 1
  done
  warn "gemini spawn: session transcript not visible yet for lane '$lane' (sid=$session_id). Inspect: waspflow attach $lane"
  return 1
}

# Session is resumable once its chat file exists with content — same
# predicate shape as claude_session_resumable / grok_session_resumable.
gemini_session_resumable() {
  local lane="$1" session_id cwd file
  session_id="$(gemini_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  cwd="$(lane_get "$lane" cwd)"
  file="$(lane_get "$lane" gemini_chat_file)"
  [[ -n "$file" && -f "$file" ]] || file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
  [[ -n "$file" && -s "$file" ]]
}

# IDLE predicate. Gemini's chat log has no explicit turn_ended/end_turn
# marker (unlike Claude/Codex/Grok) — it is a sequence of `{"$set":{...}}`
# snapshots that grow monotonically while a turn is in flight. Without a
# real completed run to observe the terminal snapshot shape against, this
# adapter uses the SAME conservative signal claude_is_idle's fallback
# would: the transcript file has stopped growing for a short quiet window.
# This is DELIBERATELY a weaker guarantee than the other three adapters'
# event-typed idle predicates, and is documented as such rather than
# invented and presented as equally strong. Args: lane
GEMINI_IDLE_QUIET_SECS="${GEMINI_IDLE_QUIET_SECS:-5}"
gemini_is_idle() {
  local lane="$1" session_id cwd file size1 size2
  session_id="$(gemini_discover_session "$lane")"
  [[ -n "$session_id" ]] || return 1
  cwd="$(lane_get "$lane" cwd)"
  file="$(lane_get "$lane" gemini_chat_file)"
  [[ -n "$file" && -f "$file" ]] || file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
  [[ -n "$file" && -f "$file" ]] || return 1
  size1="$(wc -c <"$file" 2>/dev/null || echo -1)"
  sleep "$GEMINI_IDLE_QUIET_SECS"
  size2="$(wc -c <"$file" 2>/dev/null || echo -2)"
  [[ "$size1" == "$size2" && "$size1" != "-1" ]]
}

# turn_mark: since there is no typed turn-boundary event to count (see
# gemini_is_idle), this falls back to a monotonic content mark (line count)
# — like the line-count mark claude.sh's own comments describe having moved
# AWAY from for exactly this reason (snapshots can advance a line count
# without a turn completing). Documented honestly as a WEAKER signal than
# the other three adapters', not silently presented as equivalent.
gemini_turn_mark() {
  local lane="$1" session_id cwd file
  session_id="$(gemini_discover_session "$lane")"
  [[ -n "$session_id" ]] || { echo 0; return 0; }
  cwd="$(lane_get "$lane" cwd)"
  file="$(lane_get "$lane" gemini_chat_file)"
  [[ -n "$file" && -f "$file" ]] || file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
  [[ -n "$file" && -f "$file" ]] || { echo 0; return 0; }
  wc -l <"$file" 2>/dev/null || echo 0
}

# Revise: re-enter the session and run one turn. Two paths:
#   - Live tmux window: steer in-pane via paste-buffer.
#   - Exited: headless `gemini --resume <session-id> -p "<msg>" -o json
#     --approval-mode yolo --skip-trust`.
# Args: lane message out_file
gemini_revise() {
  local lane="$1" message="$2" out_file="${3:-}"
  local session_id model cwd
  session_id="$(gemini_discover_session "$lane")"
  [[ -n "$session_id" ]] || { err "no session_id recorded for lane '$lane'"; return 1; }
  model="$(lane_get "$lane" model)"
  cwd="$(lane_get "$lane" cwd)"

  billing_preflight_provider gemini || return 1

  if tmux_window_exists "$lane"; then
    local target file before after attempt j
    target="$(tmux_window_target "$lane")"
    file="$(lane_get "$lane" gemini_chat_file)"
    [[ -n "$file" && -f "$file" ]] || file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
    before="$(wc -l <"$file" 2>/dev/null || echo 0)"
    tmux send-keys -t "$target" C-u
    sleep 0.3
    tmux_paste_text "$target" "$message"
    sleep 1
    for attempt in 1 2 3 4 5; do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 6); do
        [[ -z "$file" ]] && file="$(_gemini_find_session_file "$cwd" "$session_id" || true)"
        after="$(wc -l <"$file" 2>/dev/null || echo 0)"
        [[ "$after" -gt "$before" ]] && return 0
        sleep 1
      done
      warn "gemini revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    warn "gemini revise: message may not have submitted for lane '$lane' (transcript did not grow)"
    return 0
  fi

  # Headless resume after the pane exited.
  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  local tmp; tmp="${out_file:-$(mktemp)}"
  tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- \
    gemini --resume "$session_id" -p "$message" -o json --approval-mode yolo --skip-trust \
    "${model_args[@]}" </dev/null >"$tmp" 2>&1
  local rc=$?
  [[ -n "$out_file" ]] || { cat "$tmp"; rm -f "$tmp"; }
  return "$rc"
}
