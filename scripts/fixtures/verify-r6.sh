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
)
