# R3-F1 lifecycle/cleanup regressions. Processes are local fakes only; any tmux
# coverage in this slice uses a private socket.
(
  r3f1="$(mktemp -d "$scratch/waspflow-r3-f1-XXXXXX")"
  trap 'rm -rf "$r3f1"' EXIT
  export WASPFLOW_HOME="$r3f1/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  mkdir -p "$WASPFLOW_HOME"

  # C1: if a detached session leader exits while a TERM-resistant descendant
  # remains in its recorded process group, cleanup must leave it uncertain.
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
  child="$(cat "$r3f1/ready.child")"
  read -r recorded_pgid recorded_sid < <(ps -o pgid= -o sid= -p "$recorded_leader")
  lane_set descendants provider fake cwd "$r3f1" detached_session_receipts "[]"
  tmux_record_lane_detached_session descendants pane "$recorded_leader" "$recorded_pgid" "$recorded_sid" "$(process_start_ticks "$recorded_leader")"
  touch "$release"
  wait "$leader" 2>/dev/null || true
  receipt="$(tmux_lane_detached_session_receipts descendants)"
  [[ "$(tmux_detached_session_receipt_group_state "$receipt" || true)" == uncertain ]]
  if tmux_kill_owned_lane_detached_sessions descendants; then
    echo 'r3-f1 C1: uncertain detached descendant was retired' >&2; exit 1
  fi
  kill -KILL "$child" 2>/dev/null || true
  for _ in {1..100}; do [[ "$(tmux_detached_session_receipt_group_state "$receipt" || true)" == gone ]] && break; sleep 0.02; done
  [[ "$(tmux_detached_session_receipt_group_state "$receipt" || true)" == gone ]]

  # B3: detached-session receipt appends take the same state lock as lane_set,
  # so no whole-file update can overtake a concurrent lifecycle update.
  lane_set locked provider fake cwd "$r3f1" durable_field kept
  lock_file="$(lane_dir locked)/.state.lock"
  exec 8>"$lock_file"
  flock 8
  ( tmux_record_lane_detached_session locked pane 1 1 1 1; touch "$r3f1/receipt-done" ) &
  receipt_writer=$!
  sleep 0.1
  [[ ! -e "$r3f1/receipt-done" ]]
  flock -u 8
  wait "$receipt_writer"
  [[ "$(lane_get locked durable_field)" == kept && -n "$(tmux_lane_detached_session_receipts locked)" ]]

  # MEDIUM-3: only the exact untracked report is moved before the normal dirty
  # check.  It enables report-only cleanup but still refuses unrelated work.
  source "$root/lib/worktree.sh"
  report_repo="$r3f1/report-repo"
  git init -q "$report_repo"
  git -C "$report_repo" config user.name Fixture
  git -C "$report_repo" config user.email fixture@example.invalid
  touch "$report_repo/base"; git -C "$report_repo" add base; git -C "$report_repo" commit -qm base
  report_wt="$r3f1/report-worktree"
  git -C "$report_repo" worktree add -q -b report-clean "$report_wt"
  printf 'report\n' >"$report_wt/report.txt"
  [[ "$(worktree_preserve_report_for_cleanup "$report_wt" "$report_wt/report.txt" "$r3f1/reaped-report")" == moved ]]
  [[ ! -e "$report_wt/report.txt" && -s "$r3f1/reaped-report" ]]
  worktree_remove report-clean "$report_wt" "$report_repo" 0
  [[ ! -e "$report_wt" ]]
  dirty_wt="$r3f1/dirty-worktree"
  git -C "$report_repo" worktree add -q -b report-dirty "$dirty_wt"
  printf 'report\n' >"$dirty_wt/report.txt"
  worktree_preserve_report_for_cleanup "$dirty_wt" "$dirty_wt/report.txt" "$r3f1/reaped-report-dirty" >/dev/null
  printf 'real user change\n' >"$dirty_wt/other.txt"
  ! worktree_remove report-dirty "$dirty_wt" "$report_repo" 0
  [[ -d "$dirty_wt" ]]

  # B2: retirement can exclude the freshly-provisioned escalation group while
  # still stopping every earlier execution group.
  lane_set retirement provider fake cwd "$r3f1"
  tmux_record_lane_detached_session retirement pane 1 1 1 1
  tmux_record_lane_detached_session retirement escalation:new 2 2 2 2
  tmux_kill_detached_session_receipt_if_owned() { jq -r .execution <<<"$2" >>"$r3f1/retired"; }
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

  # B10: doctor treats an unavailable remote version probe as an advisory WARN.
  mkdir -p "$r3f1/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$r3f1/bin/codex"
  cat >"$r3f1/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'rev-parse --is-inside-work-tree'*) printf 'true\n' ;;
  *'describe --tags'*) printf 'v0.0.0\n' ;;
  *'rev-list --count'*) printf '0\n' ;;
  *'ls-remote --tags --refs origin'*) exit 1 ;;
  *) command git "$@" ;;
esac
EOF
  chmod +x "$r3f1/bin/codex" "$r3f1/bin/git"
  doctor_output="$(PATH="$r3f1/bin:$PATH" "$root/bin/waspflow" doctor)"
  grep -q 'WARN release version: latest tag unavailable' <<<"$doctor_output"
  grep -q -- '-> ready' <<<"$doctor_output"

  # B12: PID existence alone cannot make a reused headless-writer PID active.
  lane_set reused-headless provider fake cwd "$r3f1" status live \
    headless_revise_state running headless_revise_pid "$$" headless_revise_pid_start_ticks 0
  status_output="$("$root/bin/waspflow" status reused-headless)"
  jq -e '(.headless_revise_active // false) == false and .headless_revise_state == "interrupted"' <<<"$status_output" >/dev/null

  # LOW-2: terminal provider evidence cannot make a completed cleanup look
  # unreaped or recommend another reap operation.
  source "$root/lib/providers/codex.sh"
  source "$root/lib/events.sh"
  printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"done"}}' >"$r3f1/reaped-rollout.jsonl"
  lane_set already-reaped provider codex cwd "$r3f1" status reaped rollout "$r3f1/reaped-rollout.jsonl"
  tmux_window_exists() { return 1; }
  tmux() { [[ "$1" == list-clients ]] && return 0; return 1; }
  jq -e '.classification == "reaped" and .eligibility == "complete" and (.next_action | contains("reap") | not)' <<<"$(lane_inspection_json already-reaped)" >/dev/null

  # LOW-1: the required-report explanation is emitted only when a contract
  # exists; a generic failed lane must not claim a report was required.
  awk '/^    failed\)/,/^      ;;/ { print }' "$root/bin/waspflow" >"$r3f1/failed-result-case"
  grep -q 'if \[\[ -n "$(lane_get "\$lane" report)" \]\]' "$r3f1/failed-result-case"
)
