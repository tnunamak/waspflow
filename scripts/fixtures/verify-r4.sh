# R4 release blockers: detached ownership, recovery, Codex receipt, and ledgers.
(
  r4="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r4-XXXXXX")"
  trap 'jobs -pr | xargs -r kill -KILL 2>/dev/null || true; rm -rf "$r4"' EXIT
  export WASPFLOW_HOME="$r4/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"

  # The post-setsid receipt step sources core.sh only in a subshell. Its strict
  # shell options must not change the provider command that follows it.
  mkdir "$r4/fast-home"; printf ':\n' >"$r4/fast-home/.bash_profile"
  lane_set handshake provider fake cwd "$r4"
  HOME="$r4/fast-home" tmux_lane_login_shell handshake pane "false; touch $(printf '%q' "$r4/provider-command-ran")"
  [[ -e "$r4/provider-command-ran" ]] || { echo 'r4 C1: receipt handshake leaked strict shell options' >&2; exit 1; }

  # C1: a receipt whose PID and group have been reused but whose start ticks
  # differ cannot signal the unrelated setsid sentinel.
  setsid bash -c 'exec 9<> <(:); while :; do read -t 1 -u 9 || :; done' &
  reused_sentinel=$!
  sleep 0.05
  read -r reused_pgid reused_sid < <(ps -o pgid= -o sid= -p "$reused_sentinel")
  reused_ticks="$(process_start_ticks "$reused_sentinel")"
  lane_set reused provider fake cwd "$r4"
  reused_receipt="$(jq -cn --argjson pid "$reused_sentinel" --argjson pgid "$reused_pgid" --argjson sid "$reused_sid" --argjson ticks "$((reused_ticks + 1))" '{pid:$pid,pgid:$pgid,sid:$sid,start_ticks:$ticks}')"
  if tmux_kill_detached_session_receipt_if_owned reused "$reused_receipt"; then
    echo 'r4 C1: stale receipt was accepted for signalling' >&2; exit 1
  fi
  kill -0 "$reused_sentinel" 2>/dev/null || { echo 'r4 C1: stale receipt signalled reused sentinel' >&2; exit 1; }
  kill -KILL "$reused_sentinel" 2>/dev/null || true

  # A pre-setsid sample names the caller's inherited group. It is invalid and
  # must never turn into a group signal; the caller-group sentinel survives.
  sleep 30 & inherited_sentinel=$!
  read -r inherited_pgid inherited_sid < <(ps -o pgid= -o sid= -p "$inherited_sentinel")
  inherited_receipt="$(jq -cn --argjson pid "$inherited_sentinel" --argjson pgid "$inherited_pgid" --argjson sid "$inherited_sid" --argjson ticks "$(process_start_ticks "$inherited_sentinel")" '{pid:$pid,pgid:$pgid,sid:$sid,start_ticks:$ticks}')"
  lane_set inherited provider fake cwd "$r4"
  if tmux_kill_detached_session_receipt_if_owned inherited "$inherited_receipt"; then
    echo 'r4 C1: pre-setsid receipt was accepted for signalling' >&2; exit 1
  fi
  kill -0 "$inherited_sentinel" 2>/dev/null || { echo 'r4 C1: pre-setsid receipt signalled caller group' >&2; exit 1; }
  kill -KILL "$inherited_sentinel" 2>/dev/null || true

  # A real session leader remains a valid authority through TERM, so its
  # TERM-resistant child causes the bounded KILL path to run and retire both.
  cat >"$r4/term-child.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
exec 9<> <(:); while :; do read -t 1 -u 9 || :; done
EOF
  chmod +x "$r4/term-child.sh"
  setsid bash -c '
    bash "$1" &
    printf "%s %s\n" "$$" "$!" >"$2"
    exec 9<> <(:); while :; do read -t 1 -u 9 || :; done
  ' -- "$r4/term-child.sh" "$r4/leader-and-child" &
  for _ in {1..100}; do [[ -s "$r4/leader-and-child" ]] && break; sleep 0.02; done
  read -r detached_leader detached_child <"$r4/leader-and-child"
  read -r detached_pgid detached_sid < <(ps -o pgid= -o sid= -p "$detached_leader")
  lane_set detached provider fake cwd "$r4" detached_session_receipts '[]'
  tmux_record_lane_detached_session detached pane "$detached_leader" "$detached_pgid" "$detached_sid" "$(process_start_ticks "$detached_leader")"
  signal_log="$r4/signals"
  kill() {
    [[ "$1" == -TERM || "$1" == -KILL ]] && printf '%s\n' "$1" >>"$signal_log"
    builtin kill "$@"
  }
  tmux_kill_owned_lane_detached_sessions detached
  grep -Fx -- -TERM "$signal_log" >/dev/null && grep -Fx -- -KILL "$signal_log" >/dev/null \
    || { echo 'r4 C1: valid detached group did not receive TERM then KILL' >&2; exit 1; }
  ! kill -0 "$detached_leader" 2>/dev/null && ! kill -0 "$detached_child" 2>/dev/null \
    || { echo 'r4 C1: valid detached group survived TERM/KILL retirement' >&2; exit 1; }
)
