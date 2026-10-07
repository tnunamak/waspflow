# S5 cleanup fixtures: local Git only; no provider or ambient tmux server.
(
  s5="$(mktemp -d "$scratch/waspflow-s5-cleanup-XXXXXX")"
  trap 'rm -rf "$s5"' EXIT
  export WASPFLOW_HOME="$s5/home" WASPFLOW_ARCHIVE_DIR="$s5/archive"
  source "$root/lib/core.sh"
  source "$root/lib/worktree.sh"
  source "$root/lib/fanin.sh"

  repo="$s5/repo"
  git -C "$s5" init -q repo
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'base\n' >"$repo/example.txt"
  printf 'base\n' >"$repo/removed.txt"
  git -C "$repo" add -A; git -C "$repo" commit -qm base
  git -C "$repo" branch -m main 2>/dev/null || true
  git -C "$repo" checkout -qb waspflow/capture
  printf 'lane body\n' >"$repo/example.txt"
  git -C "$repo" commit -qam lane
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -qb exact
  printf 'lane body\n' >"$repo/example.txt"
  git -C "$repo" commit -qam exact
  git -C "$repo" checkout -q main
  lane_set capture provider fake status live repo_root "$repo"
  [[ "$(fanin_captured capture exact 2>/dev/null)" == CAPTURED ]] \
    || { echo 's5: exact body forward-port was not captured' >&2; exit 1; }

  git -C "$repo" checkout -qb same-name main
  printf 'different implementation\n' >"$repo/example.txt"
  git -C "$repo" commit -qam different
  git -C "$repo" checkout -q main
  [[ "$(fanin_captured capture same-name 2>/dev/null)" == UNKNOWN ]] \
    || { echo 's5: same path with different body was treated as captured' >&2; exit 1; }

  git -C "$repo" checkout -qb waspflow/delete
  rm "$repo/removed.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm delete
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -qb unrelated-delete
  printf 'not a deletion\n' >"$repo/removed.txt"; git -C "$repo" commit -qam unrelated
  git -C "$repo" checkout -q main
  lane_set delete provider fake status live repo_root "$repo"
  [[ "$(fanin_captured delete unrelated-delete 2>/dev/null)" == UNKNOWN ]] \
    || { echo 's5: unproven deletion was treated as captured' >&2; exit 1; }

  git -C "$repo" checkout -qb waspflow/archive main
  printf 'archive one\n' >"$repo/archive.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm archive-one
  git -C "$repo" checkout -q main
  lane_set archive provider fake status live repo_root "$repo"
  fanin_bundle_lane archive >/dev/null
  first="$(lane_get archive archive_bundle)"
  fanin_bundle_lane archive >/dev/null
  [[ "$first" == "$(lane_get archive archive_bundle)" && "$(find "$s5/archive" -type f -name '*.bundle' | wc -l)" -eq 1 ]] \
    || { echo 's5: unchanged branch made another archive' >&2; exit 1; }
  git -C "$repo" checkout -q waspflow/archive
  printf 'archive two\n' >>"$repo/archive.txt"; git -C "$repo" commit -qam archive-two
  git -C "$repo" checkout -q main
  fanin_bundle_lane archive >/dev/null
  [[ "$(lane_get archive archive_bundle)" != "$first" && "$(find "$s5/archive" -type f -name '*.bundle' | wc -l)" -eq 2 ]] \
    || { echo 's5: changed branch did not make one new archive' >&2; exit 1; }

  wt_one="$s5/worktree-one"; wt_two="$s5/worktree-two"; owned_tmp="$s5/owned-tmp"; report="$s5/report"; transferred="$s5/transferred"
  mkdir -p "$wt_one" "$wt_two" "$owned_tmp" "$transferred"; : >"$report"; : >"$s5/ambient-tmp-sentinel"
  lane_set resources provider fake status live cwd "$repo" worktree "$wt_one"
  resource_ledger_register resources worktree "$wt_one" owned
  resource_ledger_register resources worktree "$wt_two" retained
  resource_ledger_register resources tmpdir "$owned_tmp" owned
  resource_ledger_register resources report "$report" retained
  resource_ledger_register resources artifact "$transferred" transferred
  resource_ledger_register resources artifact "$s5/unknown" unknown
  resource_ledger_inventory resources | jq -e '.owned|length == 2' >/dev/null
  resource_ledger_inventory resources | jq -e '(.retained|length) == 2 and (.transferred|length) == 1 and (.unknown|length) == 1' >/dev/null
  [[ -e "$s5/ambient-tmp-sentinel" ]] || { echo 's5: ledger touched ambient temporary data' >&2; exit 1; }

  # Closing is an accounting action.  Only the explicit close-and-stop form
  # calls proven-owned worker cleanup; the unrelated sentinel remains intact.
  eval "$(sed -n '/^cmd_close()/,/^}/p' "$root/bin/waspflow")"
  foreign="$s5/foreign-worker"; : >"$foreign"
  tmux_owned_lane_window_exists() { [[ "$1" == resources ]]; }
  tmux_kill_owned_lane_window() { : >"$s5/owned-worker-stopped"; }
  tmux_kill_owned_lane_scopes() { : >"$s5/owned-scope-stopped"; }
  cmd_close resources --status abandoned --reason 'fixture close' >/dev/null
  [[ ! -e "$s5/owned-worker-stopped" && -e "$foreign" ]] \
    || { echo 's5: close alone stopped a worker or touched a foreign resource' >&2; exit 1; }
  cmd_close resources --status abandoned --reason 'fixture stop' --stop >/dev/null
  [[ -e "$s5/owned-worker-stopped" && -e "$s5/owned-scope-stopped" && -e "$foreign" ]] \
    || { echo 's5: close --stop did not isolate owned worker cleanup' >&2; exit 1; }
)
