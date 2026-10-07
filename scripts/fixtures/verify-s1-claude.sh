#!/usr/bin/env bash
# Offline checks for the Claude provider safe-settle contract.

set -euo pipefail

run_verify_s1_claude() {
  local root="${WASPFLOW_FIXTURE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local base
  base="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-s1-claude.XXXXXX")"

  (
    export WASPFLOW_HOME="$base/state" CLAUDE_PROJECTS_DIR="$base/projects"
    source "$root/lib/core.sh"
    source "$root/lib/providers/claude.sh"
    local sid=11111111-2222-3333-4444-555555555555 project child rc sleeper
    sid=11111111-2222-3333-4444-555555555555
    project="$CLAUDE_PROJECTS_DIR/project"
    child="$project/$sid/subagents/agent-test.jsonl"
    mkdir -p "$(dirname "$child")"
    printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$project/$sid.jsonl"
    lane_set claude-s1 provider claude status live session_id "$sid" cwd "$base"

    # A quiet unfinished child stays unsafe even when its process evidence is
    # live or unknown; only a terminal child is a positive idle control.
    sleep 30 & sleeper=$!
    printf '%s\n' '{"isSidechain":true,"type":"assistant","message":{"stop_reason":"tool_use"}}' >"$child"
    touch -d '46 seconds ago' "$child"
    set +e; claude_is_idle claude-s1; rc=$?; set -e
    [[ "$rc" -eq 2 ]] || { echo 'claude S1: stale live child settled' >&2; exit 1; }
    kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true
    set +e; claude_is_idle claude-s1; rc=$?; set -e
    [[ "$rc" -eq 2 ]] || { echo 'claude S1: stale child with unknown process evidence settled' >&2; exit 1; }
    printf '%s\n' '{"isSidechain":true,"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$child"
    claude_is_idle claude-s1 || { echo 'claude S1: terminal child did not settle' >&2; exit 1; }
  )

  (
    export WASPFLOW_HOME="$base/trust-state"
    source "$root/lib/core.sh"
    source "$root/lib/providers/claude.sh"
    local keys=""
    sleep() { :; }
    tmux() {
      [[ "$1" == send-keys ]] || return 0
      keys+=" ${*: -1}"
      [[ "${*: -1}" != Enter ]] || S1_TRUST_PANE='Welcome back'
    }
    _claude_pane() { printf '%s\n' "${S1_TRUST_PANE:-}"; }
    S1_TRUST_PANE=$'1. No, exit\n2. Yes, I trust this folder'
    _claude_clear_trust_prompt target || { echo 'claude S1: numbered affirmative was not cleared' >&2; exit 1; }
    [[ "$keys" == *' 2 Enter'* && "$keys" != *' 1 '* ]] || { echo 'claude S1: trust selection was not affirmative-only' >&2; exit 1; }

    keys=""; S1_TRUST_PANE=$'No, exit\nYes, I trust this folder'
    if _claude_clear_trust_prompt target; then
      echo 'claude S1: unknown trust highlight was accepted' >&2; exit 1
    fi
    [[ "$keys" != *Enter* ]] || { echo 'claude S1: unknown trust highlight sent Enter' >&2; exit 1; }
  )

  (
    export WASPFLOW_HOME="$base/footer-state" CLAUDE_PROJECTS_DIR="$base/footer-projects"
    source "$root/lib/core.sh"
    source "$root/lib/providers/claude.sh"
    local sid=22222222-3333-4444-5555-666666666666 project rc
    project="$CLAUDE_PROJECTS_DIR/project"; mkdir -p "$project"
    printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' >"$project/$sid.jsonl"
    lane_set claude-s1-footer provider claude status live session_id "$sid" cwd "$base" tmux_window @fixture
    tmux_window_exists() { return 0; }
    tmux_window_target() { printf '@fixture\n'; }
    _claude_pane() { printf '%s\n' '1 shell still running'; }
    set +e; claude_is_idle claude-s1-footer; rc=$?; set -e
    [[ "$rc" -eq 2 ]] || { echo 'claude S1: background shell footer settled' >&2; exit 1; }
    _claude_pane() { printf '%s\n' '2 shells still running'; }
    set +e; claude_is_idle claude-s1-footer; rc=$?; set -e
    [[ "$rc" -eq 2 ]] || { echo 'claude S1: plural background shell footer settled' >&2; exit 1; }
    _claude_pane() { return 1; }
    set +e; claude_is_idle claude-s1-footer; rc=$?; set -e
    [[ "$rc" -eq 2 ]] || { echo 'claude S1: unreadable shell footer settled' >&2; exit 1; }
    _claude_pane() { printf '%s\n' 'Ready'; }
    claude_is_idle claude-s1-footer || { echo 'claude S1: cleared shell footer stayed busy' >&2; exit 1; }
  )

  (
    source "$root/lib/selection.sh"
    local warning
    warn() { printf '%s\n' "$*"; }
    warning="$(selection_emit_warnings '{"warnings":["availability_unknown"]}')"
    [[ "$warning" == *'could not be verified'* && "$warning" == *'provider CLI will validate it'* && "$warning" != *'doctor --models'* ]] \
      || { echo 'selection: availability_unknown lacked an explanation' >&2; exit 1; }
  )

  (
    export WASPFLOW_HOME="$base/revise-state"
    source "$root/lib/core.sh"
    source "$root/lib/providers/claude.sh"
    local captured="$base/revise-argv" output="$base/revise-output" rc
    tmux_window_exists() { return 1; }
    billing_preflight_provider() { return 0; }
    mcp_policy_load_lane() { MCP_ARGV=(--strict-mcp-config --mcp-config '{"mcpServers":{}}'); MCP_ENV=(ENABLE_CLAUDEAI_MCP_SERVERS=false); }
    tmux_run_owned_lane_command() {
      printf '%s\n' "$@" >"$captured"
      printf '%s\n' 'partial result' 'Background tasks still running after 600s; terminating.'
    }
    lane_set claude-s1-revise provider claude status live session_id fixture-session cwd "$base" \
      model fixture-model effort high claude_config_dir "$base/profile"
    export ANTHROPIC_API_KEY='never-write-this-value'
    set +e; claude_revise claude-s1-revise continue "$output"; rc=$?; set -e
    [[ "$rc" -eq 3 && "$(cat "$output")" == *'partial result'* ]] \
      || { echo 'claude S1: print ceiling was not incomplete with retained output' >&2; exit 1; }
    grep -Fqx -- '--model' "$captured" && grep -Fqx fixture-model "$captured" \
      && grep -Fqx -- '--effort' "$captured" && grep -Fqx high "$captured" \
      && grep -Fqx -- '--strict-mcp-config' "$captured" && grep -Fqx "CLAUDE_CONFIG_DIR=$base/profile" "$captured" \
      || { echo 'claude S1: stored resume settings were not reasserted' >&2; exit 1; }
    ! grep -Fq "$ANTHROPIC_API_KEY" "$captured" \
      || { echo 'claude S1: API key leaked into resume argv' >&2; exit 1; }
    ANTHROPIC_API_KEY=''
    _claude_auth_env claude-s1-revise
    [[ " ${CLAUDE_AUTH_ENV[*]} " == *' -u ANTHROPIC_API_KEY '* ]] \
      || { echo 'claude S1: empty caller key did not clear inherited key' >&2; exit 1; }
  )

  rm -rf "$base"
}

run_verify_s1_claude
