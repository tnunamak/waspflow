# R3-F1 lifecycle/cleanup regressions. Processes are local fakes only; any tmux
# coverage in this slice uses a private socket.
(
  r3f1="$(mktemp -d "$scratch/waspflow-r3-f1-XXXXXX")"
  trap 'rm -rf "$r3f1"' EXIT
  export WASPFLOW_HOME="$r3f1/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  mkdir -p "$WASPFLOW_HOME"

  # B1: if a detached session leader exits while a TERM-resistant descendant
  # remains in its recorded process group, the group stays uncertain until the
  # bounded TERM/KILL retirement proves it is gone.
  release="$r3f1/release"
  cat >"$r3f1/child.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM HUP
while :; do sleep 1; done
EOF
  chmod +x "$r3f1/child.sh"
  setsid bash -c '
    child_script=$1 release=$2 ready=$3
    bash "$child_script" &
    printf "%s\n" "$!" >"$ready.child"
    printf "%s\n" "$$" >"$ready.leader"
    while [[ ! -e "$release" ]]; do sleep 0.02; done
  ' -- "$r3f1/child.sh" "$release" "$r3f1/ready" &
  leader=$!
  for _ in {1..100}; do [[ -s "$r3f1/ready.leader" && -s "$r3f1/ready.child" ]] && break; sleep 0.02; done
  [[ -s "$r3f1/ready.leader" && -s "$r3f1/ready.child" ]]
  recorded_leader="$(cat "$r3f1/ready.leader")"
  read -r recorded_pgid recorded_sid < <(ps -o pgid= -o sid= -p "$recorded_leader")
  lane_set descendants provider fake cwd "$r3f1" detached_session_receipts "[]"
  tmux_record_lane_detached_session descendants pane "$recorded_leader" "$recorded_pgid" "$recorded_sid" "$(process_start_ticks "$recorded_leader")"
  touch "$release"
  wait "$leader" 2>/dev/null || true
  receipt="$(tmux_lane_detached_session_receipts descendants)"
  [[ "$(tmux_detached_session_receipt_group_state "$receipt" || true)" == uncertain ]]
  tmux_kill_owned_lane_detached_sessions descendants
  [[ "$(tmux_detached_session_receipt_group_state "$receipt" || true)" == gone ]]

  # B3: detached-session receipt appends take the same state lock as lane_set,
  # so no whole-file update can overtake a concurrent lifecycle update.
  lane_set locked provider fake cwd "$r3f1" durable_field kept
  lock_file="$(lane_dir locked)/.state.lock"
  exec 8>"$lock_file"
  flock 8
  ( tmux_record_lane_detached_session locked pane "$$" "$(ps -o pgid= -p "$$" | tr -d ' ')" "$(ps -o sid= -p "$$" | tr -d ' ')" "$(process_start_ticks "$$")"; touch "$r3f1/receipt-done" ) &
  receipt_writer=$!
  sleep 0.1
  [[ ! -e "$r3f1/receipt-done" ]]
  flock -u 8
  wait "$receipt_writer"
  [[ "$(lane_get locked durable_field)" == kept && -n "$(tmux_lane_detached_session_receipts locked)" ]]

  # B2: retirement can exclude the freshly-provisioned escalation group while
  # still stopping every earlier execution group.
  lane_set retirement provider fake cwd "$r3f1"
  tmux_record_lane_detached_session retirement pane 1 1 1 1
  tmux_record_lane_detached_session retirement escalation:new 2 2 2 2
  tmux_kill_detached_session_receipt_if_owned() { jq -r .execution <<<"$1" >>"$r3f1/retired"; }
  tmux_kill_owned_lane_detached_sessions_except_execution retirement escalation:new
  [[ "$(cat "$r3f1/retired")" == pane ]]
  unset -f tmux_kill_detached_session_receipt_if_owned

  # Recovery never starts another provider against a checkout while retirement
  # of the previous detached execution is uncertain.
  source "$root/lib/fanin.sh"
  source "$root/lib/turn-state.sh"
  source "$root/lib/artifacts.sh"
  lane_set recovery provider fake cwd "$r3f1" spawn_submitted true report "$r3f1/missing-report"
  tmux_window_exists() { return 0; }
  tmux_window_target() { printf '@recovery\n'; }
  tmux() { :; }
  tmux_kill_owned_lane_detached_sessions() { return 1; }
  _artifacts_recover() { touch "$r3f1/unexpected-recovery"; }
  [[ "$(artifacts_finalize recovery fake)" == report_missing && ! -e "$r3f1/unexpected-recovery" ]]
  [[ "$(lane_get recovery recovery_reason)" == detached-process-retirement-uncertain ]]
)
