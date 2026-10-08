# R7 release blockers: receipt-continuity and completed fallback lifecycle.
# Every process below is fixture-owned and cleaned by its recorded PID.
(
  r7="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r7-XXXXXX")"
  trap 'jobs -pr | xargs -r kill -KILL 2>/dev/null || true; rm -rf "$r7"' EXIT
  export WASPFLOW_HOME="$r7/home" WASPFLOW_LIB="$root/lib" WASPFLOW_TMUX_SOCKET="wf-test-$$"
  source "$root/lib/core.sh"

  # C1-N1: simulate reuse at the exact second-census boundary. Real PID reuse
  # is intentionally not required: the shims model the kernel observations that
  # a recycled numeric PGID/SID would provide. The initial leader is valid; the
  # replacement sentinel must never receive a signal.
  (
    setsid bash -c 'trap "" TERM; while :; do sleep 1; done' &
    leader=$!
    for _ in {1..100}; do process_start_ticks "$leader" >/dev/null 2>&1 && break; sleep 0.02; done
    read -r pgid sid < <(ps -o pgid= -o sid= -p "$leader")
    lane_set recycled provider codex cwd "$r7" detached_session_receipts '[]'
    tmux_record_lane_detached_session recycled pane "$leader" "$pgid" "$sid" "$(process_start_ticks "$leader")"

    eval "$(declare -f tmux_detached_session_receipt_group_members | sed '1s/tmux_detached_session_receipt_group_members/r7_real_members/')"
    eval "$(declare -f tmux_detached_session_receipt_member_matches | sed '1s/tmux_detached_session_receipt_member_matches/r7_real_match/')"
    calls="$r7/recycled.calls"; printf '0\n' >"$calls"
    initial="$r7/recycled.initial"
    tmux_detached_session_receipt_group_members() {
      local n members member ticks sentinel sentinel_ticks
      n=$(( $(cat "$calls") + 1 )); printf '%s\n' "$n" >"$calls"
      if [[ "$n" -eq 1 ]]; then
        members="$(r7_real_members "$1")" || return
        printf '%s\n' "$members" >"$initial"
        printf '%s\n' "$members"
        return
      fi
      while IFS=$'\t' read -r member ticks; do
        [[ -z "$member" ]] || builtin kill -KILL "$member" 2>/dev/null || true
      done <"$initial"
      setsid bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
      sentinel=$!; printf '%s\n' "$sentinel" >"$r7/recycled.sentinel"
      for _ in {1..100}; do process_start_ticks "$sentinel" >/dev/null 2>&1 && break; sleep 0.02; done
      sentinel_ticks="$(process_start_ticks "$sentinel")"; printf '%s\n' "$sentinel_ticks" >"$r7/recycled.sentinel-ticks"
      printf '%s\t%s\n' "$sentinel" "$sentinel_ticks"
    }
    tmux_detached_session_receipt_member_matches() {
      if [[ "$2" == "$(cat "$r7/recycled.sentinel" 2>/dev/null || true)" && "$3" == "$(cat "$r7/recycled.sentinel-ticks" 2>/dev/null || true)" ]]; then
        return 0
      fi
      r7_real_match "$@"
    }
    signals="$r7/recycled.signals"
    kill() { printf '%s\n' "$*" >>"$signals"; builtin kill "$@"; }
    receipt="$(tmux_lane_detached_session_receipts recycled)"
    if tmux_kill_detached_session_receipt_if_owned recycled "$receipt"; then
      echo 'r7 C1: recycled session was treated as owned' >&2; exit 1
    fi
    sentinel="$(cat "$r7/recycled.sentinel")"
    [[ "$(cat "$calls")" -ge 2 && -n "$sentinel" ]] || { echo 'r7 C1: second census was not reached' >&2; exit 1; }
    if grep -Eq -- "-(TERM|KILL) $sentinel$" "$signals" 2>/dev/null || ! builtin kill -0 "$sentinel" 2>/dev/null; then
      echo 'r7 C1: replacement sentinel was signalled' >&2; exit 1
    fi
    builtin kill -KILL "$sentinel" 2>/dev/null || true
  )

  # A fork first observed in a later, leader-bracketed census is admitted and
  # receives TERM then KILL. It is absent from the initial validated snapshot.
  (
    cat >"$r7/ignore-term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"$1"
while :; do sleep 1; done
EOF
    cat >"$r7/late-fork-leader.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
trap 'bash "$1" "$2" & echo $! >"$3"' USR1
printf '%s\n' "$$" >"$4"
while :; do sleep 1; done
EOF
    chmod +x "$r7/ignore-term.sh" "$r7/late-fork-leader.sh"
    setsid "$r7/late-fork-leader.sh" "$r7/ignore-term.sh" "$r7/late-child-ready" "$r7/late-child" "$r7/late-leader" &
    leader=$!
    for _ in {1..100}; do [[ -s "$r7/late-leader" ]] && break; sleep 0.02; done
    read -r pgid sid < <(ps -o pgid= -o sid= -p "$leader")
    lane_set late-fork provider codex cwd "$r7" detached_session_receipts '[]'
    tmux_record_lane_detached_session late-fork pane "$leader" "$pgid" "$sid" "$(process_start_ticks "$leader")"
    eval "$(declare -f tmux_detached_session_receipt_group_members | sed '1s/tmux_detached_session_receipt_group_members/r7_late_real_members/')"
    calls="$r7/late.calls"; printf '0\n' >"$calls"
    tmux_detached_session_receipt_group_members() {
      local n members
      n=$(( $(cat "$calls") + 1 )); printf '%s\n' "$n" >"$calls"
      if [[ "$n" -eq 2 ]]; then
        builtin kill -USR1 "$leader"
        for _ in {1..150}; do [[ -s "$r7/late-child-ready" && -s "$r7/late-child" ]] && break; sleep 0.02; done
      fi
      members="$(r7_late_real_members "$1")" || return
      [[ "$n" -eq 1 ]] && printf '%s\n' "$members" >"$r7/late-initial"
      printf '%s\n' "$members"
    }
    signals="$r7/late.signals"
    kill() { printf '%s\n' "$*" >>"$signals"; builtin kill "$@"; }
    tmux_kill_owned_lane_detached_sessions late-fork
    child="$(cat "$r7/late-child")"
    if awk -F $'\t' -v child="$child" '$1 == child { found = 1 } END { exit !found }' "$r7/late-initial" \
        || ! grep -Fxq -- "-TERM $child" "$signals" || ! grep -Fxq -- "-KILL $child" "$signals"; then
      echo 'r7 C1: late TERM-resistant fork was not admitted and escalated' >&2; exit 1
    fi
    if builtin kill -0 "$child" 2>/dev/null || builtin kill -0 "$leader" 2>/dev/null; then
      echo 'r7 C1: late-fork group was not retired' >&2; exit 1
    fi
  )

  # A fork that appears only after the final pre-KILL census cannot be safely
  # signalled. Its nonempty post-KILL census must keep retirement uncertain.
  (
    setsid bash -c 'trap "" TERM; while :; do sleep 1; done' &
    leader=$!
    for _ in {1..100}; do process_start_ticks "$leader" >/dev/null 2>&1 && break; sleep 0.02; done
    read -r pgid sid < <(ps -o pgid= -o sid= -p "$leader")
    lane_set post-kill-fork provider codex cwd "$r7" detached_session_receipts '[]'
    tmux_record_lane_detached_session post-kill-fork pane "$leader" "$pgid" "$sid" "$(process_start_ticks "$leader")"
    eval "$(declare -f tmux_detached_session_receipt_group_members | sed '1s/tmux_detached_session_receipt_group_members/r7_post_kill_real_members/')"
    eval "$(declare -f tmux_detached_session_receipt_signal_members | sed '1s/tmux_detached_session_receipt_signal_members/r7_post_kill_real_signal/')"
    tmux_detached_session_receipt_group_members() {
      if [[ -s "$r7/post-kill-sentinel" ]]; then
        printf '%s\t%s\n' "$(cat "$r7/post-kill-sentinel")" "$(cat "$r7/post-kill-sentinel-ticks")"
      else
        r7_post_kill_real_members "$1"
      fi
    }
    tmux_detached_session_receipt_signal_members() {
      r7_post_kill_real_signal "$@"
      [[ "$2" == KILL && ! -e "$r7/post-kill-sentinel" ]] || return 0
      setsid bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
      sentinel=$!; printf '%s\n' "$sentinel" >"$r7/post-kill-sentinel"
      for _ in {1..100}; do process_start_ticks "$sentinel" >/dev/null 2>&1 && break; sleep 0.02; done
      process_start_ticks "$sentinel" >"$r7/post-kill-sentinel-ticks"
    }
    receipt="$(tmux_lane_detached_session_receipts post-kill-fork)"
    if tmux_kill_detached_session_receipt_if_owned post-kill-fork "$receipt"; then
      echo 'r7 C1: post-KILL fork was reported retired' >&2; exit 1
    fi
    sentinel="$(cat "$r7/post-kill-sentinel")"
    builtin kill -0 "$sentinel" 2>/dev/null || { echo 'r7 C1: post-KILL sentinel unexpectedly died' >&2; exit 1; }
    builtin kill -KILL "$sentinel" 2>/dev/null || true
  )

  # A pending fallback launch converts to a receipt, exits normally, and can be
  # stopped/reaped without being left uncertain. This is the no-systemd shape:
  # no scope receipt is present and the durable fallback record remains.
  mkdir -p "$r7/normal-home"
  printf ':\n' >"$r7/normal-home/.bash_profile"
  cat >"$r7/normal-provider" <<EOF
