#!/usr/bin/env bash
#
# provenance.sh — append-only, producer-neutral lane provenance receipts.
#
# This is deliberately a small interchange boundary. Waspflow writes local
# evidence; consumers may import agent-provenance/v1 without linking to this
# repository, tmux, or a particular session ledger.

WASPFLOW_PROVENANCE_LEDGER="${WASPFLOW_PROVENANCE_LEDGER:-$WASPFLOW_HOME/provenance.jsonl}"
WASPFLOW_PROVENANCE_INSTANCE_FILE="${WASPFLOW_PROVENANCE_INSTANCE_FILE:-$WASPFLOW_HOME/provenance-instance-id}"

provenance_validate_parent_ref() {
  local ref="$1"
  [[ ${#ref} -le 4096 ]] || { err "spawn: --parent-ref is too long (max 4096 characters)"; return 1; }
  [[ "$ref" != *$'\n'* && "$ref" != *$'\r'* ]] \
    || { err "spawn: --parent-ref cannot contain newlines"; return 1; }
}

provenance_valid_codex_thread_id() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# Set a parent context only from a caller assertion or the one harness-owned
# environment identity we can validate. This is capture at the launch boundary,
# not reconstruction from process, terminal, or timing heuristics.
provenance_resolve_parent_context() {
  local explicit_ref="$1" environment_ref="$2" codex_thread_id="$3"
  PROVENANCE_PARENT_REF=""
  PROVENANCE_PARENT_EVIDENCE_CLASS="absent"
  if [[ -n "$explicit_ref" ]]; then
    PROVENANCE_PARENT_REF="$explicit_ref"
    PROVENANCE_PARENT_EVIDENCE_CLASS="caller_asserted"
  elif [[ -n "$environment_ref" ]]; then
    PROVENANCE_PARENT_REF="$environment_ref"
    PROVENANCE_PARENT_EVIDENCE_CLASS="caller_asserted"
  elif [[ -n "$codex_thread_id" ]] && provenance_valid_codex_thread_id "$codex_thread_id"; then
    PROVENANCE_PARENT_REF="codex:$codex_thread_id"
    PROVENANCE_PARENT_EVIDENCE_CLASS="observed_harness_env"
  fi
}

_provenance_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# Creates the one per-state-home producer identity under the same lock used for
# event append. The ID is not an authentication mechanism; local filesystem
# ownership is the integrity boundary for these receipts.
_provenance_prepare_locked() {
  mkdir -p -m 700 "$WASPFLOW_HOME" "$WASPFLOW_LOCKS_DIR" || return 1
  chmod 700 "$WASPFLOW_HOME" "$WASPFLOW_LOCKS_DIR" 2>/dev/null || true
  [[ ! -L "$WASPFLOW_PROVENANCE_LEDGER" && ! -L "$WASPFLOW_PROVENANCE_INSTANCE_FILE" ]] || {
    err "provenance: refusing symlinked ledger or instance identity"
    return 1
  }
  if [[ ! -s "$WASPFLOW_PROVENANCE_INSTANCE_FILE" ]]; then
    local instance tmp
    instance="$(new_uuid)" || return 1
    tmp="$(mktemp "$WASPFLOW_HOME/.provenance-instance.XXXXXX")" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    printf '%s\n' "$instance" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$WASPFLOW_PROVENANCE_INSTANCE_FILE" || { rm -f "$tmp"; return 1; }
  fi
  chmod 600 "$WASPFLOW_PROVENANCE_INSTANCE_FILE" 2>/dev/null || true
  local instance
  instance="$(cat "$WASPFLOW_PROVENANCE_INSTANCE_FILE" 2>/dev/null)"
  [[ "$instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    err "provenance: instance identity is invalid"
    return 1
  }
  touch "$WASPFLOW_PROVENANCE_LEDGER" || return 1
  chmod 600 "$WASPFLOW_PROVENANCE_LEDGER" 2>/dev/null || true
  PROVENANCE_INSTANCE_ID="$instance"
}

_provenance_repair_torn_tail_locked() {
  local line="" line_no=0 last_line=0 bad_line=0 last_byte tmp
  [[ -s "$WASPFLOW_PROVENANCE_LEDGER" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1)); last_line=$line_no
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line" || [[ "$bad_line" -ne 0 ]] || bad_line=$line_no
  done <"$WASPFLOW_PROVENANCE_LEDGER"
  last_byte="$(tail -c 1 "$WASPFLOW_PROVENANCE_LEDGER" | od -An -tx1 | tr -d '[:space:]')"
  if [[ "$bad_line" -eq 0 ]]; then
    # A complete final object can lose only its trailing newline in a crash.
    # Preserve that evidence and restore the JSONL record boundary.
    [[ "$last_byte" == 0a ]] || printf '\n' >>"$WASPFLOW_PROVENANCE_LEDGER"
    return 0
  fi
  if [[ "$bad_line" -eq "$last_line" && "$last_byte" != 0a ]]; then
    tmp="$(mktemp "$(dirname "$WASPFLOW_PROVENANCE_LEDGER")/.provenance-ledger.XXXXXX")" || return 1
    head -n -1 "$WASPFLOW_PROVENANCE_LEDGER" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$WASPFLOW_PROVENANCE_LEDGER" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  err "provenance: refusing to append; ledger has corrupt JSON before its final torn fragment"
  return 1
}

_provenance_event_exists_locked() {
  local event_id="$1" rc=0
  jq -e --arg id "$event_id" 'select(.event_id == $id)' "$WASPFLOW_PROVENANCE_LEDGER" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) return 0 ;; 4) return 1 ;; *) return 2 ;; esac
}

provenance_instance_id() {
  local fd instance rc=0
  command -v flock >/dev/null 2>&1 || { err "provenance: flock is required"; return 1; }
  mkdir -p -m 700 "$WASPFLOW_LOCKS_DIR" || return 1
  exec {fd}>"$WASPFLOW_LOCKS_DIR/provenance.lock" || return 1
  flock -x "$fd" || { exec {fd}>&-; return 1; }
  _provenance_prepare_locked || rc=$?
  instance="${PROVENANCE_INSTANCE_ID:-}"
  flock -u "$fd" || true
  exec {fd}>&-
  [[ "$rc" -eq 0 ]] || return "$rc"
  printf '%s\n' "$instance"
}

_provenance_append() {
  local event_id="$1" payload="$2" fd
  command -v flock >/dev/null 2>&1 || { err "provenance: flock is required"; return 1; }
  mkdir -p -m 700 "$WASPFLOW_LOCKS_DIR" || return 1
  exec {fd}>"$WASPFLOW_LOCKS_DIR/provenance.lock" || return 1
  flock -x "$fd" || { exec {fd}>&-; return 1; }
  local rc=0
  _provenance_prepare_locked || rc=$?
  [[ "$rc" -ne 0 ]] || _provenance_repair_torn_tail_locked || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    local exists_rc=0
    _provenance_event_exists_locked "$event_id" || exists_rc=$?
    case "$exists_rc" in
      0) ;;
      1) printf '%s\n' "$payload" >>"$WASPFLOW_PROVENANCE_LEDGER" || rc=$? ;;
      *) err "provenance: cannot determine whether event '$event_id' already exists"; rc=1 ;;
    esac
  fi
  flock -u "$fd" || true
  exec {fd}>&-
  return "$rc"
}

