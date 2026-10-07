# R6 release blockers: detached-member continuity, failed observation, and
# pending detached launches. Processes here are local fakes only.
(
  r6="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r6-XXXXXX")"
  trap 'jobs -pr | xargs -r kill -KILL 2>/dev/null || true; rm -rf "$r6"' EXIT
  export WASPFLOW_HOME="$r6/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"

  # C1: this injects a receipt whose leader identity is dead (same PID, old
  # ticks) while a newer sentinel owns the numeric group. It cannot be made
  # literally leaderless without PID reuse, so the identity mismatch exercises
  # the safe path: no member signal and an uncertain remaining resource.
  setsid bash -c 'while :; do sleep 1; done' &
  sentinel=$!
  sleep 0.05
  read -r sentinel_pgid sentinel_sid < <(ps -o pgid= -o sid= -p "$sentinel")
  sentinel_ticks="$(process_start_ticks "$sentinel")"
  lane_set recycled provider fake cwd "$r6"
  recycled_receipt="$(jq -cn --argjson pid "$sentinel" --argjson pgid "$sentinel_pgid" --argjson sid "$sentinel_sid" --argjson ticks "$((sentinel_ticks + 1))" '{pid:$pid,pgid:$pgid,sid:$sid,start_ticks:$ticks}')"
  if tmux_kill_detached_session_receipt_if_owned recycled "$recycled_receipt"; then
    echo 'r6 C1: stale leader identity was retired' >&2; exit 1
  fi
  if ! kill -0 "$sentinel" 2>/dev/null; then
    echo 'r6 C1: recycled-group sentinel was signalled' >&2; exit 1
  fi
  kill -KILL "$sentinel" 2>/dev/null || true

  # A valid group with an original TERM-resistant child still reaches direct
  # KILL. The signal log also proves cleanup never issues a negative PGID kill.
  cat >"$r6/ignore-term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