#!/usr/bin/env bash
printf running >$(printf '%q' "$r7/normal-provider-running")
while [[ ! -e $(printf '%q' "$r7/normal-provider-gate") ]]; do sleep 0.02; done
EOF
  chmod +x "$r7/normal-provider"
  lane_set normal provider codex cwd "$r7" status live spawn_submitted true
  tmux_cgroup_scope_unavailable_reason() { printf fixture-unavailable; }
  HOME="$r7/normal-home" tmux_run_owned_lane_shell_command normal "$r7" pane "bash -lc $(printf '%q' "$r7/normal-provider")" &
  normal_wrapper=$!
  for _ in {1..150}; do [[ -e "$r7/normal-provider-running" ]] && break; sleep 0.02; done
  [[ -z "$(tmux_lane_pending_detached_launches normal)" && -n "$(tmux_lane_detached_session_receipts normal)" ]] \
    || { echo 'r7 lifecycle: pending launch did not convert to a receipt' >&2; exit 1; }
  touch "$r7/normal-provider-gate"; wait "$normal_wrapper"
  "$root/bin/waspflow" close normal --status abandoned --reason fixture --stop >/dev/null
  "$root/bin/waspflow" reap normal --keep-worktree --no-archive >/dev/null
  jq -e '.status == "reaped" and .close_stop_state == "stop-requested" and .reap_cleanup_state == "complete" and ((.pending_detached_launches // []) | length == 0) and ((.cgroup_scope_receipts // []) | length == 0)' \
    "$(lane_state_file normal)" >/dev/null || { echo 'r7 lifecycle: completed fallback lane remained uncertain' >&2; exit 1; }

  # B2 close path: an unreadable full census is uncertain, not a successful
  # stop. Other ps invocations remain real so this reaches detached cleanup.
  setsid bash -c 'trap "" TERM; while :; do sleep 1; done' &
  observed=$!
  for _ in {1..100}; do process_start_ticks "$observed" >/dev/null 2>&1 && break; sleep 0.02; done
  read -r pgid sid < <(ps -o pgid= -o sid= -p "$observed")
  lane_set census-failed provider codex cwd "$r7" detached_session_receipts '[]'
  tmux_record_lane_detached_session census-failed pane "$observed" "$pgid" "$sid" "$(process_start_ticks "$observed")"
  mkdir -p "$r7/ps-bin"
  cat >"$r7/ps-bin/ps" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' -eo '* ]] && exit 77
