#!/usr/bin/env bash
# qwen.sh - waspflow adapter for Qwen Code (qwen CLI).
#
# Qwen Code is treated as an opaque headless process.  Each
# `qwen -p ... --yolo` invocation is one-shot and exits when done.
# Lifecycle truth lives in the Waspflow-owned receipt JSONL; Qwen's
# internal session logs are used only for session ID discovery and
# runtime attestation.
#
# Session IDs cannot be pre-minted (no --session-id flag).  Qwen assigns
# its own UUID, discovered from the stream-json session_start event or
# from the filesystem (~/.qwen/projects/<sanitized-cwd>/chats/).
#
# A spawn marker file eliminates the unrelated-session race: the marker
# is touched immediately before qwen starts, and filesystem discovery
# only adopts chat files newer than the marker.

QWEN_RECEIPTS_NAME="qwen-receipts.jsonl"
QWEN_MARKER_NAME=".qwen-spawn-marker"
QWEN_SID_NAME=".qwen-sid"

qwen_valid_models() {
  local settings="$HOME/.qwen/settings.json"
  if [[ ! -f "$settings" ]]; then printf 'source=none\n'; return 0; fi
  local models
  models="$(jq -r '.modelProviders.openai[]?.id // empty' "$settings" 2>/dev/null)" || {
    printf 'source=none\n'; return 0
  }
  [[ -n "$models" ]] || { printf 'source=none\n'; return 0; }
  printf '%s\n' 'source=settings_json'
  printf '%s\n' "$models" | awk 'NF && !seen[$0]++'
}

# Qwen Code has no surgical MCP-disable flag.  --safe-mode disables MCP
# but also disables context files, hooks, extensions, and skills.
qwen_mcp_policy() {
  local requested="$1" cwd="${2:-$PWD}" state="absent"
  local settings="$HOME/.qwen/settings.json"
  if [[ -f "$settings" ]] && jq -e '.mcpServers | length > 0' "$settings" >/dev/null 2>&1; then
    state="present"
  fi
  case "$requested" in
    inherit) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "qwen MCP configuration inherited from ~/.qwen/settings.json." else "qwen MCP configuration inheritance is provider-controlled; no MCP servers configured." end),argv:[],env:{}}' ;;
    auto) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "qwen MCP auto resolves to inherit: MCP servers are configured in settings.json." else "qwen MCP auto resolves to inherit: qwen has no surgical MCP-disable flag; --safe-mode disables all customizations." end),argv:[],env:{}}' ;;
    none)
      err "qwen: --mcp none is unsupported; qwen has no surgical MCP-disable flag (--safe-mode disables all customizations). Refusing an unverified MCP boundary (config=$state)"
      return 1
      ;;
    *) return 1 ;;
  esac
}

qwen_preflight() {
  command -v qwen >/dev/null 2>&1 || { err "qwen not found on PATH"; return 1; }
  billing_preflight_provider qwen 2>/dev/null || true
  return 0
}

# Discover the Qwen session ID for a lane.
#
# Three-tier fallback chain:
#   1. lane state   — written by the generated script on completion (primary)
#   2. .qwen-sid    — written by the generated script immediately after
#                      extracting the session ID from the stream-json log,
#                      BEFORE lane_set.  Survives crashes between extraction
#                      and state persistence.  Deterministic — no race.
#   3. filesystem   — scans ~/.qwen/projects/<cwd>/chats/ for a single chat
#                      file newer than the spawn marker.  Last resort for
#                      crashes that lose both state and the sid file.  Has a
#                      narrow race window (concurrent same-cwd qwen between
#                      marker touch and chat-file creation).
qwen_discover_session() {
  local lane="$1" sid sid_file cwd marker chats candidates

  # Tier 1: lane state.
  sid="$(lane_get "$lane" session_id)"
  [[ -n "$sid" ]] && { printf '%s\n' "$sid"; return 0; }

  # Tier 2: durable sid file (crash recovery, deterministic).
  sid_file="$(_qwen_sid_file "$lane")"
  if [[ -s "$sid_file" ]]; then
    sid="$(cat "$sid_file")"
    if [[ -n "$sid" ]]; then
      lane_set "$lane" session_id "$sid"
      printf '%s\n' "$sid"
      return 0
    fi
  fi

  # Tier 3: marker-scoped filesystem scan (last resort, narrow race).
  marker="$(lane_dir "$lane")/$QWEN_MARKER_NAME"
  [[ -f "$marker" ]] || return 0

  cwd="$(lane_get "$lane" cwd)"
  chats="$HOME/.qwen/projects/$(_qwen_sanitized_cwd "${cwd:-$PWD}")/chats"
  [[ -d "$chats" ]] || return 0

  candidates="$(find "$chats" -maxdepth 1 -type f -name '*.jsonl' -newer "$marker" 2>/dev/null)"
  [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$candidates")" -eq 1 ]] || return 0
  sid="$(basename "$candidates" .jsonl)"
  lane_set "$lane" session_id "$sid"
  printf '%s\n' "$sid"
}

