# TERM-resistant verification must still finish with a timeout receipt.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-deadline-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/worktree.sh"
  lane_set deadline cwd "$fixture" provider fake
  state="$(_artifacts_run_command deadline "$fixture/verify" resistant "trap '' TERM; while :; do :; done" "$fixture" 1)"
  [[ "$state" == timeout ]]
  jq -e '.state == "timeout" and .exit_code == 137' "$fixture/verify-result.json" >/dev/null
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
