#!/usr/bin/env bash
#
# worktree.sh — optional git-worktree isolation for a lane. Sourced by core
# consumers. When a lane is spawned with isolation, the agent works in its own
# git worktree so a parallel fleet can't stomp on each other's files.
#
# Isolation is OPT-IN and SAFE-BY-DEFAULT:
#   - Only engages when the spawn cwd is inside a git repo.
#   - Creates a detached worktree on a new branch  waspflow/<lane>.
#   - Records the worktree path in lane state so reap can remove it.
#   - On reap, removes the worktree ONLY if it has no uncommitted changes,
#     unless --force is given (mirrors how the Agent worktree mode auto-cleans
#     only when unchanged). We never silently discard an agent's work.

# Resolve the git repo root for a cwd, or empty if not a repo.
worktree_repo_root() {
  local cwd="$1"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Resolve operator/project policy without creating directories.
worktree_resolve_root() {
  local repo_root="$1" configured requested root
  configured="$(git -C "$repo_root" config --get waspflow.worktreeRoot 2>/dev/null || true)"
  requested="${WASPFLOW_WORKTREE_ROOT:-}"
  for root in "$configured" "$requested"; do
    [[ -z "$root" ]] && continue
    [[ "$root" == /* && -d "$root" ]] || { err "worktree root must be an existing absolute directory: $root"; return 1; }
  done
  [[ -z "$configured" ]] || configured="$(cd "$configured" && pwd -P)" || return 1
  [[ -z "$requested" ]] || requested="$(cd "$requested" && pwd -P)" || return 1
  if [[ -n "$configured" && -n "$requested" && "$configured" != "$requested" ]]; then
    err "worktree root conflicts with project policy: $requested (required: $configured)"; return 1
  fi
  root="${configured:-${requested:-$(dirname "$repo_root")}}"
  root="$(cd "$root" && pwd -P)" || return 1
  [[ -w "$root" && -x "$root" ]] || { err "worktree root is not writable/searchable: $root"; return 1; }
  printf '%s\n' "$root"
}

worktree_resolve_path() {
  local repo_root="$1" leaf="$2" root path
  [[ -n "$leaf" && "$leaf" != . && "$leaf" != .. && "$leaf" != */* && "$leaf" != *$'\n'* && "$leaf" != *$'\r'* ]] \
    || { err "worktree name must be one path component"; return 1; }
  root="$(worktree_resolve_root "$repo_root")" || return 1
  path="${root%/}/$leaf"
  [[ ! -L "$path" ]] || { err "worktree path is a symlink: $path"; return 1; }
  printf '%s\n' "$path"
}


# Create an isolated worktree for a lane rooted at the repo containing $cwd.
# Echoes the worktree absolute path on success; non-zero + message on failure.
# Args: lane cwd [base_commit]
worktree_create() {
  local lane="$1" cwd="$2" base_commit="${3:-}"
  local repo_root branch wt_path
  repo_root="$(worktree_repo_root "$cwd")"
  [[ -n "$repo_root" ]] || { err "worktree isolation requested but '$cwd' is not in a git repo"; return 1; }

  branch="waspflow/$lane"
  wt_path="$(worktree_resolve_path "$repo_root" "$(basename "$repo_root")-waspflow-$lane")" || return 1

  if [[ -e "$wt_path" ]]; then
    err "worktree path already exists: $wt_path (reap the lane or pick a new name)"
    return 1
  fi

  # Preserve the historical HEAD-based command when no explicit base is given.
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    if [[ -n "$base_commit" && "$(git -C "$repo_root" rev-parse "refs/heads/$branch^{commit}" 2>/dev/null)" != "$base_commit" ]]; then
      err "worktree branch $branch does not point to requested --base commit"
      return 1
    fi
    git -C "$repo_root" worktree add "$wt_path" "$branch" >/dev/null 2>&1 \
      || { err "git worktree add (existing branch $branch) failed"; return 1; }
  elif [[ -n "$base_commit" ]]; then
    git -C "$repo_root" worktree add -b "$branch" "$wt_path" "$base_commit" >/dev/null 2>&1 \
      || { err "git worktree add -b $branch from requested --base failed"; return 1; }
  else
    git -C "$repo_root" worktree add -b "$branch" "$wt_path" >/dev/null 2>&1 \
      || { err "git worktree add -b $branch failed"; return 1; }
  fi
  echo "$wt_path"
}

# Remove a lane's worktree. Refuses if dirty unless force=1.
# Args: lane worktree_path repo_root force
worktree_remove() {
  local lane="$1" wt_path="$2" repo_root="$3" force="${4:-0}"
  [[ -n "$wt_path" && -d "$wt_path" ]] || return 0   # nothing to do
  [[ -n "$repo_root" ]] || repo_root="$(worktree_repo_root "$wt_path")"

  if [[ "$force" != "1" ]]; then
    # Dirty = staged/unstaged changes OR untracked files.
    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
      warn "worktree for lane '$lane' has uncommitted changes; NOT removing ($wt_path). Use --force to discard."
      return 1
    fi
  fi
  local force_flag=()
  [[ "$force" == "1" ]] && force_flag=(--force)
  git -C "$repo_root" worktree remove "${force_flag[@]}" "$wt_path" >/dev/null 2>&1 \
    || { warn "git worktree remove failed for $wt_path (left in place)"; return 1; }
  return 0
}