_qwen_receipt_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$QWEN_RECEIPTS_NAME"; }
_qwen_marker_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$QWEN_MARKER_NAME"; }
_qwen_sid_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$QWEN_SID_NAME"; }

_qwen_receipt() {
  local lane="$1" phase="$2" outcome="$3" rc="$4" sid="$5" started="$6" finished="$7" prompt_kind="$8"
  local file; file="$(_qwen_receipt_file "$lane")"
  mkdir -p "$(dirname "$file")"
  jq -cn --arg lane "$lane" --arg phase "$phase" --arg outcome "$outcome" --arg sid "$sid" \
    --arg kind "$prompt_kind" --argjson rc "${rc:-0}" --argjson started "${started:-0}" --argjson finished "${finished:-0}" \
    '{schema_version:1,provider:"qwen",lane:$lane,phase:$phase,outcome:$outcome,session_id:($sid|if .=="" then null else . end),prompt_kind:$kind,exit_code:$rc,started_epoch:$started,completed_epoch:$finished}' \
    >>"$file"
}

# Sanitize a cwd to the Qwen project directory name (slashes → dashes).
_qwen_sanitized_cwd() { printf '%s' "$1" | sed 's|/|-|g'; }

# Build the shell script evaluated inside the lane-owned tmux process.
#
# The generated script:
#   1. sources core.sh + qwen.sh for receipt/lane helpers
#   2. touches the spawn marker (discovery race boundary)
#   3. writes an invocation receipt
#   4. runs qwen with stream-json output tee'd to a log
#   5. checks PIPESTATUS for both qwen and tee
#   6. extracts the session ID from the log
#   7. writes a completion receipt with the correct outcome
#   8. persists the session ID to lane state
#   9. cleans up the log via an EXIT trap
#
# API keys are NEVER passed via argv; qwen reads them from the inherited
# environment.
_qwen_shell() {
  local lane="$1" model="$2" session_id="$3" prompt="$4" kind="$5"
  shift 5
  local extra=("$@")
  local log adapter core marker
  log="$(lane_dir "$lane")/.qwen-log.$$"
  marker="$(_qwen_marker_file "$lane")"
  adapter="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/providers/qwen.sh"
  core="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/core.sh"
  local argv=(qwen -p "$prompt" --yolo --output-format stream-json)
  [[ -n "$model" ]] && argv+=(--model "$model")
  [[ -n "$session_id" ]] && argv+=(--resume "$session_id")
  argv+=("${extra[@]}")
  local q a; q=""
  for a in "${argv[@]}"; do q+=" $(printf '%q' "$a")"; done

  # Emit the generated script as a readable multi-line string.
  # All dynamic values are injected via %q-escaped variables at the top;
  # the body is a quoted heredoc with no further interpolation.
  printf 'source %q; source %q\n' "$core" "$adapter"
  cat <<'QWEN_SCRIPT'
cleanup_log=""
trap 'rm -f "$cleanup_log"' EXIT
started=$(date +%s)
QWEN_SCRIPT
  printf 'cleanup_log=%q\n' "$log"
  printf '_qwen_receipt %q invocation started 0 "" "$started" "$started" %q\n' "$lane" "$kind"
  printf 'touch %q\n' "$marker"
  cat <<'QWEN_SCRIPT'
set +e
QWEN_SCRIPT
  printf '%s 2>&1 | tee %q\n' "${q# }" "$log"
  cat <<'QWEN_SCRIPT'
pipeline_rc=("${PIPESTATUS[@]}")
set -e
rc=${pipeline_rc[0]}
tee_rc=${pipeline_rc[1]}
sid=$(jq -r 'select(.type=="system" and .subtype=="session_start") | .session_id // empty' "$cleanup_log" 2>/dev/null | head -1 || true)
outcome=failed
if [[ "$rc" -eq 0 && "$tee_rc" -ne 0 ]]; then
  rc="$tee_rc"
elif [[ "$rc" -eq 0 && -z "$sid" ]]; then
  rc=1; outcome=no_session
elif [[ "$rc" -eq 0 ]]; then
  outcome=succeeded
fi
finished=$(date +%s)
QWEN_SCRIPT
  printf '_qwen_receipt %q completion "$outcome" "$rc" "$sid" "$started" "$finished" %q\n' "$lane" "$kind"
  # Persist the session ID to a durable file BEFORE lane_set.  If the
  # process crashes between here and lane_set, tier-2 discovery recovers
  # the ID deterministically (no filesystem race).
  printf 'if [[ -n "$sid" ]]; then printf "%%s" "$sid" > %q; fi\n' "$(_qwen_sid_file "$lane")"
  printf 'if [[ -n "$sid" ]]; then lane_set %q session_id "$sid"; fi\n' "$lane"
  printf 'exit "$rc"\n'
}

