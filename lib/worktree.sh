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

# Create an isolated worktree for a lane rooted at the repo containing $cwd.
# Echoes the worktree absolute path on success; non-zero + message on failure.
# Args: lane cwd
worktree_create() {
  local lane="$1" cwd="$2"
  local repo_root branch wt_path
  repo_root="$(worktree_repo_root "$cwd")"
  [[ -n "$repo_root" ]] || { err "worktree isolation requested but '$cwd' is not in a git repo"; return 1; }

  branch="waspflow/$lane"
  # Place worktrees as siblings of the repo to avoid nesting inside it.
  wt_path="$(dirname "$repo_root")/$(basename "$repo_root")-waspflow-$lane"

  if [[ -e "$wt_path" ]]; then
    err "worktree path already exists: $wt_path (reap the lane or pick a new name)"
    return 1
  fi

  # Branch off the current HEAD of the repo.
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_root" worktree add "$wt_path" "$branch" >/dev/null 2>&1 \
      || { err "git worktree add (existing branch $branch) failed"; return 1; }
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
