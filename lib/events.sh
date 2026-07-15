#!/usr/bin/env bash
#
# events.sh — read-only normalized provider-event observation and lane inspection.
#
# This is intentionally a small, whitelist-only boundary between provider JSONL
# (which can contain prompts, tool arguments, and secrets) and orchestration.
# It never writes lane state, sends tmux keys, or captures pane paint.

# Emit one safe event-tail document. The source path is deliberately reduced to
# its basename. A bounded tail cannot truthfully expose absolute line offsets,
# so it exposes no offset at all. Event bodies are never emitted.
# Args: lane limit
provider_event_tail() {
  local lane="$1" limit="$2" provider source="" source_kind="" sid=""
  provider="$(lane_get "$lane" provider)"
  case "$provider" in
    codex)
      source="$(lane_get "$lane" rollout)"
      source_kind="rollout-jsonl"
      ;;
    claude)
      sid="$(claude_discover_session "$lane" 2>/dev/null || true)"
      [[ -n "$sid" ]] && source="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -type f -name "${sid}.jsonl" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
      source_kind="session-jsonl"
      ;;
    grok)
      sid="$(grok_discover_session "$lane" 2>/dev/null || true)"
      [[ -n "$sid" ]] && source="$(_grok_events_file "$sid" 2>/dev/null || true)"
      source_kind="events-jsonl"
      ;;
    *) jq -cn --arg provider "$provider" '{provider:$provider,source:{state:"unknown-provider"},events:[]}'; return 0 ;;
  esac
  if [[ -z "$source" || ! -f "$source" ]]; then
    jq -cn --arg provider "$provider" --arg kind "$source_kind" '{provider:$provider,source:{state:"missing",kind:$kind},events:[]}'
    return 0
  fi

  # A provider log can be huge and sparse. Bound every read to this tail window;
  # observation is consequently honest only about sampled data, not log-wide
  # integrity. Temp files live outside the lane so a read never dirties durable
  # state, even when the lane directory is on a watched or read-only filesystem.
  local bytes_limit="${WASPFLOW_EVENT_TAIL_BYTES:-262144}" temp_root file_bytes snapshot last_byte line n=0 last_line=0 bad=0 truncated=0 leading_partial=0 parsed event events_file result
  [[ "$bytes_limit" =~ ^[0-9]+$ && "$bytes_limit" -gt 0 ]] || bytes_limit=262144
  # /tmp is RAM-backed on the supported host. Keep even bounded snapshots on
  # disk; tests can inject their isolated disk-backed scratch root explicitly.
  temp_root="${WASPFLOW_EVENT_TMPDIR:-${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}}"
  mkdir -p "$temp_root" || return 1
  file_bytes="$(wc -c <"$source" 2>/dev/null || echo '')"
  if [[ ! "$file_bytes" =~ ^[0-9]+$ ]]; then jq -cn --arg provider "$provider" --arg kind "$source_kind" '{provider:$provider,source:{state:"unreadable",kind:$kind},events:[]}'; return 0; fi
  snapshot="$(mktemp "$temp_root/waspflow-event-tail.XXXXXX")" || return 1
  if ! tail -c "$bytes_limit" "$source" >"$snapshot" 2>/dev/null; then
    rm -f "$snapshot"; jq -cn --arg provider "$provider" --arg kind "$source_kind" '{provider:$provider,source:{state:"unreadable",kind:$kind},events:[]}'; return 0
  fi
  [[ "$file_bytes" -gt "$bytes_limit" ]] && leading_partial=1
  last_byte="$(tail -c 1 "$snapshot" 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
  while IFS= read -r line || [[ -n "$line" ]]; do last_line=$((last_line + 1)); done <"$snapshot"
  events_file="$(mktemp "$temp_root/waspflow-event-values.XXXXXX")" || { rm -f "$snapshot"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if ! parsed="$(jq -c . <<<"$line" 2>/dev/null)"; then
      # A sampled tail may begin halfway through a record; that says nothing
      # about provider corruption, so drop only that first partial candidate.
      if [[ "$leading_partial" -eq 1 && "$n" -eq 1 ]]; then continue; fi
      if [[ "$last_byte" != 0a && "$n" -eq "$last_line" ]]; then truncated=1; else bad=1; fi
      continue
    fi
    case "$provider" in
      codex)
        if ! event="$(jq -cn --argjson x "$parsed" '
          ($x.payload.type // $x.type // "") as $t |
          if $t == "task_started" then {event_time:($x.timestamp // ""),event_type:"turn_started",turn_started_mark:true}
          elif $t == "task_complete" then {event_time:($x.timestamp // ""),event_type:"turn_completed",turn_completed_mark:true}
          elif $t == "thread_settings_applied" then {event_time:($x.timestamp // ""),event_type:"runtime_settings"}
          else empty end')"; then rm -f "$snapshot" "$events_file"; return 1; fi
        ;;
      claude)
        if ! event="$(jq -cn --argjson x "$parsed" '
          if $x.type == "user" and (($x.message.content // null) | type == "string") then {event_time:($x.timestamp // ""),event_type:"turn_started",turn_started_mark:true}
          elif $x.type == "assistant" and ($x.message.stop_reason // "") == "end_turn" then {event_time:($x.timestamp // ""),event_type:"turn_completed",turn_completed_mark:true}
          elif $x.type == "assistant" then {event_time:($x.timestamp // ""),event_type:"assistant_event"}
          else empty end')"; then rm -f "$snapshot" "$events_file"; return 1; fi
        ;;
      grok)
        if ! event="$(jq -cn --argjson x "$parsed" '
          if $x.type == "turn_started" then {event_time:($x.timestamp // ""),event_type:"turn_started",turn_started_mark:true}
          elif $x.type == "turn_ended" then {event_time:($x.timestamp // ""),event_type:"turn_completed",turn_completed_mark:true}
          else empty end')"; then rm -f "$snapshot" "$events_file"; return 1; fi
        ;;
    esac
    if [[ -n "$event" ]] && ! printf '%s\n' "$event" >>"$events_file"; then rm -f "$snapshot" "$events_file"; return 1; fi
  done <"$snapshot"
  local state="tail-window"; [[ "$bad" -eq 1 ]] && state="malformed-tail"; [[ "$truncated" -eq 1 ]] && state="truncated-tail"
  if ! result="$(jq -cn --arg provider "$provider" --arg kind "$source_kind" --arg base "$(basename "$source")" --arg state "$state" --argjson file_bytes "$file_bytes" --argjson bytes_sampled "$(wc -c <"$snapshot")" --slurpfile events "$events_file" --argjson limit "$limit" '
    ([ $events[] | select(.turn_started_mark or .turn_completed_mark) ] | last // null) as $mark |
    ($events | .[-$limit:]) as $tail |
    {provider:$provider,source:{state:$state,integrity:"tail-window-only",kind:$kind,basename:$base,file_bytes:$file_bytes,bytes_sampled:$bytes_sampled},events:$tail,
     turn_state:(if $mark == null then "unknown" elif $mark.turn_completed_mark then "terminal" else "active" end)}')"; then
    rm -f "$snapshot" "$events_file"
    return 1
  fi
  rm -f "$snapshot" "$events_file"
  printf '%s\n' "$result"
}

# One lane's reconciliation surface.  Facts first; classification is an
# explainable conservative interpretation, never a claim that a lane is stale.
lane_inspection_json() {
  local lane="$1" sf provider tail exists clients outcome report verify state classification eligibility
  sf="$(lane_state_file "$lane")"
  if ! jq empty "$sf" 2>/dev/null; then jq -cn --arg lane "$lane" '{lane:$lane,classification:"corrupt/unknown",eligibility:"preserve",reasons:["unparseable-state.json"]}'; return 0; fi
  provider="$(lane_get "$lane" provider)"
  case "$provider" in claude|codex|grok) load_provider "$provider" ;; *)
    jq -cn --arg lane "$lane" --arg provider "$provider" '{lane:$lane,provider:$provider,classification:"corrupt/unknown",eligibility:"preserve",reasons:["unknown-provider"]}'
    return 0
  esac
  tail="$(provider_event_tail "$lane" 1)"
  exists=false; tmux_window_exists "$lane" && exists=true
  clients="$(tmux list-clients -t "${WASPFLOW_TMUX_SESSION}:" -F '#{client_tty}' 2>/dev/null | wc -l | tr -d ' ')"
  outcome="$(lane_outcome "$lane")"; report="$(lane_get "$lane" report)"; verify="$(lane_get "$lane" verify_state)"; state="$(lane_get "$lane" status)"
  local terminal source_state wait_state; terminal="$(jq -r '.turn_state == "terminal"' <<<"$tail")"; source_state="$(jq -r '.source.state' <<<"$tail")"; wait_state="$(lane_get "$lane" wait_state)"
  classification="corrupt/unknown"; eligibility="preserve"
  local -a reasons=("provider-log:$source_state")
  if [[ "$wait_state" == stalled ]]; then classification="blocked-needs-human"; eligibility="needs-human"; reasons+=("recorded-wait-stall")
  elif [[ "$state" == live && "$exists" != true ]]; then classification="orphaned-control-plane"; eligibility="needs-human"; reasons+=("live-record-missing-owned-window")
  elif [[ "$source_state" != tail-window ]]; then reasons+=("provider-receipt-not-trustworthy")
  elif [[ "$outcome" =~ ^(harvested|superseded|abandoned)$ && "$terminal" == true ]] \
    && { [[ -z "$report" || -f "$report" ]] && [[ -z "$verify" || "$verify" == passed ]]; }; then
    classification="closeout-ready"; eligibility="explicit-closeout"; reasons+=("terminal-receipt" "closeout-provenance")
  elif [[ "$terminal" == true ]]; then classification="terminal-idle-unclosed"; eligibility="needs-human"; reasons+=("terminal-provider-receipt")
  elif [[ "$exists" == true ]]; then classification="active-observed"; eligibility="observe"; reasons+=("owned-window-and-nonterminal-receipt")
  else reasons+=("insufficient-source-facts")
  fi
  if [[ "$clients" =~ ^[0-9]+$ && "$clients" -gt 0 ]]; then
    classification="blocked-needs-human"
    eligibility="vetoed-attached-client"
    reasons+=("attached-client-veto")
  fi
  jq -cn --arg lane "$lane" --arg provider "$provider" --arg lifecycle "$state" --arg outcome "$outcome" --arg classification "$classification" --arg eligibility "$eligibility" --argjson window "$exists" --argjson clients "${clients:-0}" --argjson receipt "$tail" --argjson reasons "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -sc .)" \
    '{lane:$lane,provider:$provider,lifecycle:$lifecycle,fanin_outcome:$outcome,tmux_window_exists:$window,tmux_client_count:$clients,provider_receipt:{source:$receipt.source,last_event:($receipt.events[-1] // null)},classification:$classification,eligibility:$eligibility,reasons:$reasons}'
}
