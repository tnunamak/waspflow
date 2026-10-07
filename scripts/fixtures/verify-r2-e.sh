# R2-E: reconcile lifecycle precedence, doctor prerequisites, and DeepSeek events.
(
  fixture="$(mktemp -d "$scratch/waspflow-r2-e-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib" WASPFLOW_EVENT_TMPDIR="$fixture/tmp"
  source "$root/lib/core.sh"
  source "$root/lib/reconcile.sh"

  # Terminal lifecycle is authoritative even when reaping removed its checkout
  # and the historical pane PID is gone. A parked lane is similarly no longer
  # a candidate for stale-PID interruption. A live scope outranks both facts.
  tmux_owned_lane_window_exists() { return 1; }
  lane_set reaped provider fake status reaped cwd "$fixture/removed" tmux_pane_pid 999999 tmux_pane_pid_start_time 1
  lane_set parked provider fake status parked cwd "$fixture/removed" tmux_pane_pid 999999 tmux_pane_pid_start_time 1
  lane_set scoped provider fake status live cwd "$fixture/removed" tmux_pane_pid 999999 tmux_pane_pid_start_time 1
  scoped_state="$(lane_state_file scoped)"
  jq '.cgroup_scope_receipts=[{unit:"waspflow-r2-e.scope",invocation_id:"fixture"}]' "$scoped_state" >"$scoped_state.tmp"
  mv "$scoped_state.tmp" "$scoped_state"
  reconcile_lane_json reaped '[]' true | jq -e '.status == "reaped"' >/dev/null
  reconcile_lane_json parked '[]' true | jq -e '.status == "parked"' >/dev/null
  reconcile_lane_json scoped '["waspflow-r2-e.scope"]' true | jq -e '.status == "live"' >/dev/null

)
