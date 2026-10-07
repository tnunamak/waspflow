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
