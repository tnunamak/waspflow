# Reused lane labels and repeated owner pairs represent separate obligations.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-owner-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"; source "$root/lib/reconcile.sh"; source "$root/lib/provenance.sh"
  tmux_owned_lane_window_exists() { return 1; }
  lane_set life provider fake status reaped lane_uuid old-life cwd "$fixture"
  old="$(reconcile_event_emit life 9 completion)"
  reconcile_event_claim "$old" consumer 60 >/dev/null
  reconcile_event_ack "$old" consumer
  lane_set life lane_uuid new-life
  new="$(reconcile_event_emit life 1 completion)"
  same_generation="$(reconcile_event_emit life 9 completion)"
  [[ "$old" != "$same_generation" ]]
  reconcile_event_claim "$same_generation" consumer 60 >/dev/null
  reconcile_event_ack "$same_generation" consumer
  reconcile_lane_json life '[]' true | jq -e '.pending_events == 0 and .superseded_pending_events == 1' >/dev/null
  if reconcile_event_ack "$old" consumer; then exit 1; fi
)
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-handoff-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"; source "$root/lib/reconcile.sh"; source "$root/lib/provenance.sh"
  waspflow_active_scope_snapshot() { echo '[]'; }
  tmux_owned_lane_window_exists() { return 1; }
  lane_set handoff provider fake status reaped cwd "$fixture" lane_uuid life owner_ref A
  for owner in B A B; do _reconcile_adopt_locked handoff "$owner" >/dev/null; done
  jq -es '[.[] | select(.event_type == "lane_owner_handoff")] | length == 3 and .[-1].ownership.to == "B"' "$WASPFLOW_HOME/provenance.jsonl" >/dev/null
  [[ "$(lane_get handoff owner_ref)" == B ]]
  _reconcile_adopt_locked handoff B >/dev/null
  [[ "$(wc -l <"$WASPFLOW_HOME/provenance.jsonl")" == 3 ]]
)
