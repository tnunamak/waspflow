#!/usr/bin/env bash
# qwen.sh - waspflow adapter for Qwen Code (qwen CLI).
#
# Qwen Code is treated as an opaque headless process, following the
# antigravity pattern.  Each `qwen -p ... --yolo` invocation is one-shot
# and exits when done.  Lifecycle truth lives in the Waspflow-owned
# receipt JSONL; Qwen's internal session logs are used only for session
# ID discovery and runtime attestation.
#
# Session IDs cannot be pre-minted (no --session-id flag).  Qwen assigns
# its own UUID, discovered from the stream-json session_start event or
# from the filesystem (~/.qwen/projects/<sanitized-cwd>/chats/).

QWEN_RECEIPTS_NAME="qwen-receipts.jsonl"

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

qwen_discover_session() {
  local lane="$1" sid cwd started chats candidates
  sid="$(lane_get "$lane" session_id)"
  [[ -n "$sid" ]] && { printf '%s\n' "$sid"; return 0; }

  cwd="$(lane_get "$lane" cwd)"
  chats="$HOME/.qwen/projects/$(_qwen_sanitized_cwd "${cwd:-$PWD}")/chats"
  started="$(jq -r 'select(.phase=="invocation") | .started_epoch' "$(_qwen_receipt_file "$lane")" 2>/dev/null | tail -1)"
  [[ "$started" =~ ^[0-9]+$ && -d "$chats" ]] || return 0
  candidates="$(
    find "$chats" -maxdepth 1 -type f -name '*.jsonl' -newermt "@$((started - 1))" -printf '%T@\t%f\n' 2>/dev/null \
      | sort -rn | cut -f2-
  )"
  [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$candidates")" -eq 1 ]] || return 0
  sid="${candidates%.jsonl}"
  lane_set "$lane" session_id "$sid"
  printf '%s\n' "$sid"
}

_qwen_receipt_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$QWEN_RECEIPTS_NAME"; }

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

# Build the shell command evaluated inside the lane-owned tmux process.
# Stream-json output is tee'd to a log file for session ID discovery.
# API keys are NEVER passed via argv; qwen reads them from the inherited
# environment.
_qwen_shell() {
  local lane="$1" model="$2" session_id="$3" prompt="$4" kind="$5"
  shift 5
  local extra=("$@")
  local log adapter core
  log="$(lane_dir "$lane")/.qwen-log.$$"
  adapter="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/providers/qwen.sh"
  core="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/core.sh"
  local argv=(qwen -p "$prompt" --yolo --output-format stream-json)
  [[ -n "$model" ]] && argv+=(--model "$model")
  [[ -n "$session_id" ]] && argv+=(--resume "$session_id")
  argv+=("${extra[@]}")
  local q a; q=""
  for a in "${argv[@]}"; do q+=" $(printf '%q' "$a")"; done
  printf 'source %q; source %q; cleanup_log=%q; trap '\''rm -f "$cleanup_log"'\'' EXIT; started=$(date +%%s); _qwen_receipt %q invocation started 0 "" "$started" "$started" %q; set +e; %s 2>&1 | tee %q; pipeline_rc=("${PIPESTATUS[@]}"); set -e; rc=${pipeline_rc[0]}; tee_rc=${pipeline_rc[1]}; sid=$(jq -r '\''select(.type=="system" and .subtype=="session_start") | .session_id // empty'\'' %q 2>/dev/null | head -1 || true); outcome=failed; if [[ "$rc" -eq 0 && "$tee_rc" -ne 0 ]]; then rc="$tee_rc"; elif [[ "$rc" -eq 0 && -z "$sid" ]]; then rc=1; outcome=no_session; elif [[ "$rc" -eq 0 ]]; then outcome=succeeded; fi; finished=$(date +%%s); _qwen_receipt %q completion "$outcome" "$rc" "$sid" "$started" "$finished" %q; if [[ -n "$sid" ]]; then lane_set %q session_id "$sid"; fi; exit "$rc"' \
    "$core" "$adapter" "$log" "$lane" "$kind" "${q# }" "$log" "$log" "$lane" "$kind" "$lane"
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
