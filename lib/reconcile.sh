#!/usr/bin/env bash
#
# reconcile.sh — conservative, read-only fleet reconstruction from durable facts.
#
# A lane record is evidence, not authority to recreate a worker.  This module
# only joins bounded local observations with that evidence.  The one mutating
# action, explicit owner adoption, is deliberately separate and lock-protected.

source "$WASPFLOW_LIB/events.sh"

_reconcile_pid_start_time() {
  local pid="$1" stat
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  # Field 22 is starttime; comm may contain spaces, so discard through ') '.
  stat="${stat#*) }"
  awk '{print $20}' <<<"$stat"
}

reconcile_event_ledger() { printf '%s\n' "${WASPFLOW_EVENT_LEDGER:-$WASPFLOW_HOME/events.jsonl}"; }
reconcile_event_claims() { printf '%s\n' "${WASPFLOW_EVENT_CLAIMS:-$WASPFLOW_HOME/event-claims.json}"; }

# A small read-only doctor surface. It intentionally observes only persisted
# state and owned tmux identities; it never opens provider logs or starts work.
reconcile_fleet_health_json() {
  local active_scopes='[]' scopes_ok=true lane record record_status window unknown=0 orphaned=0
  local -a samples=()
  if ! active_scopes="$(waspflow_active_scope_snapshot 2>/dev/null)"; then scopes_ok=false; fi
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    record="$(jq -c . "$(lane_state_file "$lane")" 2>/dev/null || true)"
    if [[ -z "$record" ]]; then unknown=$((unknown + 1)); samples+=("$lane"); continue; fi
    record_status="$(jq -r '.status // ""' <<<"$record")"
    window=false; tmux_owned_lane_window_exists "$lane" && window=true
    if [[ "$record_status" == live && "$window" != true ]]; then orphaned=$((orphaned + 1)); samples+=("$lane")
    elif [[ "$(waspflow_derived_lane_lifecycle "$record" "$active_scopes" "$scopes_ok")" == unknown ]]; then unknown=$((unknown + 1)); samples+=("$lane")
    fi
  done < <(list_lanes)
  jq -cn --argjson unknown "$unknown" --argjson orphaned "$orphaned" --argjson samples "$(printf '%s\n' "${samples[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{unknown:$unknown,orphaned:$orphaned,samples:$samples}'
}

# Append a redacted delivery obligation. Event ids include the generation, so a
# revised turn cannot acknowledge a previous turn's obligation.
reconcile_event_emit() (
  local lane="$1" generation="$2" kind="$3" event_id="${4:-}" ledger fd payload absent
  [[ -n "$lane" && "$generation" =~ ^[0-9]+$ && "$kind" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  event_id="${event_id:-$(printf '%s' "$lane|$generation|$kind" | sha256sum | awk '{print substr($1,1,32)}')}"
  ledger="$(reconcile_event_ledger)"; mkdir -p -m 700 "$WASPFLOW_HOME" "$WASPFLOW_LOCKS_DIR" || return 1
  exec {fd}>"$WASPFLOW_LOCKS_DIR/events.lock" || return 1; flock -x "$fd" || return 1
  touch "$ledger" || { flock -u "$fd"; exec {fd}>&-; return 1; }
  absent="$(jq -sr --arg id "$event_id" '[.[] | select(.event_id == $id)] | length == 0' "$ledger")" || return 1
  if [[ "$absent" == true ]]; then
    payload="$(jq -cn --arg id "$event_id" --arg lane "$lane" --arg kind "$kind" --argjson generation "$generation" \
      '{schema:"waspflow-owner-event/v1",event_id:$id,lane:$lane,generation:$generation,kind:$kind,state:"pending",created_epoch:now}')" || return 1
    printf '%s\n' "$payload" >>"$ledger" || return 1
  fi
  printf '%s\n' "$event_id"
)

# Claim and acknowledgement state is separate from immutable event evidence.
# Leases make a crashed consumer recoverable without permitting two live claims.
reconcile_event_claim() (
  local event_id="$1" consumer="$2" lease_seconds="${3:-60}" claims fd now result
  [[ -n "$event_id" && -n "$consumer" && "$lease_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
  claims="$(reconcile_event_claims)"; mkdir -p -m 700 "$WASPFLOW_HOME" "$WASPFLOW_LOCKS_DIR" || return 1
  exec {fd}>"$WASPFLOW_LOCKS_DIR/events.lock" || return 1; flock -x "$fd" || return 1
  [[ -f "$claims" ]] || printf '{}\n' >"$claims"
  now="$(date +%s)"
  result="$(jq -c --arg id "$event_id" --arg consumer "$consumer" --argjson now "$now" --argjson lease "$lease_seconds" '
    .[$id] as $old | if ($old.acked // false) then {ok:false,reason:"acknowledged"}
    elif (($old.lease_until // 0) > $now and ($old.consumer // "") != $consumer) then {ok:false,reason:"claimed"}
    else {ok:true,claim:{consumer:$consumer,lease_until:($now + $lease),acked:false}} end' "$claims")" || return 1
  if [[ "$(jq -r '.ok' <<<"$result")" == true ]]; then
    local tmp; tmp="$(mktemp "$WASPFLOW_HOME/.event-claims.XXXXXX")" || return 1
    jq --arg id "$event_id" --argjson claim "$(jq -c '.claim' <<<"$result")" '.[$id] = $claim' "$claims" >"$tmp" && mv "$tmp" "$claims" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$result"
)

reconcile_event_ack() (
  local event_id="$1" consumer="$2" claims ledger fd tmp lane generation latest
  claims="$(reconcile_event_claims)"; [[ -f "$claims" ]] || return 1
  ledger="$(reconcile_event_ledger)"; [[ -f "$ledger" ]] || return 1
  mkdir -p -m 700 "$WASPFLOW_HOME" "$WASPFLOW_LOCKS_DIR" || return 1
  exec {fd}>"$WASPFLOW_LOCKS_DIR/events.lock" || return 1; flock -x "$fd" || return 1
  lane="$(jq -sr --arg id "$event_id" 'map(select(.event_id == $id)) | last | .lane // ""' "$ledger")" || return 1
  generation="$(jq -sr --arg id "$event_id" 'map(select(.event_id == $id)) | last | .generation // ""' "$ledger")" || return 1
  [[ -n "$lane" && "$generation" =~ ^[0-9]+$ ]] || return 1
  latest="$(jq -sr --arg lane "$lane" '[.[] | select(.lane == $lane) | .generation] | max // -1' "$ledger")" || return 1
  # A newer generation supersedes this obligation. An old completion cannot
  # acknowledge current work merely because the same consumer still has it.
  [[ "$latest" == "$generation" ]] || return 1
  jq -e --arg id "$event_id" --arg consumer "$consumer" '.[$id].consumer == $consumer and (.[$id].acked // false | not)' "$claims" >/dev/null || return 1
  tmp="$(mktemp "$WASPFLOW_HOME/.event-claims.XXXXXX")" || return 1
  jq --arg id "$event_id" '.[$id].acked = true | .[$id].acked_epoch = now' "$claims" >"$tmp" && mv "$tmp" "$claims" || { rm -f "$tmp"; return 1; }
)

reconcile_lane_json() {
  local lane="$1" record active_scopes="$2" scopes_ok="$3" pid expected_start actual_start window=false lifecycle record_status owner cwd outcome claims pending_events=0 pending_events_state=known superseded_pending_events=0 pending_events_reason="" event_summary classification next_action evidence
  local state_file; state_file="$(lane_state_file "$lane")"
  if [[ ! -f "$state_file" ]]; then jq -cn --arg lane "$lane" '{lane:$lane,status:"unknown",evidence:["missing-state.json"],next_action:"preserve forensic path; inspect record directory"}'; return; fi
  if ! record="$(jq -c . "$state_file" 2>/dev/null)"; then jq -cn --arg lane "$lane" '{lane:$lane,status:"unknown",evidence:["corrupt-state.json"],next_action:"preserve forensic path; repair or inspect record"}'; return; fi
  tmux_owned_lane_window_exists "$lane" && window=true
  lifecycle="$(waspflow_derived_lane_lifecycle "$record" "$active_scopes" "$scopes_ok")"
  record_status="$(jq -r '.status // ""' <<<"$record")"
  owner="$(jq -r '.owner_ref // ""' <<<"$record")"
  cwd="$(jq -r '.cwd // ""' <<<"$record")"
  outcome="$(jq -r '.outcome // ""' <<<"$record")"
  pid="$(jq -r '.tmux_pane_pid // ""' <<<"$record")"; expected_start="$(jq -r '.tmux_pane_pid_start_time // ""' <<<"$record")"
  actual_start="$(_reconcile_pid_start_time "$pid" 2>/dev/null || true)"
  if [[ -f "$(reconcile_event_ledger)" ]]; then
    claims="$(jq -c . "$(reconcile_event_claims)" 2>/dev/null || true)"
    if [[ -z "$claims" ]] || ! jq -e 'type == "object"' >/dev/null <<<"$claims"; then
      pending_events=null; superseded_pending_events=null; pending_events_state=unknown; pending_events_reason="unreadable-event-claims"
    elif ! event_summary="$(jq -cs --arg lane "$lane" --argjson claims "$claims" '
      [ .[] | select(.lane == $lane) ] as $events |
      if any($events[]?; (.generation | type) != "number") then
        {state:"unknown",pending:null,superseded:null,reason:"invalid-event-generation"}
      else
        [ $events[] | select(.state == "pending" and (($claims[.event_id].acked // false) | not)) ] as $unacked |
        ($events | map(.generation) | max // null) as $latest |
        {state:"known",
         pending:([$unacked[] | select(.generation == $latest)] | length),
         superseded:([$unacked[] | select(.generation != $latest)] | length),
         reason:""}
      end
    ' "$(reconcile_event_ledger)" 2>/dev/null)"; then
      pending_events=null; superseded_pending_events=null; pending_events_state=unknown; pending_events_reason="unreadable-event-ledger"
    else
      pending_events="$(jq -c .pending <<<"$event_summary")"
      superseded_pending_events="$(jq -c .superseded <<<"$event_summary")"
      pending_events_state="$(jq -r .state <<<"$event_summary")"
      pending_events_reason="$(jq -r .reason <<<"$event_summary")"
    fi
  fi
  classification="$lifecycle"; next_action="inspect durable receipt"
  # Derived lifecycle is stronger evidence than historical pane metadata. A
  # completed reap may deliberately remove its cwd, and a live scope may keep
  # descendants running after the pane shell has gone away.
  if [[ "$lifecycle" == reaped ]]; then
    next_action="inspect durable receipt"
  elif [[ "$lifecycle" == live ]]; then
    classification="live"; next_action="observe or use normal wait/revise controls"
  elif [[ "$record_status" == parked ]]; then
    classification="parked"; next_action="inspect durable receipt"
  elif [[ "$window" == true ]]; then classification="live"; next_action="observe or use normal wait/revise controls"
  elif [[ -n "$cwd" && ! -d "$cwd" ]]; then classification="unknown"; next_action="recorded working directory is missing; preserve and inspect"
  elif [[ "$lifecycle" == interrupted ]]; then next_action="inspect before explicit recovery or adoption"
  elif [[ -n "$expected_start" && -z "$actual_start" ]]; then classification="interrupted"; next_action="recorded pane process exited; inspect before recovery"
  elif [[ -n "$expected_start" && "$actual_start" != "$expected_start" ]]; then classification="unknown"; next_action="PID identity changed; refuse adoption and inspect"
  elif [[ -n "$expected_start" && "$actual_start" == "$expected_start" ]]; then classification="live"; next_action="recorded process identity is live; inspect its owned resources"
  elif [[ -n "$outcome" && "$record_status" != reaped ]]; then classification="closed-unreaped"; next_action="explicitly reap only after inspecting cleanup evidence"
  elif [[ "$lifecycle" == unknown ]]; then next_action="identity evidence is incomplete; preserve and inspect"
  fi
  evidence="$(jq -cn --arg lifecycle "$lifecycle" --arg pid "$pid" --arg expected "$expected_start" --arg actual "$actual_start" '["recorded-lifecycle:" + $lifecycle] + (if $pid == "" then [] else ["pane-pid:" + $pid] end) + (if $expected == "" then [] else ["recorded-pid-start:" + $expected] end) + (if $actual == "" then [] else ["observed-pid:absent"] end)')" || return 1
  jq -cn --arg lane "$lane" --arg status "$classification" --arg owner "$owner" --arg next "$next_action" --arg pending_state "$pending_events_state" --arg pending_reason "$pending_events_reason" --argjson window "$window" --argjson pending "$pending_events" --argjson superseded "$superseded_pending_events" --argjson evidence "$evidence" \
    '{lane:$lane,status:$status,current_owner:(if $owner == "" then null else $owner end),tmux_window_exists:$window,pending_events:$pending,pending_events_state:$pending_state,pending_events_reason:(if $pending_reason == "" then null else $pending_reason end),superseded_pending_events:$superseded,evidence:$evidence,next_action:$next}'
}

cmd_reconcile() {
  local project="" owner="" json=0 adopt="" apply=0 active_scopes='[]' scopes_ok=true lane row
  while [[ $# -gt 0 ]]; do case "$1" in
    --help|-h)
      cat <<'EOF'
Usage:
  waspflow reconcile [--project DIR] [--owner REF] [--json]
  waspflow reconcile --adopt LANE --owner REF --apply

The first form is read-only. Adoption is explicit, rechecks identity under the
lane lock, records a handoff, and never stops or removes resources.
EOF
      return 0
      ;;
    --project) project="${2:-}"; shift 2 ;; --owner) owner="${2:-}"; shift 2 ;;
    --json) json=1; shift ;; --adopt) adopt="${2:-}"; shift 2 ;; --apply) apply=1; shift ;;
    *) die "reconcile: unknown option '$1'" ;; esac; done
  [[ -z "$project" ]] || project="$(cd "$project" && pwd)" || die "reconcile: --project does not exist"
  if [[ -n "$adopt" || "$apply" -eq 1 ]]; then
    [[ -n "$adopt" && "$apply" -eq 1 && -n "$owner" ]] || die "reconcile: adoption requires --adopt LANE --owner REF --apply"
    lane_exists "$adopt" || die "reconcile: cannot adopt missing or corrupt lane '$adopt'"
    lane_operation_run "$adopt" _reconcile_adopt_locked "$adopt" "$owner"
    return
  fi
  if ! active_scopes="$(waspflow_active_scope_snapshot 2>/dev/null)"; then
    active_scopes='[]'; scopes_ok=false
  fi
  local -a rows=()
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    row="$(reconcile_lane_json "$lane" "$active_scopes" "$scopes_ok")"
    [[ -z "$project" ]] || [[ "$(jq -r '.cwd // ""' "$(lane_state_file "$lane")" 2>/dev/null)" == "$project" ]] || continue
    [[ -z "$owner" || "$(jq -r '.current_owner // ""' <<<"$row")" == "$owner" ]] || continue
    rows+=("$row")
  done < <(list_lanes)
  if [[ "$json" -eq 1 ]]; then [[ ${#rows[@]} -eq 0 ]] && echo '[]' || printf '%s\n' "${rows[@]}" | jq -cs .
  else printf '%-20s %-18s %s\n' LANE STATUS NEXT_ACTION; for row in "${rows[@]}"; do printf '%-20s %-18s %s\n' "$(jq -r .lane <<<"$row")" "$(jq -r .status <<<"$row")" "$(jq -r .next_action <<<"$row")"; done; fi
}

_reconcile_adopt_locked() {
  local lane="$1" owner="$2" state current record active='[]' scopes_ok=true classification
  record="$(cat "$(lane_state_file "$lane")" 2>/dev/null)" || return 1; jq -e type >/dev/null <<<"$record" || return 1
  if ! active="$(waspflow_active_scope_snapshot 2>/dev/null)"; then
    active='[]'; scopes_ok=false
  fi
  classification="$(reconcile_lane_json "$lane" "$active" "$scopes_ok" | jq -r .status)"
  [[ "$classification" != unknown ]] || { err "reconcile: lane '$lane' has uncertain identity; refusing adoption"; return 1; }
  current="$(lane_get "$lane" owner_ref)"; [[ "$current" == "$owner" ]] && { log "reconcile: lane '$lane' already owned by '$owner'"; return 0; }
  provenance_emit_owner_handoff "$lane" "$current" "$owner" || return 1
  lane_set "$lane" owner_ref "$owner" owner_handoff_state recorded event_subscription_state pending
  log "reconcile: adopted '$lane' for '$owner' (no resources were stopped or removed)"
}