_provenance_event_id() {
  local lane="$1" kind="$2" lane_uuid
  lane_uuid="$(lane_get "$lane" lane_uuid)"
  [[ -n "$lane_uuid" ]] || return 1
  printf 'waspflow:%s:%s\n' "$lane_uuid" "$kind"
}

provenance_enabled() {
  [[ "$(lane_get "$1" provenance_version)" == "1" ]]
}

provenance_emit_lane_started() {
  local lane="$1" event_id provider lane_uuid parent_ref parent_evidence_class prompt_hash instance payload
  event_id="$(lane_get "$lane" provenance_lane_started_event_id)"
  if [[ -z "$event_id" ]]; then
    event_id="$(_provenance_event_id "$lane" lane_started)" || return 1
    lane_set "$lane" provenance_lane_started_event_id "$event_id"
  fi
  provider="$(lane_get "$lane" provider)"
  lane_uuid="$(lane_get "$lane" lane_uuid)"
  parent_ref="$(lane_get "$lane" provenance_parent_ref)"
  parent_evidence_class="$(lane_get "$lane" provenance_parent_evidence_class)"
  [[ -n "$parent_evidence_class" ]] || parent_evidence_class="absent"
  prompt_hash="$(_provenance_sha256 "$(lane_get "$lane" prompt)" 2>/dev/null || true)"
  instance="$(provenance_instance_id)" || return 1
  payload="$(jq -cn \
    --arg event_id "$event_id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lane_uuid "$lane_uuid" --arg lane "$lane" --arg provider "$provider" \
    --arg parent_ref "$parent_ref" --arg parent_evidence_class "$parent_evidence_class" --arg task_hash "$prompt_hash" --arg instance "$instance" '
      {schema:"agent-provenance/v1",schema_version:1,event_id:$event_id,event_type:"lane_started",observed_at:$at,
       producer:{name:"waspflow",instance_id:$instance},
       lane:{id:$lane_uuid,label:$lane,provider:$provider},
       parent:{ref:(if $parent_ref == "" then null else $parent_ref end),evidence_class:$parent_evidence_class},
       evidence:{class:"observed",method:"waspflow_confirmed_submission",task_fingerprint:(if $task_hash == "" then null else "sha256:" + $task_hash end)}}')" || return 1
  _provenance_append "$event_id" "$payload" || return 1
  lane_set "$lane" provenance_lane_started_emitted "true"
}

