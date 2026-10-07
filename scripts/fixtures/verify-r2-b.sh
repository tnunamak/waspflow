#!/usr/bin/env bash
# r2-b: revision-generation and exec-publication regressions.
(
  r2b="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r2-b-XXXXXX")"
  trap 'rm -rf "$r2b"' EXIT
  export WASPFLOW_HOME="$r2b/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/fanin.sh"
  source "$root/lib/exec.sh"
  source "$root/lib/providers/deepseek.sh"

  # Exercise the command's real sequencing with only a fake provider: the
  # report baseline must precede a synchronous headless reply, and a failed
  # reply must not leave an earlier success current.
  eval "$(sed -n '/^_revise_one()/,/^}/p' "$root/bin/waspflow")"
  tmux_reconcile_lane_window() { return 0; }
  tmux_window_exists() { return 1; }
  load_provider() { :; }

  printf old >"$r2b/report"
  lane_set revision-ok provider codex cwd "$r2b" git_tracked false result succeeded report "$r2b/report" report_contract_version 2 report_before_signature "$(artifacts_report_signature "$r2b/report")"
  codex_revise() { printf new >"$r2b/report"; }
  _revise_one revision-ok "write it" ""
  [[ "$(WASPFLOW_RECOVERY_POLICY=disabled artifacts_finalize revision-ok codex)" == succeeded ]]

  lane_set revision-failed provider codex cwd "$r2b" git_tracked false result succeeded
  codex_revise() { return 1; }
  if _revise_one revision-failed "fail" ""; then
    echo 'r2-b revise: failed provider revision succeeded' >&2; exit 1
  fi
  [[ "$(lane_get revision-failed result)" == failed ]]
  [[ "$(artifacts_finalize revision-failed codex)" == failed ]]

  # DeepSeek's receipt makes failed/no-session runs idle; finalization must use
  # that terminal evidence. An unconfirmed initial task has the same no-report
  # failure boundary.
  for outcome in failed no_session; do
    lane="deepseek-$outcome"
    lane_set "$lane" provider deepseek cwd "$r2b" git_tracked false result "" spawn_submitted true
    printf '{"phase":"completion","outcome":"%s"}\n' "$outcome" >"$(_deepseek_receipt_file "$lane")"
    [[ "$(artifacts_finalize "$lane" deepseek)" == failed ]]
  done
  lane_set unsubmitted provider codex cwd "$r2b" git_tracked false result "" status spawn_failed spawn_submitted false
  [[ "$(artifacts_finalize unsubmitted codex)" == failed ]]

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
  artifacts_emit_exec_receipt_v1() { :; }

  # Exact small/machine-readable answers and error-shaped classifications are
  # useful; only whitespace fails without replacing the existing destination.
  for answer in null denied x; do
    _exec_codex() { printf '%s' "$answer" >"$5"; }
    exec_run --provider codex --cwd "$r2b" -o "$r2b/$answer.out" -- prompt
    [[ "$(cat "$r2b/$answer.out")" == "$answer" ]]
  done
  printf OLD >"$r2b/old.out"
  _exec_codex() { printf ' \n\t ' >"$5"; }
  if exec_run --provider codex --cwd "$r2b" -o "$r2b/old.out" -- prompt; then
    echo 'r2-b exec: whitespace output succeeded' >&2; exit 1
  fi
  [[ "$(cat "$r2b/old.out")" == OLD ]]
  _exec_codex() { printf 'Error: provider unavailable' >"$5"; }
  exec_run --provider codex --cwd "$r2b" -o "$r2b/old.out" -- prompt
  [[ "$(cat "$r2b/old.out")" == 'Error: provider unavailable' ]]
  _exec_codex() { printf 'Error: missing configuration\nFix: set PROJECT_ROOT.' >"$5"; }
  exec_run --provider codex --cwd "$r2b" -o "$r2b/explained-error.out" -- prompt
  grep -Fq 'Fix: set PROJECT_ROOT.' "$r2b/explained-error.out"

  # A path can become a directory after preflight. The staged file must neither
  # count as published nor remain hidden inside that directory.
  _exec_codex() { printf NEW >"$5"; mkdir "$r2b/raced.out"; }
  if exec_run --provider codex --cwd "$r2b" -o "$r2b/raced.out" -- prompt; then
    echo 'r2-b exec: directory race succeeded' >&2; exit 1
  fi
  [[ "$(cat "$r2b/raced.out.partial")" == NEW ]]
  [[ -z "$(find "$r2b/raced.out" -maxdepth 1 -type f -name '.waspflow-output.*' -print)" ]]

  # A pre-existing `.partial` directory is also not a publication target. Keep
  # the staged file at its exact retained path instead of hiding it inside that
  # directory under an inaccurate `.partial` warning.
  mkdir "$r2b/double-race.out.partial"
  _exec_codex() { printf DOUBLE >"$5"; mkdir "$r2b/double-race.out"; }
  if exec_run --provider codex --cwd "$r2b" -o "$r2b/double-race.out" -- prompt; then
    echo 'r2-b exec: double directory race succeeded' >&2; exit 1
  fi
  [[ -z "$(find "$r2b/double-race.out.partial" -maxdepth 1 -type f -name '.waspflow-output.*' -print)" ]]
  [[ -n "$(find "$r2b" -maxdepth 1 -type f -name '.waspflow-output.*' -print)" ]]

  # A publication failure must keep the staged provider output reachable as
  # `.partial`; the old path cleared its identity before this cleanup branch.
  _exec_codex() { printf PARTIAL >"$5"; }
  mv() {
    if [[ "${1:-}" == -f && "${3:-}" == "$r2b/mv-failure.out" ]]; then return 1; fi
    command mv "$@"
  }
  if exec_run --provider codex --cwd "$r2b" -o "$r2b/mv-failure.out" -- prompt; then
    echo 'r2-b exec: forced publication failure succeeded' >&2; exit 1
  fi
  unset -f mv
  [[ "$(cat "$r2b/mv-failure.out.partial")" == PARTIAL ]]

  # Reproduce a directory created in the small interval after partial-output
  # preflight but before `mv`: retain and report the helper's relocated path.
  _exec_codex() { printf TOCTOU >"$5"; mkdir "$r2b/partial-race.out"; }
  mv() {
    if [[ "${1:-}" == -f && "${3:-}" == "$r2b/partial-race.out.partial" ]]; then
      mkdir "$3"
    fi
    command mv "$@"
  }
  if exec_run --provider codex --cwd "$r2b" -o "$r2b/partial-race.out" -- prompt 2>"$r2b/partial-race.err"; then
    echo 'r2-b exec: partial publication race succeeded' >&2; exit 1
  fi
  unset -f mv
  partial_stage="$(find "$r2b/partial-race.out.partial" -maxdepth 1 -type f -name '.waspflow-output.*' -print)"
  [[ -n "$partial_stage" && "$(cat "$partial_stage")" == TOCTOU ]]
  grep -Fq "partial output retained at $partial_stage" "$r2b/partial-race.err"
)
