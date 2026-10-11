# TERM-resistant verification must still finish with a timeout receipt.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-deadline-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/worktree.sh"
  lane_set deadline cwd "$fixture" provider fake
  # Outer watchdog: without KILL escalation the command never ends, so bound
  # the call and kill the resistant loop by its unique marker on expiry.
  started="$(date +%s)"
  ( _artifacts_run_command deadline "$fixture/verify" resistant "trap '' TERM; : $fixture/resistant; while :; do :; done" "$fixture" 1 >"$fixture/state" ) &
  runner=$!
  for _ in {1..100}; do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$runner" 2>/dev/null; then
    pkill -KILL -f "$fixture/resistant" || true; wait "$runner" || true
    echo 'p2 deadline: TERM-resistant verification outlived its deadline' >&2; exit 1
  fi
  wait "$runner"
  (( $(date +%s) - started <= 6 ))
  [[ "$(cat "$fixture/state")" == timeout ]]
  jq -e '.state == "timeout" and .exit_code == 137' "$fixture/verify-result.json" >/dev/null
)

# A SIGKILL before a one-second deadline is a task failure even when it crosses
# a wall-clock second boundary.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-boundary-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  lane_set boundary cwd "$fixture" provider fake
  # Start late in a second so the 0.4 s run ends in the next second.
  until [[ "$(date +%N)" =~ ^8[0-4] ]]; do sleep 0.01; done
  state="$(_artifacts_run_command boundary "$fixture/verify" early-kill 'sleep 0.4; kill -9 $$' "$fixture" 1)"
  [[ "$state" == failed ]]
  jq -e '.state == "failed" and .exit_code == 137' "$fixture/verify-result.json" >/dev/null
)

# An immediate SIGKILL is a task failure under a long deadline. Keep it eligible
# for the baseline oracle instead of treating every 137 as timeout.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-sigkill-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/worktree.sh"
  mkdir "$fixture/repo" "$fixture/worktrees"
  git -C "$fixture/repo" init -q
  git -C "$fixture/repo" config user.name Fixture
  git -C "$fixture/repo" config user.email fixture@example.invalid
  printf 'baseline\n' >"$fixture/repo/input"
  git -C "$fixture/repo" add input
  git -C "$fixture/repo" commit -qm baseline
  fork="$(git -C "$fixture/repo" rev-parse HEAD)"

  lane_set sigkill cwd "$fixture/repo" repo_root "$fixture/repo" worktree_root "$fixture/worktrees" provider fake verify_command 'kill -9 $$' verify_timeout 60
  [[ "$(artifacts_run_verify_checkpoint sigkill)" == failed ]]
  [[ "$(lane_get sigkill verify_failure_class)" == task ]]
  jq -e '.state == "failed" and .exit_code == 137 and .duration_seconds < 60' "$(lane_dir sigkill)/verify-result.json" >/dev/null
  lane_set sigkill verify_fork_point "$fork"
  artifacts_classify_pre_existing sigkill
  [[ "$(lane_get sigkill baseline_oracle_state)" == failed ]]
)
