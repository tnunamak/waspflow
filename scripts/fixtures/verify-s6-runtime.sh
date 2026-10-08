#!/usr/bin/env bash
# S6 runtime ownership fixtures: use one private tmux server and no providers.
set -euo pipefail

(

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}"
fixture="$(mktemp -d "$scratch/waspflow-s6-runtime-XXXXXX")"
socket="wf-s6-$$-$RANDOM"
cleanup() {
  command tmux -L "$socket" kill-session -t waspflow 2>/dev/null || true
  command tmux -L "$socket" kill-session -t unrelated 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT

export WASPFLOW_HOME="$fixture/home" WASPFLOW_TMUX_SESSION=waspflow
source "$root/lib/core.sh"
tmux() { command tmux -L "$socket" "$@"; }

# A public socket override routes core's tmux wrapper through `tmux -L`.
mkdir "$fixture/socket-bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s"\n' "$fixture/socket-args" >"$fixture/socket-bin/tmux"
chmod +x "$fixture/socket-bin/tmux"
PATH="$fixture/socket-bin:$PATH" WASPFLOW_TMUX_SOCKET=fixture-socket WASPFLOW_LIB="$root/lib" \
  bash -c 'source "$WASPFLOW_LIB/core.sh"; tmux list-sessions'
[[ "$(<"$fixture/socket-args")" == '-L fixture-socket list-sessions' ]]

# Missing user-runtime state is an explicit tmux-only fallback, not raw
# systemctl/jq noise.
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
[[ "$(tmux_cgroup_scope_unavailable_reason)" == xdg-runtime-dir-missing ]]

mkdir -p "$WASPFLOW_HOME" "$fixture/cwd"
lane_set lane lane_uuid 11111111-1111-1111-1111-111111111111 cwd "$fixture/cwd" provider codex session_id fixture-session
tmux new-session -d -s waspflow -n _waspflow_home
tmux new-session -d -s unrelated -n waspflow
window="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:1 -n lane "cd $(printf '%q' "$fixture/cwd"); exec bash")"
tmux set-option -w -t "$window" @waspflow_home "$(cd "$WASPFLOW_HOME" && pwd -P)"
tmux set-option -w -t "$window" @waspflow_lane_uuid 11111111-1111-1111-1111-111111111111
tmux set-option -w -t "$window" @waspflow_provider codex
tmux set-option -w -t "$window" @waspflow_session_id fixture-session
tmux_capture_lane_ownership lane "$window"
[[ "$(tmux_window_target lane)" == "$window" ]]

# A missing tag, a foreign tag, and a wrong recorded session have no authority
# to steer or clean up a same-named pane.
tmux set-option -wu -t "$window" @waspflow_home
if tmux_owned_lane_window_target lane >/dev/null; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:50' >&2
  exit 1
fi
tmux set-option -w -t "$window" @waspflow_home "$fixture/foreign"
if tmux_owned_lane_window_target lane >/dev/null; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:52' >&2
  exit 1
fi
tmux set-option -w -t "$window" @waspflow_home "$(cd "$WASPFLOW_HOME" && pwd -P)"
lane_set lane tmux_session unrelated
if tmux_owned_lane_window_target lane >/dev/null; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:55' >&2
  exit 1
fi
lane_set lane tmux_session waspflow

# Restoration accepts only one same-cwd candidate with both durable tags.
tmux kill-window -t "$window"
restored="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:1 -n lane "cd $(printf '%q' "$fixture/cwd"); exec bash")"
tmux set-option -w -t "$restored" @waspflow_home "$(cd "$WASPFLOW_HOME" && pwd -P)"
tmux set-option -w -t "$restored" @waspflow_lane_uuid 11111111-1111-1111-1111-111111111111
tmux set-option -w -t "$restored" @waspflow_provider codex
tmux set-option -w -t "$restored" @waspflow_session_id fixture-session
tmux_reconcile_lane_window lane
[[ "$(lane_get lane tmux_window)" == "$restored" ]]
tmux set-option -wu -t "$restored" @waspflow_lane_uuid
tmux kill-window -t "$restored"
untagged="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:1 -n lane "cd $(printf '%q' "$fixture/cwd"); exec sleep 30")"
if tmux_reconcile_lane_window lane; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:70' >&2
  exit 1
fi
tmux kill-window -t "$untagged"

# A lane session gets the conservative cap; an unrelated session remains alone.
tmux set-option -g history-limit 500000
tmux set-window-option -t unrelated:0 history-limit 500000
tmux_ensure_session
tmux_apply_owned_window_history_limit waspflow:0
[[ "$(tmux show-window-options -v -t waspflow:0 history-limit)" == 100000 ]]
[[ "$(tmux show-window-options -v -t unrelated:0 history-limit)" == 500000 ]]
WASPFLOW_TMUX_HISTORY_LIMIT=0 WASPFLOW_TMUX_HISTORY_LIMIT_EXPLICIT=true
tmux_ensure_session
inherited="$(tmux new-window -d -P -F '#{window_id}' -t waspflow:1 -n inherited)"
tmux_apply_owned_window_history_limit "$inherited"
[[ -z "$(tmux show-window-options -v -t "$inherited" history-limit)" ]]

# Separate homes targeting one server/session choose the same allocation lock,
# so the create path serializes them before inspecting tmux's next window slot.
lock_a="$(WASPFLOW_HOME="$fixture/home-a" tmux_session_allocation_lock)"
lock_b="$(WASPFLOW_HOME="$fixture/home-b" tmux_session_allocation_lock)"
[[ "$lock_a" == "$lock_b" ]]

# A parked headless writer remains a checkout conflict only for the exact PID
# instance recorded at launch; dead and reused identities do not block.
repo="$fixture/repo"; mkdir "$repo"; git -C "$repo" init -q
git -C "$repo" config user.name Fixture; git -C "$repo" config user.email fixture@example.invalid
touch "$repo/file"; git -C "$repo" add file; git -C "$repo" commit -qm base
sleep 30 & writer=$!
lane_set headless cwd "$repo" status parked headless_revise_pid "$writer" \
  headless_revise_pid_start_ticks "$(process_start_ticks "$writer")"
warn_shared_checkout_lanes "$repo" 2>"$fixture/conflict"
grep -q "lane 'headless' is also live" "$fixture/conflict"
kill "$writer"; wait "$writer" 2>/dev/null || true
if lane_headless_writer_active headless; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:103' >&2
  exit 1
fi
sleep 30 & reused=$!
lane_set headless headless_revise_pid "$reused" headless_revise_pid_start_ticks 0
if lane_headless_writer_active headless; then
  echo 'verify: unexpected success at scripts/fixtures/verify-s6-runtime.sh:106' >&2
  exit 1
fi
kill "$reused"; wait "$reused" 2>/dev/null || true

# The hydration watchdog is startup-only: a hung login shell becomes durable
# failure, while a healthy command runs past the same short deadline.
lane_set startup provider codex cwd "$fixture/cwd"
tmux_kill_owned_lane_scopes() { :; }
tmux_kill_owned_lane_window() { :; }
fake_home="$fixture/fake-home"; mkdir "$fake_home"
printf 'sleep 5\n' >"$fake_home/.bash_profile"
set +e
HOME="$fake_home" WASPFLOW_SHELL_STARTUP_TIMEOUT_SECONDS=1 tmux_lane_login_shell startup 'true'
timeout_rc=$?
set -e
[[ "$timeout_rc" -ne 0 && "$(lane_get startup startup_blocker)" == shell-hydration-timeout ]]
printf ':\n' >"$fake_home/.bash_profile"
HOME="$fake_home" WASPFLOW_SHELL_STARTUP_TIMEOUT_SECONDS=5 tmux_lane_login_shell startup 'sleep 6; printf done >'"$(printf '%q' "$fixture/done")"
[[ -s "$fixture/done" ]]

)
