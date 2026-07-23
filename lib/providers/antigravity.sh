#!/usr/bin/env bash
# antigravity.sh - waspflow adapter for agy 1.1.5.
#
# agy is deliberately treated as an opaque headless process.  Its private log
# is used only to discover the conversation UUID and is removed immediately;
# lifecycle truth lives in the Waspflow-owned receipt JSONL.

ANTIGRAVITY_RECEIPTS_NAME="antigravity-receipts.jsonl"

antigravity_valid_models() {
  local models
  command -v agy >/dev/null 2>&1 || { printf 'source=none\n'; return 0; }
  models="$(agy models 2>/dev/null)" || { printf 'source=none\n'; return 0; }
  [[ -n "$models" ]] || { printf 'source=none\n'; return 0; }
  printf '%s\n' 'source=live_query'
  printf '%s\n' "$models" | sed 's/[[:space:]]*$//' | awk 'NF && !seen[$0]++'
}

# agy 1.1.5 has no MCP-disable flag in its supported headless contract.
# Inspect the conventional config locations so the warning describes the
# discovered state, but never claim that --mcp none was enforced.
antigravity_mcp_policy() {
  local requested="$1" cwd="${2:-$PWD}" config="" state="absent"
  for config in "${AGY_CONFIG_FILE:-}" "$cwd/.gemini/antigravity/mcp_config.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/antigravity/mcp_config.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/gemini/antigravity/mcp_config.json" \
    "$HOME/.gemini/antigravity/mcp_config.json"; do
    [[ -n "$config" && -f "$config" ]] || continue
    state="present"
    break
  done
  case "$requested" in
    inherit) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "agy MCP configuration inherited from local config." else "agy MCP configuration inheritance is provider-controlled; no local config was found." end),argv:[],env:{}}' ;;
    auto) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "agy MCP auto resolves to inherit: local MCP configuration is active." else "agy MCP auto resolves to inherit: agy 1.1.5 exposes no verified MCP-minimal mode." end),argv:[],env:{}}' ;;
    none)
      err "antigravity: --mcp none is unsupported by agy 1.1.5; refusing an unverified MCP boundary (config=$state)"
      return 1
      ;;
    *) return 1 ;;
  esac
}

antigravity_preflight() {
  command -v agy >/dev/null 2>&1 || { err "agy not found on PATH"; return 1; }
  billing_preflight_provider antigravity 2>/dev/null || true
  return 0
}

antigravity_discover_session() { lane_get "$1" session_id; }

_antigravity_receipt_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$ANTIGRAVITY_RECEIPTS_NAME"; }

_antigravity_receipt() {
  local lane="$1" phase="$2" outcome="$3" rc="$4" sid="$5" started="$6" finished="$7" prompt_kind="$8"
  local file; file="$(_antigravity_receipt_file "$lane")"
  mkdir -p "$(dirname "$file")"
  jq -cn --arg lane "$lane" --arg phase "$phase" --arg outcome "$outcome" --arg sid "$sid" \
    --arg kind "$prompt_kind" --argjson rc "${rc:-0}" --argjson started "${started:-0}" --argjson finished "${finished:-0}" \
    '{schema_version:1,provider:"antigravity",lane:$lane,phase:$phase,outcome:$outcome,session_id:($sid|if .=="" then null else . end),prompt_kind:$kind,exit_code:$rc,started_epoch:$started,completed_epoch:$finished}' \
    >>"$file"
}

# This command is evaluated inside the lane-owned tmux process.  The raw log
# never enters a receipt or transcript and is removed on every normal path.
_antigravity_shell() {
  local lane="$1" model="$2" effort="$3" conversation="$4" prompt="$5" kind="$6"; shift 6
  local log adapter core; log="$(lane_dir "$lane")/.agy-log.$$"
  adapter="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/providers/antigravity.sh"
  core="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/core.sh"
  local argv=(agy --print "$prompt")
  [[ -n "$conversation" ]] && argv+=(--conversation "$conversation")
  [[ -n "$model" ]] && argv+=(--model "$model")
  [[ -n "$effort" ]] && argv+=(--effort "$effort")
  argv+=(--mode accept-edits --dangerously-skip-permissions --log-file "$log")
  local q a; q=""
  for a in "${argv[@]}"; do q+=" $(printf '%q' "$a")"; done
  printf 'source %q; source %q; trap '\''rm -f %q'\'' EXIT; started=$(date +%%s); _antigravity_receipt %q invocation started 0 "" "$started" "$started" %q; set +e; %s; rc=$?; set -e; sid=$(grep -aEio "Created conversation[[:space:]]+[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}" %q 2>/dev/null | grep -Eo "[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}" | tail -1 || true); [ -n "$sid" ] || sid=%q; finished=$(date +%%s); outcome=failed; if [[ "$rc" -eq 0 && -n "$sid" ]]; then outcome=succeeded; fi; _antigravity_receipt %q completion "$outcome" "$rc" "$sid" "$started" "$finished" %q; if [[ -n "$sid" ]]; then lane_set %q session_id "$sid"; fi; exit "$rc"' \
    "$core" "$adapter" "$log" "$lane" "$kind" "${q# }" "$log" "$conversation" "$lane" "$kind" "$lane"
}

