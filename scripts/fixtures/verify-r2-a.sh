# R2-A core/cleanup/escalation regressions. All tmux work stays on this private
# socket; the provider is a local heartbeat script, never a live CLI.
(
  r2a="$(mktemp -d "$scratch/waspflow-r2-a-XXXXXX")"
  r2a_socket="wf-r2-a-$$-$RANDOM"
  cleanup_r2a() {
    command tmux -L "$r2a_socket" kill-session -t waspflow 2>/dev/null || true
    rm -rf "$r2a"
  }
  trap cleanup_r2a EXIT
  export WASPFLOW_HOME="$r2a/home" WASPFLOW_TMUX_SESSION=waspflow WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/escalation.sh"
  tmux() { command tmux -L "$r2a_socket" "$@"; }

  mkdir -p "$WASPFLOW_HOME" "$r2a/cwd"
  tmux new-session -d -s waspflow -n _waspflow_home

  # #1: a mismatched receipt plus a still-present pane is uncertain, never
  # evidence that it is absent and safe to reap.
  owned="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:1 -n uncertain 'exec sleep 30')"
  tmux set-option -w -t "$owned" @waspflow_home "$(cd "$WASPFLOW_HOME" && pwd -P)"
  tmux set-option -w -t "$owned" @waspflow_lane_uuid 11111111-1111-1111-1111-111111111111
  lane_set uncertain lane_uuid 11111111-1111-1111-1111-111111111111 tmux_session waspflow tmux_window "$owned" tmux_pane_pid 1
  ! tmux_window_exists uncertain
  tmux_lane_window_cleanup_uncertain uncertain

  # #13 + #14: explicit legacy adoption tags exactly one untagged pane, using
  # new_uuid's /proc fallback rather than requiring uuidgen.
  legacy="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:2 -n legacy 'exec sleep 30')"
  lane_set legacy status live lane_uuid '' tmux_session '' tmux_window '' tmux_pane_pid ''
  tmux_adopt_legacy_lane_window legacy
  tmux_owned_lane_window_exists legacy
  [[ "$(lane_get legacy lane_uuid)" =~ ^[0-9a-f-]{36}$ ]]

  # #2: a provisional hydration timeout preserves the committed lane and does
  # not invoke its lane-wide scope/window cleanup.
  lane_set provisional provider codex status escalating spawn_submitted true
  tmux_kill_owned_lane_scopes() { : >"$r2a/unexpected-scope-kill"; }
  tmux_kill_owned_lane_window() { : >"$r2a/unexpected-window-kill"; }
  mkdir "$r2a/slow-home"; printf 'sleep 3\n' >"$r2a/slow-home/.bash_profile"
  set +e
  HOME="$r2a/slow-home" WASPFLOW_SHELL_STARTUP_TIMEOUT_SECONDS=1 tmux_lane_login_shell provisional escalation:fixture true
  provisional_rc=$?
  set -e
  [[ "$provisional_rc" -ne 0 && "$(lane_get provisional status)" == escalating ]]
  [[ ! -e "$r2a/unexpected-scope-kill" && ! -e "$r2a/unexpected-window-kill" ]]
  source "$root/lib/core.sh"

  # #3: transitions retain the old window's full ownership receipt so commit
  # can retire it under the strict ownership contract.
  lane_set transition provider codex model old effort low op_mode standard session_id old-session arm_generation 0 segment_index 0 tmux_session waspflow tmux_window @old tmux_pane_pid 42 lane_uuid 22222222-2222-2222-2222-222222222222
  escalate_run_locked() { transition_receipt="$(lane_get "$1" pending_transition)"; }
  escalate_begin_locked transition false '{"provider":"codex","model":"new","effort":"high"}' default 0 in_place fixture note false none
  [[ "$(jq -r .from_waspflow_home <<<"$transition_receipt")" == "$(cd "$WASPFLOW_HOME" && pwd -P)" ]]
  [[ "$(jq -r .from_waspflow_lane_uuid <<<"$transition_receipt")" == 22222222-2222-2222-2222-222222222222 ]]
  unset -f escalate_run_locked

  # #19: PID reuse no longer blocks reap; only the start-tick identity counts.
  sleep 30 & reused=$!
  lane_set headless headless_revise_pid "$reused" headless_revise_pid_start_ticks 0
  ! lane_headless_writer_active headless
  kill "$reused"; wait "$reused" 2>/dev/null || true

  # #4: run the real login wrapper with a fake provider on an unavailable
  # systemd host. Its setsid-created heartbeat dies through the recorded group.
  mkdir "$r2a/bin"
  printf '#!/usr/bin/env bash\nwhile :; do date +%%s%%N >>"${R2A_HEARTBEAT:?}"; sleep 0.05; done\n' >"$r2a/bin/codex"
  chmod +x "$r2a/bin/codex"
  lane_set detached provider codex status live
  export R2A_HEARTBEAT="$r2a/heartbeat"
  mkdir "$r2a/fast-home"; printf ':\n' >"$r2a/fast-home/.bash_profile"
  HOME="$r2a/fast-home" WASPFLOW_SHELL_STARTUP_TIMEOUT_SECONDS=3 tmux_lane_login_shell detached pane "$r2a/bin/codex" &
  wrapper=$!
  for _ in {1..60}; do [[ -s "$R2A_HEARTBEAT" ]] && break; sleep 0.05; done
  [[ -s "$R2A_HEARTBEAT" ]]
  receipt="$(tmux_lane_detached_session_receipts detached)"
  tmux_detached_session_receipt_live "$receipt"
  child="$(jq -r .pid <<<"$receipt")"
  tmux_kill_owned_lane_detached_sessions detached
  for _ in {1..30}; do kill -0 "$child" 2>/dev/null || break; sleep 0.05; done
  ! kill -0 "$child" 2>/dev/null
  wait "$wrapper" 2>/dev/null || true
)
