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

(
  fixture="$(mktemp -d "$scratch/waspflow-r2-e-ledger-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/reconcile.sh"

  # The acknowledgement's supersession check must use every ledger row, not
  # the final row only. A failed acknowledgement also leaves the shared lock
  # available to the next event operation in this long-lived shell.
  alpha_one="$(reconcile_event_emit alpha 1 completion)"
  alpha_two="$(reconcile_event_emit alpha 2 completion)"
  reconcile_event_emit beta 1 completion >/dev/null
  reconcile_event_claim "$alpha_two" consumer 60 | jq -e '.ok == true' >/dev/null
  reconcile_event_ack "$alpha_two" consumer
  if reconcile_event_ack "$alpha_one" wrong-consumer; then
    echo 'reconcile: stale acknowledgement succeeded' >&2; exit 1
  fi
  flock -n "$WASPFLOW_LOCKS_DIR/events.lock" true
)

(
  fixture="$(mktemp -d "$scratch/waspflow-r2-e-events-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib" WASPFLOW_EVENT_TMPDIR="$fixture/tmp"
  source "$root/lib/core.sh"
  source "$root/lib/events.sh"

  # DeepSeek's durable receipt is already a safe, typed lifecycle stream; it
  # needs no provider session log and must classify like the other receipt APIs.
  lane_set deepseek-events provider deepseek
  mkdir -p "$(lane_dir deepseek-events)"
  cat >"$(lane_dir deepseek-events)/deepseek-receipts.jsonl" <<'EOF'
{"phase":"invocation","started_epoch":10}
{"phase":"completion","outcome":"failed","completed_epoch":12}
EOF
  provider_event_tail deepseek-events 2 | jq -e '
    .provider == "deepseek" and .source.kind == "deepseek-receipt-jsonl" and
    .turn_state == "terminal" and ([.events[].event_type] == ["turn_started", "turn_completed"])
  ' >/dev/null
)

(
  fixture="$(mktemp -d "$scratch/waspflow-r2-e-doctor-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  mkdir -p "$fixture/bin" "$fixture/home"
  for tool in bash tmux jq awk python3 git flock timeout perl dirname find date sort tail head cat mkdir rm cksum grep sed; do
    ln -s "$(command -v "$tool")" "$fixture/bin/$tool"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/codex"
  chmod +x "$fixture/bin/codex"

  doctor() {
    PATH="$fixture/bin" HOME="$fixture/home" WASPFLOW_HOME="$fixture/home/state" \
      WASPFLOW_DOCTOR_LATEST_TAG=v999.0.0 "$root/bin/waspflow" doctor
  }

  rm "$fixture/bin/codex"
  if doctor >"$fixture/no-provider.out"; then
    echo 'doctor: no-provider host reported ready' >&2; exit 1
  fi
  grep -q 'FAIL provider CLI (install one supported provider)' "$fixture/no-provider.out"

  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/codex"
  chmod +x "$fixture/bin/codex"
  rm "$fixture/bin/timeout"
  if doctor >"$fixture/no-timeout.out"; then
    echo 'doctor: missing timeout reported ready' >&2; exit 1
  fi
  grep -q 'FAIL tool timeout (required)' "$fixture/no-timeout.out"
  ln -s "$(command -v timeout)" "$fixture/bin/timeout"
  rm "$fixture/bin/perl"
  if doctor >"$fixture/no-perl.out"; then
    echo 'doctor: missing perl reported ready' >&2; exit 1
  fi
  grep -q 'FAIL tool perl (required)' "$fixture/no-perl.out"
)