_antigravity_effort_args() {
  case "${1:-}" in "") ;; low|medium|high) ;; *) err "antigravity: unsupported effort '$1' (use low|medium|high)"; return 1 ;; esac
}

antigravity_validate_model_effort() {
  local model="${1:-}" effort="${2:-}" encoded=""
  [[ "$model" =~ -(low|medium|high)$ ]] && encoded="${BASH_REMATCH[1]}"
  if [[ -n "$encoded" && -n "$effort" && "$encoded" != "$effort" ]]; then
    err "antigravity: model '$model' encodes effort '$encoded' and conflicts with --effort '$effort'"
    return 1
  fi
}

antigravity_spawn() {
  local lane="$1" cwd="$2" model="$3" _provided_sid="$4" transcript="$5" prompt="$6"; shift 6
  local effort attempts receipt_file i owned
  effort="$(lane_get "$lane" effort)"; _antigravity_effort_args "$effort" || return 1
  antigravity_validate_model_effort "$model" "$effort" || return 1
  receipt_file="$(_antigravity_receipt_file "$lane")"
  : >"$receipt_file"
  local cmd; cmd="$(_antigravity_shell "$lane" "$model" "$effort" "" "$prompt" spawn)"
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
  err "antigravity spawn: agy submission receipt did not appear for lane '$lane'"
  return 1
}

antigravity_session_resumable() {
  local lane="$1" sid; sid="$(antigravity_discover_session "$lane")"
  [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || return 1
  jq -e --arg s "$sid" 'select(.phase=="completion" and .outcome=="succeeded" and .session_id==$s)' "$(_antigravity_receipt_file "$lane")" >/dev/null 2>&1
}

antigravity_is_idle() {
  local lane="$1" file; file="$(_antigravity_receipt_file "$lane")"
  [[ -s "$file" ]] || return 1
  [[ "$(tail -n 1 "$file" | jq -r 'select(.phase=="completion") | .outcome' 2>/dev/null)" =~ ^(succeeded|failed)$ ]]
}

antigravity_turn_mark() { local f; f="$(_antigravity_receipt_file "$1")"; jq -r 'select(.phase=="completion" and .outcome=="succeeded") | 1' "$f" 2>/dev/null | wc -l; }

antigravity_revise() {
  local lane="$1" message="$2" out_file="${3:-}" sid model cwd effort cmd
  sid="$(antigravity_discover_session "$lane")"; [[ -n "$sid" ]] || { err "antigravity: no resumable session for lane '$lane'"; return 1; }
  model="$(lane_get "$lane" model)"; cwd="$(lane_get "$lane" cwd)"; effort="$(lane_get "$lane" effort)"; _antigravity_effort_args "$effort" || return 1
  antigravity_validate_model_effort "$model" "$effort" || return 1
  cmd="$(_antigravity_shell "$lane" "$model" "$effort" "$sid" "$message" revise)"
  if [[ -n "$out_file" ]]; then
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- bash -lc "$cmd" </dev/null >"$out_file"
  else
    tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- bash -lc "$cmd" </dev/null
  fi
}

# agy has no documented escalation/resume hook distinct from conversation
# resume. The core must fail explicitly rather than treating this as supported.
antigravity_resume_with_arm() { err "antigravity: escalation hooks are unsupported by agy 1.1.5"; return 1; }
antigravity_confirm_escalation_submission() { err "antigravity: escalation confirmation is unsupported by agy 1.1.5"; return 1; }