exec /usr/bin/ps "$@"
EOF
  chmod +x "$r7/ps-bin/ps"
  if PATH="$r7/ps-bin:$PATH" "$root/bin/waspflow" close census-failed --status abandoned --reason fixture --stop >"$r7/close.out" 2>"$r7/close.err"; then
    echo 'r7 B2: close reported success after failed census' >&2; exit 1
  fi
  [[ -z "$(lane_get census-failed close_stop_state)" && -z "$(lane_get census-failed park_retirement_state)" ]] \
    || { echo 'r7 B2: failed close claimed a completed stop' >&2; exit 1; }
  grep -Fq 'receipt identity continuity is uncertain' "$r7/close.err" \
    || { echo 'r7 B2: failed close did not report uncertainty' >&2; exit 1; }
  builtin kill -KILL "$observed" 2>/dev/null || true

  # Exercise the real park and escalation branches without their provider/tmux
  # eligibility preconditions obscuring the census fault. The `ps` shim fails
  # only the all-process census used by detached cleanup; receipt identity and
  # every other observation still use the host ps.
  source <(sed '$ d' "$root/bin/waspflow")
  source "$root/lib/escalation.sh"
  setsid bash -c 'trap "" TERM; while :; do sleep 1; done' &
  observed=$!
  for _ in {1..100}; do process_start_ticks "$observed" >/dev/null 2>&1 && break; sleep 0.02; done
  read -r pgid sid < <(command ps -o pgid= -o sid= -p "$observed")
  lane_set park-failed provider codex cwd "$r7" detached_session_receipts '[]'
  tmux_record_lane_detached_session park-failed pane "$observed" "$pgid" "$sid" "$(process_start_ticks "$observed")"
  lane_is_parkable() { return 0; }
  tmux_kill_owned_lane_window() { :; }
  ps() { [[ " $* " == *' -eo '* ]] && return 77; command ps "$@"; }
  PARK_NEEDS_ADOPT=0 PARK_CLEARS_BARRIER=0
  if _park_one_locked park-failed fixture; then
    echo 'r7 B2: park reported success after failed census' >&2; exit 1
  fi
  [[ "$(lane_get park-failed park_retirement_state)" == uncertain && "$(lane_get park-failed status)" != parked ]] \
    || { echo 'r7 B2: park claimed a completed retirement' >&2; exit 1; }
  unset -f ps

  lane_set escalation-failed provider codex model old effort low op_mode standard session_id old-session arm_generation 0 segment_index 0 \
    pending_transition "$(jq -cn '{id:"fixture-transition",from_arm:{provider:"codex",model:"old",effort:"low"},to_arm:{provider:"codex",model:"new",effort:"high",mode:"standard"},from_generation:"0",from_session:"old-session",mode:"in_place",trigger:"fixture",provisional_session:{session_id:"new-session",rollout:"",ownership:{}}}')"
  tmux_record_lane_detached_session escalation-failed pane "$observed" "$pgid" "$sid" "$(process_start_ticks "$observed")"
  tmux_kill_window_if_owned() { :; }
  ps() { [[ " $* " == *' -eo '* ]] && return 77; command ps "$@"; }
  set +e
  escalate_commit_locked escalation-failed false
  escalation_rc=$?
  set -e
  [[ "$escalation_rc" -eq 2 && "$(lane_get escalation-failed old_arm_retirement_state)" == uncertain && "$(lane_get escalation-failed status)" == live ]] \
    || { echo 'r7 B2: escalation claimed old-arm retirement after failed census' >&2; exit 1; }
  unset -f ps
  builtin kill -KILL "$observed" 2>/dev/null || true
)
