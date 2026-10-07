# S7: fleet reconciliation is conservative, bounded, and provider-free.
(
  s7="$(mktemp -d "$scratch/waspflow-s7-fleet-XXXXXX")"
  trap 'rm -rf "$s7"' EXIT
  export WASPFLOW_HOME="$s7/home" WASPFLOW_EVENT_TMPDIR="$s7/tmp" WASPFLOW_TMUX_SESSION="wf-test-$$"
  mkdir -p "$s7/bin" "$s7/cwd" "$s7/projects/alternate/projects/p"
  cat >"$s7/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$s7/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# The fixture deliberately exposes no owned panes and never contacts a server.
if [[ "${1:-}" == list-clients ]]; then
  exit 0
fi
exit 1
EOF
  chmod +x "$s7/bin/systemctl" "$s7/bin/tmux"

  # Claude events follow the lane's profile when the global projects root is unset.
  source "$root/lib/core.sh"
  source "$root/lib/providers/claude.sh"
  source "$root/lib/events.sh"
  lane_set claude-alt provider claude status live session_id session-alt claude_config_dir "$s7/projects/alternate"
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$s7/projects/alternate/projects/p/session-alt.jsonl"
  unset CLAUDE_PROJECTS_DIR
  provider_event_tail claude-alt 1 | jq -e '.source.state == "tail-window" and .turn_state == "terminal"' >/dev/null
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" inspect claude-alt >"$s7/inspect.json" 2>"$s7/inspect.err"
  jq -e '.classification == "orphaned-control-plane" and (.next_action | contains("waspflow reconcile"))' "$s7/inspect.json" >/dev/null
  [[ ! -s "$s7/inspect.err" ]]

  # Corrupt rows are part of the durable-index prefix and still diagnose rc 2.
  for n in 1 2 3 4 5 6; do mkdir -p "$WASPFLOW_LANES_DIR/bad$n"; printf '{' >"$WASPFLOW_LANES_DIR/bad$n/state.json"; done
  set +e
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" list --limit 5 --json >"$s7/list.json" 2>"$s7/list.err"
  list_rc=$?
  set -e
  [[ "$list_rc" -eq 2 && "$(jq length "$s7/list.json")" -eq 5 ]]

  # Reconcile only reads durable facts: no fake provider is placed on PATH and
  # a missing pane is not enough to adopt anything. PID start time lets the
  # no-systemd fallback distinguish dead, live, and reused identities.
  source "$root/lib/reconcile.sh"
  live_start="$(_reconcile_pid_start_time "$$")"
  lane_set live provider fake status live cwd "$s7/cwd" lane_uuid 11111111-1111-1111-1111-111111111111 tmux_pane_pid "$$" tmux_pane_pid_start_time "$live_start" owner_ref current
  lane_set dead provider fake status live cwd "$s7/cwd" lane_uuid 22222222-2222-2222-2222-222222222222 tmux_pane_pid 999999 tmux_pane_pid_start_time 1
  lane_set reused provider fake status live cwd "$s7/cwd" lane_uuid 33333333-3333-3333-3333-333333333333 tmux_pane_pid "$$" tmux_pane_pid_start_time 0
  lane_set missing-wt provider fake status live cwd "$s7/no-worktree" lane_uuid 44444444-4444-4444-4444-444444444444
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" reconcile --owner current --json >"$s7/reconcile.json"
  jq -e 'map(select(.lane == "live" and .status == "live")) | length == 1' "$s7/reconcile.json" >/dev/null
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" reconcile --json >"$s7/all.json"
  jq -e 'map(select(.lane == "dead" and .status == "interrupted")) | length == 1' "$s7/all.json" >/dev/null
  jq -e 'map(select(.lane == "reused" and .status == "unknown")) | length == 1' "$s7/all.json" >/dev/null
  jq -e 'map(select(.lane == "missing-wt" and .status == "unknown")) | length == 1' "$s7/all.json" >/dev/null
  WASPFLOW_DOCTOR_LATEST_TAG=v999.0.0 PATH="$s7/bin:$PATH" "$root/bin/waspflow" doctor >"$s7/doctor.out"
  grep -q 'WARN fleet recovery: unknown=.*orphaned=' "$s7/doctor.out"
  grep -q 'waspflow reconcile --json' "$s7/doctor.out"

  # Ownership changes require an explicit apply and append exactly one handoff;
  # they never stop a pane, remove a worktree, or reconstruct a lane.
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" reconcile --adopt live --owner next-owner --apply >/dev/null
  PATH="$s7/bin:$PATH" "$root/bin/waspflow" reconcile --adopt live --owner next-owner --apply >/dev/null
  [[ "$(lane_get live owner_ref)" == next-owner ]]
  [[ "$(jq -s '[.[] | select(.event_type == "lane_owner_handoff")] | length' "$WASPFLOW_HOME/provenance.jsonl")" -eq 1 ]]

  # A revised generation has a distinct event id. Leased claims serialize two
  # consumers, and a retry after lease expiry remains possible.
  first="$(reconcile_event_emit live 1 completion)"; second="$(reconcile_event_emit live 2 completion)"
  [[ "$first" != "$second" ]]
  reconcile_event_claim "$first" consumer-a 1 | jq -e '.ok == true' >/dev/null
  reconcile_event_claim "$first" consumer-b 1 | jq -e '.ok == false and .reason == "claimed"' >/dev/null
  # A one-second sleep races the integer-second lease boundary. Expire the
  # fixture claim explicitly so the next assertion is deterministic.
  claims_file="$(reconcile_event_claims)"
  jq --arg id "$first" '.[$id].lease_until = 0' "$claims_file" >"$claims_file.tmp"
  mv "$claims_file.tmp" "$claims_file"
  reconcile_event_claim "$first" consumer-b 2 | jq -e '.ok == true' >/dev/null
  ! reconcile_event_ack "$first" consumer-b
  reconcile_event_claim "$second" consumer-b 2 | jq -e '.ok == true' >/dev/null
  reconcile_event_ack "$second" consumer-b
  ! reconcile_event_claim "$second" consumer-a 2 | jq -e '.ok == true' >/dev/null
)
