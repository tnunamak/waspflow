#!/usr/bin/env bash
#
# artifacts.sh — durable-artifact discipline for a lane. Generalizes the
# hard-won "never silently lose a worker's output" guarantees of a prior
# single-provider workstream harness to both providers, automatic-by-default.
#
# What it gives every lane, with NO flags:
#   - prompt.txt           : the exact task the worker received
#   - git-status-before.txt: working-tree state at spawn (if cwd is a git repo)
#   - git-status-after.txt  : working-tree state when the lane goes idle
#   - git-diff.txt          : the change the worker actually made (stat + patch)
#   These answer "what did this agent change?" — the cheapest accountability.
#
# What it adds ONLY when you pass `--report <path>` to spawn (opt-in deliverable):
#   - On idle, verify the report exists and is substantial (>= REPORT_MIN_BYTES).
#   - If missing, run ONE recovery pass: resume the session with write tools
#     disabled and ask it to reconstruct the report from transcript + git diff.
#   - Finalize an honest result: succeeded | recovered | report_missing | failed.
#
# The lane's `result` field (in state.json) is the single source of truth a
# caller / `wait` keys on. Without a report contract, result is succeeded once
# the provider reports idle (the agent finished its turn cleanly).

WASPFLOW_REPORT_MIN_BYTES="${WASPFLOW_REPORT_MIN_BYTES:-200}"

# Capture working-tree state at spawn. cwd may not be a git repo — that's fine,
# we just skip git capture and note it. Args: lane cwd prompt
artifacts_capture_before() {
  local lane="$1" cwd="$2" prompt="$3" dir
  dir="$(lane_dir "$lane")"
  printf '%s\n' "$prompt" >"$dir/prompt.txt"
  if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$cwd" status --short >"$dir/git-status-before.txt" 2>&1 || true
    lane_set "$lane" git_tracked "true"
  else
    : >"$dir/git-status-before.txt"
    lane_set "$lane" git_tracked "false"
  fi
}

# Capture the change the worker made. Idempotent — safe to call repeatedly (on
# each idle). Args: lane
artifacts_capture_after() {
  local lane="$1" cwd dir
  cwd="$(lane_get "$lane" cwd)"
  dir="$(lane_dir "$lane")"
  [[ "$(lane_get "$lane" git_tracked)" == "true" ]] || return 0
  git -C "$cwd" status --short >"$dir/git-status-after.txt" 2>&1 || true
  {
    git -C "$cwd" --no-pager diff --stat 2>/dev/null
    echo
    git -C "$cwd" --no-pager diff 2>/dev/null
  } >"$dir/git-diff.txt" 2>&1 || true
}

# Is the lane's required report present and substantial?
artifacts_report_present() {
  local lane="$1" report sz
  report="$(lane_get "$lane" report)"
  [[ -n "$report" ]] || return 0   # no contract → vacuously satisfied
  [[ -f "$report" ]] || return 1
  sz="$(wc -c <"$report" 2>/dev/null | tr -d ' ')"
  [[ -n "$sz" && "$sz" -ge "$WASPFLOW_REPORT_MIN_BYTES" ]]
}

# Finalize a lane once it is idle: capture the diff, enforce the report contract
# (with one recovery pass), and stamp an honest `result`. Echoes the result.
# Idempotent: if already finalized to a terminal result, returns it unchanged.
# Args: lane provider
artifacts_finalize() {
  local lane="$1" provider="$2" existing report
  existing="$(lane_get "$lane" result)"
  case "$existing" in succeeded|recovered|failed|report_missing) echo "$existing"; return 0 ;; esac

  artifacts_capture_after "$lane"

  report="$(lane_get "$lane" report)"
  if [[ -z "$report" ]]; then
    # No deliverable contract — finishing the turn cleanly IS success.
    lane_set "$lane" result "succeeded"
    echo "succeeded"; return 0
  fi

  if artifacts_report_present "$lane"; then
    lane_set "$lane" result "succeeded" report_state "present"
    echo "succeeded"; return 0
  fi

  # Report missing → one recovery pass (unless recovery disabled).
  if [[ "$(lane_get "$lane" no_recovery)" == "true" ]]; then
    lane_set "$lane" result "report_missing" report_state "absent"
    warn "lane '$lane': required report missing and recovery disabled ($report)"
    echo "report_missing"; return 0
  fi

  warn "lane '$lane': required report missing — attempting one recovery pass"
  # Recovery MUST use the provider's headless resume path, not in-pane steering:
  # the recovery prompt is multi-line and a TUI send-keys mangles it. Kill the
  # live window first (the worktree stays — recovery needs it to read the diff
  # and write the report) so the provider's revise takes the headless branch.
  if tmux_window_exists "$lane"; then
    tmux kill-window -t "$(tmux_window_target "$lane")" 2>/dev/null || true
    # Wait for the session to become resumable. A just-killed interactive session
    # may not have flushed its session log yet; resuming too soon yields
    # "No conversation found". Poll the provider's resumability up to ~8s.
    local k
    for k in $(seq 1 8); do
      if "${provider}_session_resumable" "$lane" 2>/dev/null; then break; fi
      sleep 1
    done
  fi
  _artifacts_recover "$lane" "$provider" "$report"

  if artifacts_report_present "$lane"; then
    lane_set "$lane" result "recovered" report_state "recovered"
    warn "lane '$lane': report reconstructed by recovery pass"
    echo "recovered"; return 0
  fi

  lane_set "$lane" result "failed" report_state "absent"
  err "lane '$lane': report still missing after recovery — result=failed"
  echo "failed"; return 0
}

# Run ONE write-disabled recovery turn to reconstruct the report from evidence.
# Uses the provider's headless revise path (resume the same session). The
# provider adapters disable write tools for recovery via a guarded prompt; for
# Claude we additionally pass --disallowedTools through the revise --arg channel
# if supported. Args: lane provider report_path
_artifacts_recover() {
  local lane="$1" provider="$2" report="$3" cwd transcript dir
  cwd="$(lane_get "$lane" cwd)"
  transcript="$(lane_get "$lane" transcript)"
  dir="$(lane_dir "$lane")"

  local recovery_prompt
  recovery_prompt="Your previous turn finished without writing the required report to:
  $report

Reconstruct that report now from the existing evidence ONLY. Do NOT modify code,
run builds, or make commits — your sole job is to write the report file.

Evidence available to you:
  - The conversation so far (this session).
  - The change you made: $dir/git-diff.txt
  - Working-tree status: $dir/git-status-after.txt

Write a concise report to $report describing what was done and its status. If the
evidence does not support a 'complete' result, say so plainly and state what is
missing. End with the verbatim output of \`git status --short\`."

  # The window has usually exited by finalize time; revise resumes headlessly.
  # If still live, the in-pane steer also works (the agent writes the file).
  "${provider}_revise" "$lane" "$recovery_prompt" "$dir/recovery.log" >/dev/null 2>&1 || true
}
