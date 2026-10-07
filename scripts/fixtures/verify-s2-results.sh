#!/usr/bin/env bash
# S2: generation-scoped results and fresh exec output.
(
  s2="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-s2-results-XXXXXX")"
  trap 'rm -rf "$s2"' EXIT
  export WASPFLOW_HOME="$s2/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/fanin.sh"
  source "$root/lib/worktree.sh"
  source "$root/lib/exec.sh"
  source "$root/lib/providers/antigravity.sh"

  # A succeeded generation is historical once a later accepted turn begins.
  lane_set generations provider codex cwd "$s2" git_tracked false result ""
  [[ "$(artifacts_finalize generations codex)" == succeeded ]]
  artifacts_begin_turn_generation generations
  [[ "$(lane_get generations result)" == "" && "$(lane_get generations turn_generation)" == 1 ]]
  jq -e '.generation == 0 and .result == "succeeded"' "$(lane_dir generations)/generation-results.jsonl" >/dev/null
  receipt="$(_antigravity_receipt_file generations)"
  printf '%s\n' '{"phase":"completion","outcome":"failed","exit_code":1}' >"$receipt"
  [[ "$(artifacts_finalize generations antigravity)" == failed ]]
  [[ "$(lane_get generations result)" == failed ]]

  # A missing report with recovery disabled never calls a provider.
  lane_set recovery provider codex cwd "$s2" git_tracked false result "" report "$s2/missing" no_recovery true
  _artifacts_recover() { touch "$s2/provider-called"; }
  [[ "$(artifacts_finalize recovery codex)" == report_missing ]]
  [[ ! -e "$s2/provider-called" ]]
  unset -f _artifacts_recover

  # A failed baseline does not erase a candidate's additional failure output.
  mkdir "$s2/repo" "$s2/worktrees"
  git -C "$s2/repo" init -q
  git -C "$s2/repo" config user.name Fixture
  git -C "$s2/repo" config user.email fixture@example.invalid
  printf '#!/usr/bin/env bash\nprintf "A\\n"\nexit 1\n' >"$s2/repo/oracle"
  chmod +x "$s2/repo/oracle"
  git -C "$s2/repo" add oracle && git -C "$s2/repo" commit -qm baseline
  fork="$(git -C "$s2/repo" rev-parse HEAD)"
  printf '#!/usr/bin/env bash\nprintf "A\\nB\\n"\nexit 1\n' >"$s2/repo/oracle"
  lane_set comparator provider codex cwd "$s2/repo" repo_root "$s2/repo" worktree_root "$s2/worktrees" verify_fork_point "$fork" verify_failure_class task verify_command ./oracle verify_timeout 5
  printf 'A\nB\n' >"$(lane_dir comparator)/verify-stdout.txt"
  : >"$(lane_dir comparator)/verify-stderr.txt"
  artifacts_classify_pre_existing comparator
  [[ "$(lane_get comparator verify_failure_class)" == task && "$(lane_get comparator baseline_oracle_reason)" == failure-set-not-compared ]]

  split_after_ddash() {
    FLAGS=(); REST=(); local seen=0 arg
    for arg in "$@"; do
      if [[ "$seen" -eq 0 && "$arg" == -- ]]; then seen=1; continue; fi
      if [[ "$seen" -eq 0 ]]; then FLAGS+=("$arg"); else REST+=("$arg"); fi
    done
  }
  selection_gate_mode() { echo off; }
  is_known_provider() { return 0; }
  load_provider() { :; }
  validate_model() { :; }
  resolve_mcp_policy() { MCP_ARGV_JSON='[]'; MCP_ENV_JSON='{}'; MCP_WARNING=''; }
  codex_preflight() { :; }
  mcp_policy_load_json() { :; }
  billing_path_v1() { echo '{}'; }
  artifacts_emit_exec_receipt_v1() { printf '%s\n' "${12}" >"$s2/exec-receipt"; }

  printf OLD >"$s2/out"
  _exec_codex() { :; }
  if exec_run --provider codex --cwd "$s2" -o "$s2/out" -- prompt; then
    echo 's2 exec: stale output accepted after a no-write success' >&2; exit 1
  fi
  [[ "$(cat "$s2/out")" == OLD ]]
  jq -e '.state == "invalid" or .state == "missing"' "$s2/exec-receipt" >/dev/null
  _exec_codex() { printf 'Permission denied\n' >"$5"; }
  if exec_run --provider codex --cwd "$s2" -o "$s2/out" -- prompt; then
    echo 's2 exec: denial output accepted' >&2; exit 1
  fi
  [[ "$(cat "$s2/out")" == OLD ]]
  _exec_codex() { printf NEW >"$5"; }
  exec_run --provider codex --cwd "$s2" -o "$s2/out" -- prompt
  [[ "$(cat "$s2/out")" == NEW ]]
)
