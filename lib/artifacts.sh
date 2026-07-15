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
#   - On idle, verify the report exists, is substantial (>= REPORT_MIN_BYTES),
#     and for new lanes was created or changed after spawn.
#   - If missing, run ONE recovery pass: resume with workspace-write and, only
#     when required, the normalized external report parent; reconstruct the
#     report from transcript + git diff.
#   - Finalize an honest result: succeeded | recovered | report_missing | failed.
#
# What it adds ONLY when you pass `--verify <cmd>` to spawn:
#   - `waspflow verify <lane>` runs the optional prepare command and verification
#     command in the lane cwd without closing its window or worktree.
#   - Reap reuses that checkpoint when its workspace fingerprint still matches;
#     otherwise it runs the contract before cleanup.
#   - Write local receipts for the command, stdout, stderr, and JSON result.
#   - Promote a report-satisfied lane from succeeded/recovered to verified, or
#     stamp verify_failed when the verification contract does not pass.
#
# The lane's `result` field (in state.json) is the single source of truth a
# caller / `wait` keys on. Without a report or verify contract, result is
# succeeded once the provider reports idle (the agent finished its turn cleanly).

WASPFLOW_REPORT_MIN_BYTES="${WASPFLOW_REPORT_MIN_BYTES:-200}"

# Normalize the path once at the command boundary. Providers receive this exact
# value in their prompt and reap checks this same value; no adapter should have
# to reinterpret a user-supplied report name.
# Args: worker_cwd report_path
artifacts_normalize_report_path() {
  local cwd="$1" report="$2" absolute
  if [[ "$report" == /* ]]; then
    absolute="$report"
  else
    absolute="$cwd/$report"
  fi
  if command -v realpath >/dev/null 2>&1; then
    if realpath -m -- "$absolute"; then
      return 0
    fi
  fi

  # Keep the fallback dependency-free for systems without realpath. It can
  # still resolve an existing parent physically; a missing parent is rejected
  # rather than handing providers a path whose normalization we cannot prove.
  local parent base
  parent="$(dirname "$absolute")"
  base="$(basename "$absolute")"
  [[ -d "$parent" ]] || return 1
  printf '%s/%s\n' "$(cd -P "$parent" && pwd -P)" "$base"
}

artifacts_report_contract_block() {
  local report="$1"
  cat <<EOF
Waspflow report contract (exact normalized path):
Write the required deliverable to this exact path:
$report
Do not infer a filename, substitute another path, or overwrite an unrelated report.
EOF
}

# Append the contract in one shared place. The exact block check keeps a caller
# that already composed this prompt from duplicating the contract on a revise or
# recovery pass. Provider adapters only receive the resulting string as an argv
# value or literal pasted text; they never shell-assemble the path themselves.
artifacts_report_prompt() {
  local message="$1" report="${2:-}" block
  [[ -n "$report" ]] || { printf '%s' "$message"; return 0; }
  block="$(artifacts_report_contract_block "$report")"
  if [[ "$message" == *"$block"* ]]; then
    printf '%s' "$message"
    return 0
  fi
  printf '%s\n\n%s' "$message" "$block"
}

# Capture enough identity to distinguish a report written by this lane from a
# substantial file that happened to exist before it started. Content changes
# catch normal rewrites; nanosecond mtime/inode changes catch same-content
# rewrites without requiring a report format or marker in user-authored files.
artifacts_report_signature() {
  local report="$1" checksum metadata
  [[ -f "$report" ]] || { printf '%s\n' absent; return 0; }
  checksum="$(cksum <"$report" | awk '{print $1 ":" $2}')"
  metadata="$(stat -c '%Y:%y:%s:%i' "$report" 2>/dev/null \
    || stat -f '%m:%z:%i' "$report" 2>/dev/null || true)"
  [[ -n "$metadata" ]] || return 1
  printf 'file:%s:%s\n' "$checksum" "$metadata"
}

# Capture working-tree state at spawn. cwd may not be a git repo — that's fine,
# we just skip git capture and note it. Args: lane cwd prompt
artifacts_capture_before() {
  local lane="$1" cwd="$2" prompt="$3" dir report
  dir="$(lane_dir "$lane")"
  printf '%s\n' "$prompt" >"$dir/prompt.txt"
  report="$(lane_get "$lane" report)"
  if [[ -n "$report" ]]; then
    lane_set "$lane" report_contract_version "2" \
      report_before_signature "$(artifacts_report_signature "$report")"
  fi
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
  local lane="$1" report sz before current
  report="$(lane_get "$lane" report)"
  [[ -n "$report" ]] || return 0   # no contract → vacuously satisfied
  [[ -f "$report" ]] || { lane_set "$lane" report_state "absent"; return 1; }
  sz="$(wc -c <"$report" 2>/dev/null | tr -d ' ')"
  [[ -n "$sz" && "$sz" -ge "$WASPFLOW_REPORT_MIN_BYTES" ]] || {
    lane_set "$lane" report_state "insubstantial"
    return 1
  }
  if [[ "$(lane_get "$lane" report_contract_version)" == "2" ]]; then
    before="$(lane_get "$lane" report_before_signature)"
    current="$(artifacts_report_signature "$report")"
    if [[ -z "$before" || "$before" == "$current" ]]; then
      lane_set "$lane" report_state "unchanged"
      return 1
    fi
  fi
  return 0
}

# Finalize a lane once it is idle: capture the diff, enforce the report contract
# (with one recovery pass), and stamp an honest `result`. Echoes the result.
# Idempotent: if already finalized to a terminal result, returns it unchanged.
# Args: lane provider
artifacts_finalize() {
  local lane="$1" provider="$2" existing report
  existing="$(lane_get "$lane" result)"
  case "$existing" in
    succeeded|recovered|failed|report_missing|verified|verify_failed|abandoned) echo "$existing"; return 0 ;;
    "") ;;   # not finalized yet — proceed to compute the result below
    *)
      # A NON-EMPTY but UNRECOGNIZED result means the state was tampered with or
      # written by an incompatible version. Do NOT launder it into "succeeded"
      # (that would fabricate a success). Surface it honestly.
      lane_set "$lane" result "corrupt_result" prior_result "$existing"
      echo "corrupt_result"; return 0
      ;;
  esac

  # A lane the operator already closed out via `close --status abandoned` (or
  # superseded) is DONE, by explicit human/orchestrator decision — its actual
  # deliverable state is irrelevant and must not be judged. Without this gate,
  # reap ran the report-recovery pass (a live/headless RESUME of the worker,
  # asking it to keep working) against a lane the caller declared a dead end,
  # and — if no report contract existed at all — stamped "succeeded" outright.
  # Both are false-success/false-progress reports on a lane that was explicitly
  # abandoned. `outcome` (fan-in ledger) is intentionally separate from `result`
  # (deliverable honesty); this is the one place they must interact, since an
  # abandoned lane's deliverable contract is moot by definition.
  local outcome; outcome="$(lane_outcome "$lane")"
  case "$outcome" in
    abandoned|superseded)
      artifacts_capture_after "$lane"
      lane_set "$lane" result "abandoned"
      echo "abandoned"; return 0
      ;;
  esac

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
    local report_failure_state; report_failure_state="$(lane_get "$lane" report_state)"
    lane_set "$lane" result "report_missing" report_state "${report_failure_state:-absent}"
    warn "lane '$lane': required report missing and recovery disabled ($report)"
    echo "report_missing"; return 0
  fi

  warn "lane '$lane': required report missing or unchanged at the exact contracted path ($report) — attempting one recovery pass"
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

  local report_failure_state; report_failure_state="$(lane_get "$lane" report_state)"
  lane_set "$lane" result "failed" report_state "${report_failure_state:-absent}"
  err "lane '$lane': report still missing after recovery — result=failed"
  echo "failed"; return 0
}

# Return a content-sensitive fingerprint for a Git workspace. It includes HEAD,
# tracked staged/unstaged changes, and untracked file paths/content. A missing or
# non-Git workspace deliberately has no fingerprint and therefore no reusable
# checkpoint: rerunning the oracle is safer than claiming freshness we cannot
# establish.
# Args: cwd
artifacts_workspace_fingerprint() {
  local cwd="$1"
  [[ -d "$cwd" ]] || return 1
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  {
    git -C "$cwd" rev-parse HEAD 2>/dev/null || printf 'no-head\n'
    git -C "$cwd" diff --binary HEAD 2>/dev/null
    while IFS= read -r -d '' path; do
      printf '%s\0' "$path"
      git -C "$cwd" hash-object -- "$path" 2>/dev/null || printf 'unreadable\n'
    done < <(git -C "$cwd" ls-files --others --exclude-standard -z)
  } | git hash-object --stdin
}

# Return true|false|unknown for the verification command's likely test surface.
# Isolated lanes record their exact fork at spawn; older/non-isolated lanes fall
# back to HEAD + the working tree when possible, which is useful but cannot prove
# what changed since the worker started and is therefore reported as unknown.
# The surface is intentionally heuristic: conventional test/spec/verify path
# names plus path-like tokens referenced directly by the verify command.
# Args: lane verify_command
artifacts_verify_test_files_changed() {
  local lane="$1" command="$2" cwd fork changed path referenced=0
  cwd="$(lane_get "$lane" cwd)"
  [[ -d "$cwd" ]] || { printf 'unknown\n'; return 0; }
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'unknown\n'; return 0;
  }
  fork="$(lane_get "$lane" verify_fork_point)"
  [[ -n "$fork" ]] && git -C "$cwd" cat-file -e "$fork^{commit}" 2>/dev/null || {
    printf 'unknown\n'; return 0;
  }
  changed="$({
    git -C "$cwd" diff --name-only "$fork...HEAD"
    git -C "$cwd" diff --name-only HEAD
    git -C "$cwd" ls-files --others --exclude-standard
  } | sort -u)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if grep -Eqi '(^|/)(test|tests|spec|specs|verify)(/|$|[._-])|(^|/)[^/]*(test|spec|verify)[^/]*$' <<<"$path"; then
      printf 'true\n'; return 0
    fi
    if [[ "$command" == *"$path"* ]]; then referenced=1; fi
  done <<<"$changed"
  [[ "$referenced" -eq 1 ]] && printf 'true\n' || printf 'false\n'
}

# Add checkpoint metadata to the verify receipt and state. Receipt mutation is
# centralized here so explicit verify and reap cannot drift in their evidence.
# Args: lane failure_class test_files_changed workspace_fingerprint
_artifacts_record_verify_checkpoint() {
  local lane="$1" failure_class="$2" test_files_changed="$3" fingerprint="$4" epoch tmp
  local result_file="$(lane_dir "$lane")/verify-result.json"
  epoch="$(date +%s)"
  tmp="${result_file}.tmp.$$"
  jq --arg failure_class "$failure_class" \
    --arg verify_test_files_changed "$test_files_changed" \
    '. + {failure_class:$failure_class, verify_test_files_changed:$verify_test_files_changed}' \
    "$result_file" >"$tmp" && mv "$tmp" "$result_file"
  lane_set "$lane" verify_failure_class "$failure_class" \
    verify_test_files_changed "$test_files_changed" \
    verify_checkpoint_epoch "$epoch" \
    verify_checkpoint_fingerprint "$fingerprint" \
    verify_epoch "$epoch"
}

# A checkpoint is fresh only when its recorded Git workspace fingerprint exactly
# matches the current one. This deliberately treats non-Git workspaces as stale.
# Args: lane
artifacts_verify_checkpoint_fresh() {
  local lane="$1" checkpoint fingerprint cwd
  checkpoint="$(lane_get "$lane" verify_checkpoint_epoch)"
  fingerprint="$(lane_get "$lane" verify_checkpoint_fingerprint)"
  [[ -n "$checkpoint" && -n "$fingerprint" ]] || return 1
  cwd="$(lane_get "$lane" cwd)"
  [[ -d "$cwd" ]] || return 1
  [[ "$(artifacts_workspace_fingerprint "$cwd" 2>/dev/null || true)" == "$fingerprint" ]]
}

# Run the prepare/verify contract once, without changing lane lifecycle/result.
# Echoes passed|failed|timeout|infra. Every path writes verify receipts and a
# checkpoint marker; callers decide whether that outcome should promote result.
# Args: lane
artifacts_run_verify_checkpoint() {
  local lane="$1" verify_command prepare_command verify_name verify_timeout cwd dir
  local verify_state prepare_state failure_class test_files_changed fingerprint
  verify_command="$(lane_get "$lane" verify_command)"
  [[ -n "$verify_command" ]] || return 3

  cwd="$(lane_get "$lane" cwd)"
  dir="$(lane_dir "$lane")"
  verify_name="$(lane_get "$lane" verify_name)"
  verify_name="${verify_name:-verify}"
  verify_timeout="$(lane_get "$lane" verify_timeout)"
  verify_timeout="${verify_timeout:-1800}"
  prepare_command="$(lane_get "$lane" prepare_command)"

  test_files_changed="$(artifacts_verify_test_files_changed "$lane" "$verify_command")"
  [[ "$test_files_changed" == true ]] || warn "verify: lane '$lane' test-surface changes are $test_files_changed (heuristic; not a gate)"

  if [[ -n "$prepare_command" ]]; then
    prepare_state="$(_artifacts_run_command "$lane" "$dir/prepare" "prepare" "$prepare_command" "$cwd" "$verify_timeout")"
    lane_set "$lane" prepare_state "$prepare_state"
    case "$prepare_state" in
      passed) ;;
      *)
        failure_class="prepare"
        [[ "$prepare_state" == timeout ]] && failure_class="timeout"
        [[ ! -d "$cwd" || "$(lane_get "$lane" prepare_exit_code)" == 127 ]] && failure_class="infra"
        _artifacts_write_skipped_verify "$lane" "$verify_name" "$verify_command" "$cwd" "prepare_$prepare_state"
        fingerprint="$(artifacts_workspace_fingerprint "$cwd" 2>/dev/null || true)"
        _artifacts_record_verify_checkpoint "$lane" "$failure_class" "$test_files_changed" "$fingerprint"
        echo "$prepare_state"
        return 0
        ;;
    esac
  fi

  verify_state="$(_artifacts_run_command "$lane" "$dir/verify" "$verify_name" "$verify_command" "$cwd" "$verify_timeout")"
  case "$verify_state" in
    passed) failure_class="none" ;;
    timeout) failure_class="timeout" ;;
    *)
      failure_class="task"
      [[ ! -d "$cwd" || "$(lane_get "$lane" verify_exit_code)" == 127 ]] && failure_class="infra"
      ;;
  esac
  fingerprint="$(artifacts_workspace_fingerprint "$cwd" 2>/dev/null || true)"
  _artifacts_record_verify_checkpoint "$lane" "$failure_class" "$test_files_changed" "$fingerprint"
  echo "$verify_state"
}

# Run the lane's optional verification contract for reap and return its final
# result. A fresh explicit checkpoint avoids rerunning a destructive cleanup
# gate; stale/missing checkpoints execute the same shared runner as `verify`.
# Args: lane base_result
artifacts_verify() {
  local lane="$1" base_result="$2" verify_name verify_command cwd verify_state
  case "$base_result" in
    verified|verify_failed) echo "$base_result"; return 0 ;;
  esac
  verify_command="$(lane_get "$lane" verify_command)"
  [[ -n "$verify_command" ]] || { echo "$base_result"; return 0; }
  verify_name="$(lane_get "$lane" verify_name)"; verify_name="${verify_name:-verify}"
  cwd="$(lane_get "$lane" cwd)"

  case "$base_result" in
    succeeded|recovered) ;;
    *)
      _artifacts_write_skipped_verify "$lane" "$verify_name" "$verify_command" "$cwd" "$base_result"
      _artifacts_record_verify_checkpoint "$lane" "none" "unknown" ""
      echo "$base_result"
      return 0
      ;;
  esac

  if artifacts_verify_checkpoint_fresh "$lane"; then
    verify_state="$(lane_get "$lane" verify_state)"
  else
    verify_state="$(artifacts_run_verify_checkpoint "$lane")"
  fi
  case "$verify_state" in
    passed)
      lane_set "$lane" result "verified"
      echo "verified"
      return 0
      ;;
    failed|timeout|infra)
      lane_set "$lane" result "verify_failed"
      echo "verify_failed"
      return 0
      ;;
    *)
      lane_set "$lane" result "verify_failed"
      echo "verify_failed"
      return 0
      ;;
  esac
}

_artifacts_write_skipped_verify() {
  local lane="$1" name="$2" command="$3" cwd="$4" reason="$5" dir start
  dir="$(lane_dir "$lane")"
  start="$(date +%s)"
  printf '%s\n' "$command" >"$dir/verify-command.txt"
  : >"$dir/verify-stdout.txt"
  printf 'skipped: %s\n' "$reason" >"$dir/verify-stderr.txt"
  jq -n \
    --arg name "$name" \
    --arg command "$command" \
    --arg cwd "$cwd" \
    --arg state "skipped" \
    '{name:$name, command:$command, cwd:$cwd, exit_code:null, duration_seconds:0, state:$state}' \
    >"$dir/verify-result.json"
  lane_set "$lane" verify_state "skipped" verify_exit_code "" verify_epoch "$start"
}

# Run a shell command in cwd and write receipts with the given prefix:
# <prefix>-command.txt, <prefix>-stdout.txt, <prefix>-stderr.txt,
# <prefix>-result.json. Echoes passed|failed|timeout.
_artifacts_run_command() {
  local lane="$1" prefix="$2" name="$3" command="$4" cwd="$5" timeout_seconds="$6"
  local stdout="${prefix}-stdout.txt" stderr="${prefix}-stderr.txt"
  local command_file="${prefix}-command.txt" result_file="${prefix}-result.json"
  local start end duration rc state timeout_available=0

  printf '%s\n' "$command" >"$command_file"
  start="$(date +%s)"
  # Run in a NON-login shell (bash -c, not -lc). A login shell sources the user's
  # interactive profile (~/.bash_profile etc.), whose side effects are nondeterministic
  # under load — observed: an ssh/gpg-agent hook that prints errors and, in parallel,
  # made even `bash -lc true` exit nonzero ~50% of the time, flakily stamping a
  # passing verify as verify_failed. The verify command must depend only on its own
  # environment, not on interactive login setup. (Real bug + the suite-flake source.)
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout_available=1
    (cd "$cwd" && timeout "$timeout_seconds" bash -c "$command") >"$stdout" 2>"$stderr"
    rc=$?
  else
    warn "verify: coreutils 'timeout' not found; running '$name' without a timeout"
    (cd "$cwd" && bash -c "$command") >"$stdout" 2>"$stderr"
    rc=$?
  fi
  set -e
  end="$(date +%s)"
  duration=$((end - start))

  if [[ "$timeout_available" -eq 1 && "$rc" -eq 124 ]]; then
    state="timeout"
  elif [[ "$rc" -eq 0 ]]; then
    state="passed"
  else
    state="failed"
  fi

  jq -n \
    --arg name "$name" \
    --arg command "$command" \
    --arg cwd "$cwd" \
    --argjson exit_code "$rc" \
    --argjson duration_seconds "$duration" \
    --arg state "$state" \
    '{name:$name, command:$command, cwd:$cwd, exit_code:$exit_code, duration_seconds:$duration_seconds, state:$state}' \
    >"$result_file"

  case "$(basename "$prefix")" in
    verify)
      lane_set "$lane" verify_state "$state" verify_exit_code "$rc" verify_epoch "$end"
      ;;
    prepare)
      lane_set "$lane" prepare_exit_code "$rc" prepare_epoch "$end"
      ;;
  esac
  echo "$state"
}

# Return the physical parent directory where recovery may write its one required
# report. `--report` paths are already absolute in lane state; resolving here
# keeps the capability explicit and prevents a lexical `..` path reaching a
# provider command line. Args: report_path
_artifacts_report_parent() {
  local report="$1" parent
  parent="$(dirname "$report")"
  (cd -P "$parent" && pwd -P)
}

# Run ONE write-enabled recovery turn to reconstruct the report from evidence.
# Uses the provider's headless revise path (resume the same session), granting
# only the normalized parent of the required report when a provider needs an
# explicit external write capability. Args: lane provider report_path
_artifacts_recover() {
  local lane="$1" provider="$2" report="$3" cwd transcript dir report_parent report_parent_raw normalized_report
  cwd="$(lane_get "$lane" cwd)"
  normalized_report="$(artifacts_normalize_report_path "$cwd" "$report")" || {
    err "lane '$lane': cannot normalize required report path for recovery ($report)"
    return 1
  }
  report="$normalized_report"
  transcript="$(lane_get "$lane" transcript)"
  dir="$(lane_dir "$lane")"
  report_parent_raw="$(dirname "$report")"
  if [[ -d "$report_parent_raw" ]]; then
    report_parent="$(_artifacts_report_parent "$report")" || {
      err "lane '$lane': cannot resolve required report parent for recovery ($report)"
      return 1
    }
  elif [[ "$report" == "$cwd/"* ]]; then
    # Preserve ordinary workspace-write behavior for a report whose in-workspace
    # parent does not exist yet: recovery can create it without another grant.
    # Do not make the analogous external case broader by granting an ancestor.
    report_parent=""
  else
    err "lane '$lane': required external report parent does not exist ($report_parent_raw)"
    return 1
  fi

  local recovery_prompt
  recovery_prompt="Your previous turn finished without satisfying the required report contract.
Reconstruct that report now from the existing evidence ONLY. Do NOT modify code,
run builds, or make commits — your sole job is to write the report file.

Evidence available to you:
  - The conversation so far (this session).
  - The change you made: $dir/git-diff.txt
  - Working-tree status: $dir/git-status-after.txt

Write a concise report describing what was done and its status. If the evidence
does not support a 'complete' result, say so plainly and state what is missing.
End with the verbatim output of \`git status --short\`."
  recovery_prompt="$(artifacts_report_prompt "$recovery_prompt" "$report")"

  # The window has usually exited by finalize time; revise resumes headlessly.
  # If still live, the in-pane steer also works (the agent writes the file).
  "${provider}_revise" "$lane" "$recovery_prompt" "$dir/recovery.log" "$report_parent" >/dev/null 2>&1 || true
}