provenance_emit_worker_session_bound() {
  local lane="$1" session_id event_id provider lane_uuid marker_hash instance payload
  session_id="$(lane_get "$lane" session_id)"
  [[ -n "$session_id" ]] || return 0
  event_id="$(lane_get "$lane" provenance_worker_bound_event_id)"
  if [[ -z "$event_id" ]]; then
    event_id="$(_provenance_event_id "$lane" worker_session_bound)" || return 1
    lane_set "$lane" provenance_worker_bound_event_id "$event_id"
  fi
  provider="$(lane_get "$lane" provider)"
  lane_uuid="$(lane_get "$lane" lane_uuid)"
  marker_hash="$(_provenance_sha256 "$(lane_get "$lane" codex_marker)" 2>/dev/null || true)"
  instance="$(provenance_instance_id)" || return 1
  payload="$(jq -cn \
    --arg event_id "$event_id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lane_uuid "$lane_uuid" --arg lane "$lane" --arg provider "$provider" \
    --arg session_id "$session_id" --arg marker_hash "$marker_hash" --arg instance "$instance" '
      {schema:"agent-provenance/v1",schema_version:1,event_id:$event_id,event_type:"worker_session_bound",observed_at:$at,
       producer:{name:"waspflow",instance_id:$instance},
       lane:{id:$lane_uuid,label:$lane,provider:$provider},
       worker:{kind:"agent_session",harness:$provider,native_session_id:$session_id},
       evidence:{class:"observed",method:"provider_session_binding",correlation_digest:(if $marker_hash == "" then null else "sha256:" + $marker_hash end)}}')" || return 1
  _provenance_append "$event_id" "$payload" || return 1
  lane_set "$lane" provenance_worker_bound_emitted "true"
}

provenance_reconcile_lane() {
  local lane="$1" session_id
  provenance_enabled "$lane" || return 0
  if [[ "$(lane_get "$lane" provenance_lane_started_emitted)" != true ]]; then
    if ! provenance_emit_lane_started "$lane"; then
      lane_set "$lane" provenance_state "launch_event_failed"
      return 1
    fi
  fi
  if [[ "$(lane_get "$lane" provenance_worker_bound_emitted)" == true ]]; then
    lane_set "$lane" provenance_state "recorded"
    return 0
  fi
  session_id="$(lane_get "$lane" session_id)"
  if [[ -z "$session_id" ]]; then
    lane_set "$lane" provenance_state "waiting_for_worker_session"
    if [[ "$(lane_get "$lane" provenance_worker_bound_emitted)" == true ]]; then
      lane_set "$lane" provenance_state "recorded"
    elif [[ -n "$(lane_get "$lane" session_id)" ]]; then
      provenance_reconcile_lane "$lane" || return 1
    fi
    return 0
  fi
  if ! provenance_emit_worker_session_bound "$lane"; then
    lane_set "$lane" provenance_state "worker_binding_failed"
    return 1
  fi
  lane_set "$lane" provenance_state "recorded"
}