EOF
  chmod +x "$r6/ignore-term.sh"
  setsid bash -c '
    bash "$1" &
    printf "%s %s\\n" "$$" "$!" >"$2"
    while :; do sleep 1; done
  ' -- "$r6/ignore-term.sh" "$r6/leader-child" &
  for _ in {1..100}; do [[ -s "$r6/leader-child" ]] && break; sleep 0.02; done
  read -r leader child <"$r6/leader-child"
  read -r leader_pgid leader_sid < <(ps -o pgid= -o sid= -p "$leader")
  lane_set direct provider fake cwd "$r6" detached_session_receipts '[]'
  tmux_record_lane_detached_session direct pane "$leader" "$leader_pgid" "$leader_sid" "$(process_start_ticks "$leader")"
  signal_log="$r6/signals"
  kill() { printf '%s\\n' "$*" >>"$signal_log"; builtin kill "$@"; }
  tmux_kill_owned_lane_detached_sessions direct
  if grep -Eq -- '(^| )--?-[0-9]+$' "$signal_log"; then
    echo 'r6 C1: cleanup used a negative process-group signal' >&2; exit 1
  fi
  if kill -0 "$leader" 2>/dev/null || kill -0 "$child" 2>/dev/null; then
    echo 'r6 C1: TERM-resistant group was not retired' >&2; exit 1
  fi

  # B2: an unavailable process census is not evidence that a receipt is gone.
  # Recovery must retain the checkout and ask an owner instead of starting a
  # second provider against it.
  source "$root/lib/fanin.sh"
  source "$root/lib/turn-state.sh"
  source "$root/lib/artifacts.sh"
  lane_set ps-failed provider fake cwd "$r6" spawn_submitted true report "$r6/missing-report"
  setsid bash -c 'while :; do sleep 1; done' &
  observed=$!
  sleep 0.05
  read -r observed_pgid observed_sid < <(command ps -o pgid= -o sid= -p "$observed")
  tmux_record_lane_detached_session ps-failed pane "$observed" "$observed_pgid" "$observed_sid" "$(process_start_ticks "$observed")"
  ps() { return 77; }
  if [[ "$(tmux_detached_session_receipt_group_state "$(tmux_lane_detached_session_receipts ps-failed)" || true)" != uncertain ]]; then
    echo 'r6 B2: failed process enumeration was not uncertain' >&2; exit 1
  fi
  tmux_window_exists() { return 1; }
  _artifacts_recover() { touch "$r6/unexpected-recovery"; }
  if [[ "$(artifacts_finalize ps-failed fake)" != report_missing ]]; then
    echo 'r6 B2: failed process enumeration did not stop recovery' >&2; exit 1
  fi
  if [[ -e "$r6/unexpected-recovery" || "$(lane_get ps-failed recovery_state)" != needs-owner ]]; then
    echo 'r6 B2: recovery started after failed process enumeration' >&2; exit 1
  fi
  unset -f ps
  kill -KILL "$observed" 2>/dev/null || true

  # R4-N1: receipt conversion is bound to the current lane life and launch.
  # A stale writer cannot append its receipt after a respawn has replaced state.
  lane_set stale provider fake cwd "$r6" lane_uuid "$(new_uuid)"
  stale_uuid="$(lane_get stale lane_uuid)"
  stale_launch="$(new_uuid)"
  setsid bash -c 'while :; do sleep 1; done' &
  stale_child=$!
  sleep 0.05
  read -r stale_pgid stale_sid < <(ps -o pgid= -o sid= -p "$stale_child")
  stale_ticks="$(process_start_ticks "$stale_child")"
  tmux_record_pending_detached_launch stale "$stale_uuid" "$stale_launch" pane "$stale_child" "$stale_ticks"
  if tmux_record_lane_detached_session stale pane "$stale_child" "$stale_pgid" "$stale_sid" "$stale_ticks" "$stale_uuid" "$(new_uuid)"; then
    echo 'r6 N1: stale launch receipt append was accepted' >&2; exit 1
  fi
  if [[ -n "$(tmux_lane_detached_session_receipts stale)" ]]; then
    echo 'r6 N1: stale launch wrote a receipt' >&2; exit 1
  fi
  lane_set stale lane_uuid "$(new_uuid)"
  if tmux_record_lane_detached_session stale pane "$stale_child" "$stale_pgid" "$stale_sid" "$stale_ticks" "$stale_uuid" "$stale_launch"; then
    echo 'r6 N1: stale lane-life receipt append was accepted' >&2; exit 1
  fi
  kill -KILL "$stale_child" 2>/dev/null || true

  # An unretired pending child receives TERM only by matching direct identity,
  # then keeps reap partial and listed as an uncertain remaining resource.
  cat >"$r6/pending-ignore-term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
EOF
  chmod +x "$r6/pending-ignore-term.sh"
  setsid "$r6/pending-ignore-term.sh" &
  pending_child=$!
  sleep 0.05
  lane_set pending provider codex cwd "$r6" lane_uuid "$(new_uuid)" spawn_submitted false
  tmux_record_pending_detached_launch pending "$(lane_get pending lane_uuid)" "$(new_uuid)" pane "$pending_child" "$(process_start_ticks "$pending_child")"
  if WASPFLOW_TMUX_SOCKET="wf-test-$$" "$root/bin/waspflow" reap pending --keep-worktree --no-archive >"$r6/reap.out" 2>"$r6/reap.err"; then
    echo 'r6 N1: reap reported complete with a pending launch' >&2; exit 1
  fi
  if [[ "$(lane_get pending reap_cleanup_state)" != partial ]] || ! jq -e '.[] | startswith("pending-launch:")' <<<"$(lane_get pending reap_remaining_resources)" >/dev/null; then
    echo 'r6 N1: reap did not preserve the pending launch as uncertain' >&2; exit 1
  fi
  kill -KILL "$pending_child" 2>/dev/null || true
)
