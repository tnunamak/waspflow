# r3-f4: reconciliation diagnostics, escalation target validation, and list retention.
(
  fixture="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r3-f4-reconcile-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/reconcile.sh"

  tmux_owned_lane_window_exists() { return 1; }
  lane_set r3-f4-events provider fake status reaped cwd "$fixture"
  old_event="$(reconcile_event_emit r3-f4-events 1 completion)"
  current_event="$(reconcile_event_emit r3-f4-events 2 completion)"
  reconcile_event_claim "$current_event" consumer 60 >/dev/null
  reconcile_event_ack "$current_event" consumer

  event_row="$(reconcile_lane_json r3-f4-events '[]' true)"
  jq -e '.pending_events == 0 and .superseded_pending_events == 1 and .pending_events_state == "known" and .pending_events_reason == null' <<<"$event_row" >/dev/null \
    || { echo 'r3-f4: superseded events remained pending' >&2; exit 1; }
  ! reconcile_event_ack "$old_event" consumer

  printf '{\n' >>"$(reconcile_event_ledger)"
  event_row="$(reconcile_lane_json r3-f4-events '[]' true)"
  jq -e '.pending_events == null and .superseded_pending_events == null and .pending_events_state == "unknown" and .pending_events_reason == "unreadable-event-ledger"' <<<"$event_row" >/dev/null \
    || { echo 'r3-f4: unreadable event ledger was reported as zero pending events' >&2; exit 1; }
)

(
  fixture="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r3-f4-escalate-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/selection.sh"
  source "$root/lib/escalation.sh"

  ops_load() { OPS_POLICY_JSON='{"operating_points":[]}'; }
  selection_observe_availability() { jq -cn --arg provider "$1" --arg model "$2" '{provider:$provider,model:$model,state:"unknown",evidence_source:"non_enumerable",query_scope:"not_applicable",observed_at:null}'; }
  lane_set r3-f4-claude provider claude model claude-sonnet-5-5 effort low op_mode standard

  if escalate_select_target r3-f4-claude claude/not-a-model/low false false; then
    echo 'r3-f4: unacknowledged unknown Claude model was accepted' >&2; exit 1
  fi
  [[ "$ESC_REASON" == *'not a known Claude model'* ]]
  if escalate_select_target r3-f4-claude claude/not-a-model/low true false; then
    echo 'r3-f4: --force without acknowledgement accepted an unknown Claude model' >&2; exit 1
  fi
  escalate_select_target r3-f4-claude claude/not-a-model/low true true
  [[ "$(jq -r .model <<<"$ESC_ARM")" == not-a-model ]]
  escalate_select_target r3-f4-claude claude/claude-haiku-4-5/low false false
  escalate_select_target r3-f4-claude claude/sonnet/low false false
)