qwen_validate_model_effort() {
  local _model="${1:-}" effort="${2:-}"
  if [[ -n "$effort" ]]; then
    err "qwen: --effort is unsupported by Qwen Code"
    return 1
  fi
}

qwen_spawn() {
  local lane="$1" cwd="$2" model="$3" _provided_sid="$4" transcript="$5" prompt="$6"; shift 6
  local receipt_file i owned attempts
  receipt_file="$(_qwen_receipt_file "$lane")"
  : >"$receipt_file"
  qwen_validate_model_effort "$model" "$(lane_get "$lane" effort)" || return 1
  local cmd; cmd="$(_qwen_shell "$lane" "$model" "" "$prompt" spawn "$@")"
  local target; target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc $(printf '%q' "$cmd")")" || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true
  attempts="${WASPFLOW_SUBMIT_ATTEMPTS:-20}"
  for i in $(seq 1 "$attempts"); do
    if [[ -s "$receipt_file" ]] && jq -e 'select(.phase == "invocation" and .prompt_kind == "spawn" and .outcome == "started")' "$receipt_file" >/dev/null 2>&1; then
      return 0
    fi
    owned=false
    tmux_owned_lane_window_exists "$lane" >/dev/null 2>&1 && owned=true
    [[ "$owned" == true ]] || break
    sleep 1
  done
  err "qwen spawn: submission receipt did not appear for lane '$lane'"
  return 1
}

qwen_session_resumable() {
  local lane="$1" sid; sid="$(qwen_discover_session "$lane")"
  [[ -n "$sid" ]] || return 1
  local cwd; cwd="$(lane_get "$lane" cwd)"
  local sanitized; sanitized="$(_qwen_sanitized_cwd "${cwd:-$PWD}")"
  [[ -f "$HOME/.qwen/projects/$sanitized/chats/${sid}.jsonl" ]] || return 1
  jq -e --arg s "$sid" 'select(.phase=="completion" and .outcome=="succeeded" and .session_id==$s)' "$(_qwen_receipt_file "$lane")" >/dev/null 2>&1
}

qwen_is_idle() {
  local lane="$1" file; file="$(_qwen_receipt_file "$lane")"
  [[ -s "$file" ]] || return 1
  [[ "$(tail -n 1 "$file" | jq -r 'select(.phase=="completion") | .outcome' 2>/dev/null)" =~ ^(succeeded|failed|no_session)$ ]]
}

qwen_turn_mark() { local f; f="$(_qwen_receipt_file "$1")"; jq -r 'select(.phase=="completion" and .outcome=="succeeded") | 1' "$f" 2>/dev/null | wc -l; }

qwen_revise() {
  local lane="$1" message="$2" out_file="${3:-}" sid model cwd cmd
  sid="$(qwen_discover_session "$lane")"; [[ -n "$sid" ]] || { err "qwen: no resumable session for lane '$lane'"; return 1; }
  qwen_session_resumable "$lane" || { err "qwen: session '$sid' is not resumable (no successful completion)"; return 1; }
  model="$(lane_get "$lane" model)"; cwd="$(lane_get "$lane" cwd)"
  qwen_validate_model_effort "$model" "$(lane_get "$lane" effort)" || return 1
  cmd="$(_qwen_shell "$lane" "$model" "$sid" "$message" revise)"
  if [[ -n "$out_file" ]]; then
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- bash -lc "$cmd" </dev/null >"$out_file"
  else
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- bash -lc "$cmd" </dev/null
  fi
}

# Qwen cannot accept a caller-minted session ID, so it cannot participate in
# the escalation state machine's provisional ownership protocol.
qwen_resume_with_arm() { err "qwen: escalation hooks are unsupported by Qwen Code"; return 1; }
qwen_confirm_escalation_submission() { err "qwen: escalation confirmation is unsupported by Qwen Code"; return 1; }

# Read the model from the last assistant message in the session JSONL.
# Guard large logs with timeout; only read typed top-level fields via jq.
qwen_refresh_runtime_settings() {
  local lane="$1" sid cwd sanitized session_file observed_model
  sid="$(qwen_discover_session "$lane")"
  [[ -n "$sid" ]] || return 0
  cwd="$(lane_get "$lane" cwd)"
  sanitized="$(_qwen_sanitized_cwd "${cwd:-$PWD}")"
  session_file="$HOME/.qwen/projects/$sanitized/chats/${sid}.jsonl"
  [[ -f "$session_file" ]] || return 0
  observed_model="$(timeout 5 jq -r 'select(.type=="assistant") | .model // empty' "$session_file" 2>/dev/null | tail -1)" || return 0
  [[ -n "$observed_model" ]] || return 0
  lane_set "$lane" runtime_model "$observed_model"
}
