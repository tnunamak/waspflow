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
  # A crash must not glue a later valid JSON object onto a torn final record.
  [[ ! -s "$WASPFLOW_PROVENANCE_LEDGER" || "$(tail -c1 "$WASPFLOW_PROVENANCE_LEDGER" 2>/dev/null)" == "" ]] \
    || printf '\n' >>"$WASPFLOW_PROVENANCE_LEDGER"
  PROVENANCE_INSTANCE_ID="$instance"
}

_provenance_event_exists_locked() {
  local event_id="$1"
  jq -e --arg id "$event_id" 'select(.event_id == $id)' "$WASPFLOW_PROVENANCE_LEDGER" >/dev/null 2>&1
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
  if [[ "$rc" -eq 0 ]] && ! _provenance_event_exists_locked "$event_id"; then
    printf '%s\n' "$payload" >>"$WASPFLOW_PROVENANCE_LEDGER" || rc=$?
  fi
  flock -u "$fd" || true
  exec {fd}>&-
  return "$rc"
}

provenance_emit_lane_started() {
  local lane="$1" event_id provider lane_uuid parent_ref prompt_hash instance payload
  event_id="$(lane_get "$lane" provenance_lane_started_event_id)"
  if [[ -z "$event_id" ]]; then
    event_id="$(new_uuid)" || return 1
    lane_set "$lane" provenance_lane_started_event_id "$event_id"
  fi
  provider="$(lane_get "$lane" provider)"
  lane_uuid="$(lane_get "$lane" lane_uuid)"
  parent_ref="$(lane_get "$lane" provenance_parent_ref)"
  prompt_hash="$(_provenance_sha256 "$(lane_get "$lane" prompt)" 2>/dev/null || true)"
  instance="$(provenance_instance_id)" || return 1
  payload="$(jq -cn \
    --arg event_id "$event_id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lane_uuid "$lane_uuid" --arg lane "$lane" --arg provider "$provider" \
    --arg parent_ref "$parent_ref" --arg task_hash "$prompt_hash" --arg instance "$instance" '
      {schema:"agent-provenance/v1",schema_version:1,event_id:$event_id,event_type:"lane_started",observed_at:$at,
       producer:{name:"waspflow",instance_id:$instance},
       lane:{id:$lane_uuid,label:$lane,provider:$provider},
       parent:(if $parent_ref == "" then {ref:null,evidence_class:"absent"} else {ref:$parent_ref,evidence_class:"caller_asserted"} end),
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
    event_id="$(new_uuid)" || return 1
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
