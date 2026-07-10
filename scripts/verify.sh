#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}"
mkdir -p "$scratch"

bash -n "$root/bin/waspflow" "$root"/lib/*.sh "$root"/lib/providers/*.sh

# Codex effort honesty: xhigh must pass through (never clamp xhigh|max → high)
grep -Eq 'model_reasoning_effort=\$\{?effort\}?' "$root/lib/providers/codex.sh"
grep -Eq 'model_reasoning_effort=\$\{?effort\}?' "$root/lib/exec.sh"
# Grok effort honesty: unsupported values hard-fail (never silent-drop)
grep -Eq "unsupported effort" "$root/lib/providers/grok.sh"
# Generated capabilities-derived effort unions present
test -f "$root/lib/generated/effort-whitelists.sh"
# Lane provenance: --op spawn records policy_version + catalog_ref
grep -Eq 'policy_version' "$root/bin/waspflow"
grep -Eq 'catalog_ref' "$root/bin/waspflow"
! grep -E 'high\|xhigh\|max' "$root/lib/providers/codex.sh"
! grep -E 'high\|xhigh\|max' "$root/lib/exec.sh"

fixture="$(mktemp -d "$scratch/waspflow-verify-XXXXXX")"
state_home="$(mktemp -d "$scratch/waspflow-state-XXXXXX")"

# HERMETIC ISOLATION. The suite must be deterministic regardless of the machine's
# live state. It already isolates WASPFLOW_HOME; it MUST also isolate the tmux
# session, or reap's `tmux_window_exists <lane>` collides with the operator's real
# `waspflow` session (dozens of live windows) and the suite goes flaky. Use a
# unique session name per run and export it so every `bin/waspflow` child inherits
# it. (Per the repo's own rule: tests never touch the production tmux server.)
export WASPFLOW_TMUX_SESSION="waspflow-verify-$$"
cleanup() {
  tmux kill-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null || true
  rm -rf "$fixture" "$state_home"
}
trap cleanup EXIT

# Operating-point resolver (bundled policy pack)
ops_list="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" ops list --task implementation)"
grep -q "implement.standard" <<<"$ops_list"
ops_explain="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" ops explain implement.standard)"
grep -q "provider: claude" <<<"$ops_explain"
ops_json="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" ops resolve implement.standard --json)"
jq -e '.expands_to.provider == "claude" and .expands_to.effort == "medium" and .op == "implement.standard"' <<<"$ops_json" >/dev/null

cd "$fixture"
git init -q
git config user.email test@example.invalid
git config user.name 'Waspflow Test'
printf 'hello\n' > README.md
git add README.md
git commit -q -m init

WASPFLOW_HOME="$state_home" "$root/bin/waspflow" init \
  --profile serious-repo \
  --profile live-stack-mutex \
  --profile openspec

jq -e '
  .lanes.stale_seconds == 14400
  and .reports.globs[0] == "tmp/workstreams/*.md"
  and .blockers.globs[0] == ".git/workstreams/blockers/*"
  and .mutexes[0].file == "tmp/workstreams/current-state.md"
  and .commands[0].command == "openspec validate --all --strict"
' .waspflow/config.json >/dev/null

mkdir -p tmp/workstreams .git/workstreams/blockers
printf -- '- Status: CLOSED\n' > tmp/workstreams/current-state.md
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --no-fail --explain >/tmp/waspflow-verify-closed.txt

printf -- '- Status: OPEN\n' > tmp/workstreams/current-state.md
printf 'blocked\n' > .git/workstreams/blockers/test
set +e
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --explain >/tmp/waspflow-verify-open.txt
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "expected open check rc=2, got $rc" >&2; exit 1; }
grep -q "mutex 'live-stack' is OPEN" /tmp/waspflow-verify-open.txt
grep -q "found .*blockers/test" /tmp/waspflow-verify-open.txt
grep -q "Open mutex:" /tmp/waspflow-verify-open.txt
grep -q "Blocker file:" /tmp/waspflow-verify-open.txt

mkdir -p "$state_home/lanes/old-success"
jq -n --arg cwd "$fixture" '{provider:"codex", status:"reaped", result:"succeeded", cwd:$cwd, origin_cwd:$cwd}' \
  > "$state_home/lanes/old-success/state.json"
mkdir -p "$state_home/lanes/old-abandoned"
jq -n --arg cwd "$fixture" '{provider:"codex", status:"reaped", result:"failed", outcome:"abandoned", outcome_reason:"intentionally dropped", cwd:$cwd, origin_cwd:$cwd}' \
  > "$state_home/lanes/old-abandoned/state.json"
mkdir -p "$state_home/lanes/old-superseded"
jq -n --arg cwd "$fixture" '{provider:"codex", status:"reaped", result:"failed", outcome:"superseded", outcome_by:"better-lane", cwd:$cwd, origin_cwd:$cwd}' \
  > "$state_home/lanes/old-superseded/state.json"
lane_check="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --no-fail)"
grep -q "OK: no lanes for this project" <<<"$lane_check"
mkdir -p "$state_home/lanes/old-open-failed"
jq -n --arg cwd "$fixture" '{provider:"codex", status:"reaped", result:"failed", cwd:$cwd, origin_cwd:$cwd}' \
  > "$state_home/lanes/old-open-failed/state.json"
lane_check="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --no-fail)"
grep -q "lane has failed deliverable: lane=old-open-failed" <<<"$lane_check"
rm -rf "$state_home/lanes/old-open-failed"

long_report="$fixture/R.md"
printf 'ok %.0s' {1..80} > "$long_report"

mkdir -p "$state_home/lanes/verify-true"
jq -n \
  --arg cwd "$fixture" \
  --arg report "$long_report" \
  '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, report:$report, no_recovery:"true", git_tracked:"true", verify_command:"true", verify_name:"unit", verify_timeout:"5"}' \
  > "$state_home/lanes/verify-true/state.json"
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" reap verify-true --no-archive
jq -e '.result == "verified" and .verify_state == "passed" and .verify_exit_code == "0"' \
  "$state_home/lanes/verify-true/state.json" >/dev/null
jq -e '.name == "unit" and .command == "true" and .state == "passed" and .exit_code == 0' \
  "$state_home/lanes/verify-true/verify-result.json" >/dev/null
test -s "$state_home/lanes/verify-true/verify-command.txt"
test -f "$state_home/lanes/verify-true/verify-stdout.txt"
test -f "$state_home/lanes/verify-true/verify-stderr.txt"

mkdir -p "$state_home/lanes/verify-false"
jq -n \
  --arg cwd "$fixture" \
  '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, no_recovery:"true", git_tracked:"true", verify_command:"false", verify_name:"unit", verify_timeout:"5"}' \
  > "$state_home/lanes/verify-false/state.json"
set +e
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" reap verify-false --no-archive >/tmp/waspflow-verify-false.txt 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "expected verify_false reap rc=2, got $rc" >&2; exit 1; }
jq -e '.result == "verify_failed" and .verify_state == "failed" and .verify_exit_code == "1"' \
  "$state_home/lanes/verify-false/state.json" >/dev/null
lane_check="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --no-fail --explain)"
grep -q "lane has failed verification: lane=verify-false" <<<"$lane_check"
grep -q "Failed verification:" <<<"$lane_check"

if command -v timeout >/dev/null 2>&1; then
  mkdir -p "$state_home/lanes/verify-timeout"
  jq -n \
    --arg cwd "$fixture" \
    '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, no_recovery:"true", git_tracked:"true", verify_command:"sleep 2", verify_name:"unit", verify_timeout:"1"}' \
    > "$state_home/lanes/verify-timeout/state.json"
  set +e
  WASPFLOW_HOME="$state_home" "$root/bin/waspflow" reap verify-timeout --no-archive >/tmp/waspflow-verify-timeout.txt 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || { echo "expected verify_timeout reap rc=2, got $rc" >&2; exit 1; }
  jq -e '.result == "verify_failed" and .verify_state == "timeout" and .verify_exit_code == "124"' \
    "$state_home/lanes/verify-timeout/state.json" >/dev/null
fi

mkdir -p "$state_home/lanes/prepare-false"
jq -n \
  --arg cwd "$fixture" \
  '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, no_recovery:"true", git_tracked:"true", prepare_command:"false", verify_command:"true", verify_name:"unit", verify_timeout:"5"}' \
  > "$state_home/lanes/prepare-false/state.json"
set +e
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" reap prepare-false --no-archive >/tmp/waspflow-prepare-false.txt 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "expected prepare_false reap rc=2, got $rc" >&2; exit 1; }
jq -e '.result == "verify_failed" and .prepare_state == "failed" and .verify_state == "skipped"' \
  "$state_home/lanes/prepare-false/state.json" >/dev/null
jq -e '.state == "failed" and .exit_code == 1' "$state_home/lanes/prepare-false/prepare-result.json" >/dev/null
jq -e '.state == "skipped" and .exit_code == null' "$state_home/lanes/prepare-false/verify-result.json" >/dev/null

mkdir -p "$state_home/lanes/no-verify"
jq -n \
  --arg cwd "$fixture" \
  '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, no_recovery:"true", git_tracked:"true"}' \
  > "$state_home/lanes/no-verify/state.json"
WASPFLOW_HOME="$state_home" "$root/bin/waspflow" reap no-verify --no-archive
jq -e '.result == "succeeded" and (.verify_state == null)' "$state_home/lanes/no-verify/state.json" >/dev/null

init_print="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" init --profile live-stack-mutex --print)"
printf '%s\n' "$init_print" | jq -e '.mutexes[0].name == "live-stack"' >/dev/null

demo_preview="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" demo --provider codex --lane preview-only)"
grep -q "waspflow demo --provider codex --lane preview-only" <<<"$demo_preview"

set +e
missing_provider="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" exec -- "hello" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "expected exec without --provider to fail" >&2; exit 1; }
grep -q "exec: --provider is required" <<<"$missing_provider"

set +e
missing_prompt="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" exec --provider codex 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "expected exec without prompt to fail" >&2; exit 1; }
grep -q "exec: a task prompt is required after '--'" <<<"$missing_prompt"

sessions_dir="$(mktemp -d "$scratch/waspflow-codex-sessions-XXXXXX")"
mkdir -p "$sessions_dir/2026/07/01"
same_cwd="$fixture"
cat >"$sessions_dir/2026/07/01/rollout-2026-07-01T00-00-01-11111111-1111-1111-1111-111111111111.jsonl" <<JSONL
{"type":"session_meta","payload":{"id":"11111111-1111-1111-1111-111111111111","cwd":"$same_cwd"}}
{"type":"event_msg","payload":{"type":"user_message","message":"WASPFLOW_LANE_MARKER:lane-a:aaa"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
cat >"$sessions_dir/2026/07/01/rollout-2026-07-01T00-00-02-22222222-2222-2222-2222-222222222222.jsonl" <<JSONL
{"type":"session_meta","payload":{"id":"22222222-2222-2222-2222-222222222222","cwd":"$same_cwd"}}
{"type":"event_msg","payload":{"type":"user_message","message":"WASPFLOW_LANE_MARKER:lane-b:bbb"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
(
  export WASPFLOW_HOME="$state_home"
  export CODEX_SESSIONS_DIR="$sessions_dir"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  lane_set marker-a provider codex status live cwd "$same_cwd" codex_marker "WASPFLOW_LANE_MARKER:lane-a:aaa"
  lane_set marker-b provider codex status live cwd "$same_cwd" codex_marker "WASPFLOW_LANE_MARKER:lane-b:bbb"
  [[ "$(codex_discover_session marker-a)" == "11111111-1111-1111-1111-111111111111" ]]
  [[ "$(codex_discover_session marker-b)" == "22222222-2222-2222-2222-222222222222" ]]
)

# Grok idle/resumable: last turn_* event is turn_ended (MCP noise after is fine).
grok_sessions_dir="$(mktemp -d)"
grok_sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
grok_sdir="$grok_sessions_dir/%2Ftmp%2Fproj/$grok_sid"
mkdir -p "$grok_sdir"
cat >"$grok_sdir/events.jsonl" <<'JSONL'
{"type":"phase_changed","phase":"waiting_for_model"}
{"type":"turn_started","turn_number":0}
{"type":"phase_changed","phase":"streaming_text"}
{"type":"turn_ended","outcome":"completed"}
{"type":"mcp_server_failed"}
JSONL
(
  export WASPFLOW_HOME="$state_home"
  export GROK_SESSIONS_DIR="$grok_sessions_dir"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/grok.sh"
  lane_set grok-idle provider grok status live session_id "$grok_sid" cwd /tmp/proj
  grok_session_resumable grok-idle
  grok_is_idle grok-idle
  # A new turn after turn_ended means not idle.
  printf '%s\n' '{"type":"turn_started","turn_number":1}' >>"$grok_sdir/events.jsonl"
  if grok_is_idle grok-idle; then
    echo "expected grok not idle after turn_started" >&2
    exit 1
  fi
  # is_known_provider accepts grok
  is_known_provider grok
)

# ---------------------------------------------------------------------------
# Reliability hardening (2026-07-09): behavioral coverage for the three
# silent-waste fixes. Each closes a re-run class, so each gets a real test.
# ---------------------------------------------------------------------------

# BUG 3 — guard_cwd: refuse worker cwd '/' unless explicitly overridden.
(
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # cwd '/' must be refused (die -> nonzero) with the default env.
  if ( guard_cwd "/" ) 2>/dev/null; then
    echo "guard_cwd: expected refusal for '/'" >&2; exit 1
  fi
  # ...unless the explicit opt-in is set.
  ( WASPFLOW_ALLOW_ROOT_CWD=1 guard_cwd "/" ) || {
    echo "guard_cwd: override WASPFLOW_ALLOW_ROOT_CWD=1 should permit '/'" >&2; exit 1; }
  # A real project dir must always pass.
  ( guard_cwd "$fixture" ) || { echo "guard_cwd: rejected a real dir" >&2; exit 1; }
)

# BUG 2 — _exec_output_is_useful: reject empty/whitespace/pure-error output;
# accept real short answers (must not false-reject a legit file list).
(
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/exec.sh"
  d="$(mktemp -d "$scratch/waspflow-exec-XXXXXX")"
  printf ''                    > "$d/empty"
  printf '   \n\n\t\n'         > "$d/blank"
  printf 'Execution error\n'   > "$d/err"
  printf 'N/A\n'               > "$d/na"
  printf 'foo.txt\nbar.txt\n'  > "$d/list"     # real short answer — MUST pass
  printf 'a\n'                 > "$d/tiny"      # 2 bytes — MUST pass
  printf 'Execution error: the parser threw on line 5, here is the fix\n' > "$d/mention"  # MUST pass
  for bad in empty blank err na; do
    if _exec_output_is_useful "$d/$bad"; then echo "exec-useful: '$bad' wrongly accepted" >&2; exit 1; fi
  done
  for good in list tiny mention; do
    _exec_output_is_useful "$d/$good" || { echo "exec-useful: '$good' wrongly rejected" >&2; exit 1; }
  done
  rm -rf "$d"
)

# BUG 1 — claude_is_idle gates on active subagents. Fixture matches the real
# on-disk schema: parent <sid>.jsonl + <sid>/subagents/agent-*.jsonl.
(
  export WASPFLOW_HOME="$state_home"
  cproj="$(mktemp -d "$scratch/waspflow-claude-proj-XXXXXX")"
  export CLAUDE_PROJECTS_DIR="$cproj"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/claude.sh"
  sid="cccccccc-dddd-eeee-ffff-000000000000"
  slug="$cproj/-home-proj"
  mkdir -p "$slug/$sid/subagents"
  # Parent ended its turn cleanly.
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn"}}' > "$slug/$sid.jsonl"
  lane_set claude-idle provider claude status live session_id "$sid" cwd /home/proj

  # Case A: no subagents at all -> parent end_turn == idle (rc 0).
  claude_is_idle claude-idle || { echo "claude_is_idle: expected idle with no children" >&2; exit 1; }

  # Case B: a FRESH child mid-turn (last event not end_turn) -> NOT idle (rc 2).
  child="$slug/$sid/subagents/agent-11111111.jsonl"
  printf '%s\n' '{"isSidechain":true,"type":"assistant","message":{"stop_reason":"tool_use"}}' > "$child"
  # (freshly written -> mtime is now; within CLAUDE_SUBAGENT_ACTIVE_SECS)
  set +e; claude_is_idle claude-idle; rc=$?; set -e
  [[ "$rc" -eq 2 ]] || { echo "claude_is_idle: expected rc=2 (children active), got $rc" >&2; exit 1; }

  # Case C: that child finishes cleanly (end_turn) -> idle again (rc 0).
  printf '%s\n' '{"isSidechain":true,"type":"assistant","message":{"stop_reason":"end_turn"}}' > "$child"
  claude_is_idle claude-idle || { echo "claude_is_idle: expected idle after child end_turn" >&2; exit 1; }

  # Case D: a mid-turn child that has gone COLD (mtime old) -> treated as done -> idle.
  printf '%s\n' '{"isSidechain":true,"type":"assistant","message":{"stop_reason":"tool_use"}}' > "$child"
  touch -d '1 hour ago' "$child" 2>/dev/null || touch -t 202001010000 "$child"
  claude_is_idle claude-idle || { echo "claude_is_idle: cold mid-turn child should not block idle" >&2; exit 1; }

  # Case E: parent itself NOT done (no end_turn) -> not idle (rc 1) regardless of children.
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"tool_use"}}' > "$slug/$sid.jsonl"
  set +e; claude_is_idle claude-idle; rc=$?; set -e
  [[ "$rc" -eq 1 ]] || { echo "claude_is_idle: expected rc=1 (parent not done), got $rc" >&2; exit 1; }

  rm -rf "$cproj"
)

# codex_is_idle: last rollout event payload.type == task_complete => idle.
# Codex is a first-class provider; its idle predicate gets behavioral coverage
# too (parity with claude/grok), so `wait` on a Codex lane is proven, not assumed.
(
  export WASPFLOW_HOME="$state_home"
  cxdir="$(mktemp -d "$scratch/waspflow-codex-idle-XXXXXX")"
  export CODEX_SESSIONS_DIR="$cxdir"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  csid="33333333-3333-3333-3333-333333333333"
  mkdir -p "$cxdir/2026/07/09"
  roll="$cxdir/2026/07/09/rollout-2026-07-09T00-00-01-$csid.jsonl"
  same="$fixture"
  # Mid-turn: a task_started with no task_complete yet -> NOT idle.
  cat >"$roll" <<JSONL
{"type":"session_meta","payload":{"id":"$csid","cwd":"$same"}}
{"type":"event_msg","payload":{"type":"user_message","message":"WASPFLOW_LANE_MARKER:cx-idle:zzz"}}
{"type":"event_msg","payload":{"type":"task_started"}}
JSONL
  lane_set cx-idle provider codex status live cwd "$same" codex_marker "WASPFLOW_LANE_MARKER:cx-idle:zzz" rollout "$roll"
  if codex_is_idle cx-idle; then echo "codex_is_idle: expected NOT idle before task_complete" >&2; exit 1; fi
  # Turn completes -> idle.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete"}}' >>"$roll"
  codex_is_idle cx-idle || { echo "codex_is_idle: expected idle after task_complete" >&2; exit 1; }
  rm -rf "$cxdir"
)

# Fan-in ledger — `close` sets outcome + requires provenance; `captured` reports
# CAPTURED/UNIQUE/PARTIAL by CONTENT. Both are trust-critical for fleet cleanup
# yet had no behavioral coverage. Deterministic, no agent needed.
(
  export WASPFLOW_HOME="$state_home"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/fanin.sh"

  # close: unset outcome reads as 'open'.
  lane_set fi-close provider codex status reaped cwd "$fixture"
  [[ "$(lane_outcome fi-close)" == "open" ]] || { echo "close: default outcome should be 'open'" >&2; exit 1; }
  # harvested requires --into provenance.
  if ( fanin_close fi-close harvested "" "" ) 2>/dev/null; then
    echo "close: harvested without --into should fail" >&2; exit 1; fi
  fanin_close fi-close harvested into "PR#42"
  [[ "$(lane_get fi-close outcome)" == "harvested" && "$(lane_get fi-close outcome_into)" == "PR#42" ]] \
    || { echo "close: harvested state not recorded" >&2; exit 1; }
  fanin_close fi-close abandoned reason "dropped for a better approach"
  [[ "$(lane_get fi-close outcome)" == "abandoned" && "$(lane_get fi-close outcome_reason)" == "dropped for a better approach" ]] \
    || { echo "close: abandoned state not recorded" >&2; exit 1; }
  # outcome filter matches.
  fanin_outcome_matches fi-close "harvested,abandoned" || { echo "close: outcome filter should match abandoned" >&2; exit 1; }
  if fanin_outcome_matches fi-close "harvested"; then echo "close: filter should NOT match harvested now" >&2; exit 1; fi

  # captured: build a real git repo, a lane branch that adds a file+symbol, and
  # three refs — one WITH the work (CAPTURED), one WITHOUT (UNIQUE).
  crepo="$(mktemp -d "$scratch/waspflow-captured-XXXXXX")"
  git -C "$crepo" init -q
  git -C "$crepo" config user.email t@e.invalid; git -C "$crepo" config user.name T
  printf 'base\n' > "$crepo/base.txt"; git -C "$crepo" add -A; git -C "$crepo" commit -q -m base
  git -C "$crepo" branch -m main 2>/dev/null || true
  fork="$(git -C "$crepo" rev-parse HEAD)"
  # Lane branch adds a unique file + a unique symbol.
  git -C "$crepo" checkout -q -b waspflow/fi-cap
  printf 'export function laneUniqueSymbol() { return 1 }\n' > "$crepo/lane_added.ts"
  git -C "$crepo" add -A; git -C "$crepo" commit -q -m lane
  # ref WITHOUT the work = the fork point.
  git -C "$crepo" checkout -q main
  # ref WITH the work = a forward-port (cherry-pick, non-merge — ancestry would lie).
  git -C "$crepo" checkout -q -b integrated main
  printf 'export function laneUniqueSymbol() { return 1 }\n' > "$crepo/lane_added.ts"
  git -C "$crepo" add -A; git -C "$crepo" commit -q -m 'forward-port lane work'
  git -C "$crepo" checkout -q main
  lane_set fi-cap provider codex status reaped cwd "$crepo" repo_root "$crepo" origin_cwd "$crepo"

  verdict_cap="$(fanin_captured fi-cap integrated 2>/dev/null)"
  [[ "$verdict_cap" == "CAPTURED" ]] || { echo "captured: expected CAPTURED vs integrated, got '$verdict_cap'" >&2; exit 1; }
  verdict_uniq="$(fanin_captured fi-cap main 2>/dev/null)"
  [[ "$verdict_uniq" == "UNIQUE" ]] || { echo "captured: expected UNIQUE vs fork point, got '$verdict_uniq'" >&2; exit 1; }
  rm -rf "$crepo"
)

# wait/revise stale-idle barrier (2026-07-09, root-caused on a live run). After a
# live revise, wait must NOT honor the PRIOR turn's idle. The barrier keys on the
# provider turn_mark (session-log line count): wait honors idle only once turn_mark
# has advanced past revise_barrier_mark. This drives the REAL cmd_wait against a
# fake provider whose turn_mark + idle we control via sentinel files — the actual
# shipped gate logic, no live agent, no quota.
(
  export WASPFLOW_HOME="$state_home"
  # Register a fake provider adapter in a private lib dir so load_provider finds it.
  fakelib="$(mktemp -d "$scratch/waspflow-fakelib-XXXXXX")"
  mkdir -p "$fakelib/providers"
  cp "$root"/lib/*.sh "$fakelib/"                       # core + siblings
  cp -r "$root/lib/generated" "$fakelib/" 2>/dev/null || true
  ctl="$(mktemp -d "$scratch/waspflow-fakectl-XXXXXX")"  # sentinels: mark + idle
  printf '0\n' > "$ctl/mark"
  cat >"$fakelib/providers/faker.sh" <<PROV
faker_spawn() { :; }
faker_preflight() { :; }
faker_discover_session() { echo "x"; }
faker_session_resumable() { return 0; }
faker_revise() { :; }
# turn_mark and idle are read from control files this test writes.
faker_turn_mark() { cat "$ctl/mark" 2>/dev/null || echo 0; }
faker_is_idle() { [[ -f "$ctl/idle" ]]; }
faker_valid_models() { return 1; }
PROV

  # Source core from the fake lib so lane_set is available here AND lane state is
  # written to the same $state_home the wait subprocess reads.
  export WASPFLOW_LIB="$fakelib"
  # shellcheck disable=SC1090
  source "$fakelib/core.sh"

  run_wait() { WASPFLOW_LIB="$fakelib" WASPFLOW_HOME="$state_home" \
    "$root/bin/waspflow" wait barlane --timeout "$1" --interval 1; }

  # --- Case S1: revise sets barrier=mark; turn NOT started yet (mark unchanged) +
  #     lane already idle (prior turn). wait must NOT return early -> it TIMES OUT.
  lane_set barlane provider faker status live cwd "$fixture" revise_barrier_mark "0"
  : > "$ctl/idle"                 # prior-turn idle is present (the stale trap)
  printf '0\n' > "$ctl/mark"      # turn_mark has NOT advanced
  set +e; run_wait 2 >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 1 ]] || { echo "barrier S1: wait should NOT honor stale idle (want timeout rc1, got $rc)" >&2; exit 1; }

  # --- Case S2: the revised turn ran to completion BEFORE wait — mark advanced and
  #     lane is idle. wait must return FAST (rc0), no false timeout, barrier cleared.
  lane_set barlane revise_barrier_mark "0"
  printf '5\n' > "$ctl/mark"      # turn_mark advanced past the barrier
  : > "$ctl/idle"                 # and the turn is done (idle)
  set +e; t0=$(date +%s); run_wait 30 >/dev/null 2>&1; rc=$?; t1=$(date +%s); set -e
  [[ "$rc" -eq 0 ]] || { echo "barrier S2: wait should honor idle after mark advanced (want rc0, got $rc)" >&2; exit 1; }
  [[ $((t1 - t0)) -lt 10 ]] || { echo "barrier S2: wait false-timed-out ($((t1-t0))s) — stale-flag bug" >&2; exit 1; }
  [[ "$(lane_get barlane revise_barrier_mark)" == "" ]] || { echo "barrier S2: barrier_mark should be cleared" >&2; exit 1; }

  # --- Case: no barrier set (normal wait) -> idle honored immediately.
  lane_set barlane revise_barrier_mark ""
  : > "$ctl/idle"
  set +e; run_wait 5 >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 0 ]] || { echo "barrier: plain wait should honor idle (rc0), got $rc" >&2; exit 1; }

  rm -rf "$fakelib" "$ctl"
)
# Static pins: the barrier wiring must stay present through refactors.
grep -q 'revise_barrier_mark' "$root/bin/waspflow" || { echo "wait/revise: revise_barrier_mark barrier missing" >&2; exit 1; }
grep -q 'turn_mark' "$root/lib/core.sh" || { echo "core: turn_mark not in provider contract" >&2; exit 1; }

# Pin: verify/prepare run in a NON-login shell (bash -c). A login shell (-lc) sources
# the user's interactive profile, which was nondeterministic under load and flakily
# failed passing verify commands. Guard against regressing to -lc.
grep -q 'bash -c "\$command"' "$root/lib/artifacts.sh" || { echo "artifacts: verify must use bash -c (non-login), not -lc" >&2; exit 1; }
! grep -q 'bash -lc "\$command"' "$root/lib/artifacts.sh" || { echo "artifacts: verify regressed to login shell (-lc)" >&2; exit 1; }
# Pin: cmd_spawn ends with an explicit success so a contract-less spawn does not
# exit nonzero (which trained callers to ignore spawn's exit code, hiding real fails).
grep -q 'spawn_submitted' "$root/bin/waspflow" || { echo "spawn: submission-confirmation (spawn_submitted) missing" >&2; exit 1; }

# Dead-on-arrival spawn: when a provider adapter cannot confirm the task submitted
# (returns nonzero), cmd_spawn must exit 3, record spawn_submitted=false, and warn
# loudly — never a phantom "spawned". Drive the REAL cmd_spawn with a fake provider
# whose spawn returns 1. (The incident: an orchestrator reported work in flight that
# never ran, because spawn couldn't tell submitted from dead-on-arrival.)
(
  deadlib="$(mktemp -d "$scratch/waspflow-deadlib-XXXXXX")"; mkdir -p "$deadlib/providers"
  cp "$root"/lib/*.sh "$deadlib/"; cp -r "$root/lib/generated" "$deadlib/" 2>/dev/null || true
  cat >"$deadlib/providers/deadp.sh" <<'PROV'
deadp_preflight() { :; }
deadp_discover_session() { echo x; }
deadp_session_resumable() { return 0; }
deadp_is_idle() { return 1; }
deadp_revise() { :; }
deadp_turn_mark() { echo 0; }
deadp_valid_models() { return 1; }
deadp_spawn() { return 1; }   # simulate: window up, task never confirmed submitted
PROV
  sed -i 's/WASPFLOW_PROVIDERS=(claude codex grok)/WASPFLOW_PROVIDERS=(claude codex grok deadp)/' "$deadlib/core.sh"
  dead_home="$(mktemp -d "$scratch/waspflow-deadhome-XXXXXX")"
  dead_work="$(mktemp -d "$scratch/waspflow-deadwork-XXXXXX")"
  ( cd "$dead_work" && git init -q )
  set +e
  out="$(cd "$dead_work" && WASPFLOW_LIB="$deadlib" WASPFLOW_HOME="$dead_home" WASPFLOW_TMUX_SESSION="wf-dead-$$" \
        "$root/bin/waspflow" spawn --provider deadp --lane dead -- "do a thing" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 3 ]] || { echo "dead-on-arrival: cmd_spawn should exit 3, got $rc" >&2; exit 1; }
  grep -q "NOT confirmed submitted" <<<"$out" || { echo "dead-on-arrival: missing loud warning" >&2; exit 1; }
  [[ "$(jq -r '.spawn_submitted // empty' "$dead_home/lanes/dead/state.json" 2>/dev/null)" == "false" ]] \
    || { echo "dead-on-arrival: spawn_submitted should be false" >&2; exit 1; }
  rm -rf "$deadlib" "$dead_home" "$dead_work"
)

# Red-team hardening pins (2026-07-10): clear errors for oversized lane names and
# corrupted state.json, instead of raw OS/jq errors leaking to the operator.
grep -q 'lane name too long' "$root/lib/core.sh" || { echo "core: lane-name length guard missing" >&2; exit 1; }
grep -q 'corrupted state.json' "$root/bin/waspflow" || { echo "status: corrupt-json guard missing" >&2; exit 1; }

# Stall detection (2026-07-10). `wait` must SURFACE a worker that made no progress
# for WASPFLOW_STALL_SECONDS while its turn hasn't ended (rc 4, wait_state=stalled)
# — whatever the cause (interactive prompt, hang, slow tool). The TRIGGER is the
# stall itself, NOT prompt wording: matching prompt text is brittle (breaks when a
# provider rephrases). Prompt matching is only an optional HINT in the message.
(
  export WASPFLOW_HOME="$state_home"
  # END-TO-END, wording-INDEPENDENT: a pane with GENERIC stalled text (no prompt
  # phrases) must still trigger rc 4. This is the whole point of the reframe.
  tmux new-session -d -s "$WASPFLOW_TMUX_SESSION" -n _h 2>/dev/null || true
  tmux new-window -d -t "$WASPFLOW_TMUX_SESSION" -n stalled \
    "bash -c 'printf \"some generic output with no prompt words at all\n\"; exec cat'" 2>/dev/null
  mkdir -p "$state_home/lanes/stalled"
  echo '{"provider":"claude","status":"live","session_id":"no-such","cwd":"/tmp"}' > "$state_home/lanes/stalled/state.json"
  : > "$state_home/lanes/stalled/transcript.log"
  set +e
  t0="$(date +%s)"
  WASPFLOW_HOME="$state_home" WASPFLOW_STALL_SECONDS=3 \
    "$root/bin/waspflow" wait stalled --timeout 30 --interval 1 >/tmp/wf-stall.txt 2>&1
  rc=$?; t1="$(date +%s)"
  set -e
  [[ "$rc" -eq 4 ]] || { echo "stall: generic stalled pane should return rc 4, got $rc" >&2; exit 1; }
  [[ $((t1 - t0)) -lt 20 ]] || { echo "stall: should fire near stall_secs (3s), not wait out timeout ($((t1-t0))s)" >&2; exit 1; }
  [[ "$(jq -r '.wait_state // empty' "$state_home/lanes/stalled/state.json")" == "stalled" ]] \
    || { echo "stall: wait_state should be 'stalled'" >&2; exit 1; }
  grep -q 'STALLED' /tmp/wf-stall.txt || { echo "stall: message should say STALLED" >&2; exit 1; }
  grep -qi 'never auto-answer\|YOUR call' /tmp/wf-stall.txt || { echo "stall: must state it never auto-answers" >&2; exit 1; }
  tmux kill-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null || true
)
# The prompt-shape HINT still works (nice-to-have, not the gate).
(
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  wf_pane_looks_blocked "$(printf 'approaching your usage limit\n❯ 1. Switch to a lesser model\n  2. Keep current')" >/dev/null \
    || { echo "stall hint: should recognize a model-downgrade menu" >&2; exit 1; }
  if wf_pane_looks_blocked "$(printf '● Done. Worked for 6s\n❯ ')" >/dev/null; then
    echo "stall hint: a working pane should not be hinted as a prompt" >&2; exit 1; fi

  # GROUND TRUTH: prompts captured LIVE from codex (2026-07-10), verbatim — not
  # imagined. The hint must match the ACTUAL provider text, or it's useless. These
  # anchor the hint patterns to reality so a refactor can't drift away from it.
  real_trust="$(printf '%s\n' \
    '  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.' \
    '❯ 1. Yes, continue' \
    '  2. No, quit' \
    '  Press enter to continue')"
  wf_pane_looks_blocked "$real_trust" >/dev/null \
    || { echo "stall hint: MISSED the real codex trust prompt (captured 2026-07-10)" >&2; exit 1; }
  real_approval="$(printf '%s\n' \
    '  Would you like to run the following command?' \
    '  $ touch APPROVE_ME.txt && ls -l APPROVE_ME.txt' \
    '❯ 1. Yes, proceed (y)' \
    '  2. Yes, and dont ask again (p)' \
    '  3. No, and tell Codex what to do differently (esc)' \
    '  Press enter to confirm or esc to cancel')"
  wf_pane_looks_blocked "$real_approval" >/dev/null \
    || { echo "stall hint: MISSED the real codex approval prompt (captured 2026-07-10)" >&2; exit 1; }
)
# Pins: the trigger is stall (not wording); config knob present.
grep -q 'STALLED' "$root/bin/waspflow" || { echo "wait: stall surfacing missing" >&2; exit 1; }
grep -q 'WASPFLOW_STALL_SECONDS' "$root/bin/waspflow" || { echo "wait: stall window not configurable" >&2; exit 1; }

# --model validation (2026-07-10): fail a bad model FAST with the valid list (from
# the provider CLI's own live, auth-scoped cache), but FAIL OPEN when no cache — the
# CLI is the real backstop. Addresses the --model footgun (stale/unsupported slugs).
(
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  vmlib="$(mktemp -d "$scratch/waspflow-vm-XXXXXX")"
  # fake provider that enumerates a fixed model set
  cat >"$vmlib/faker.sh" <<'PROV'
faker_valid_models() { printf '%s\n' good-1 good-2 good-3; }
PROV
  # shellcheck disable=SC1090
  source "$vmlib/faker.sh"
  # bad model -> die (nonzero), lists valid set
  out="$( (validate_model faker bad-model spawn) 2>&1 )" && { echo "vm: bad model should fail" >&2; exit 1; }
  grep -q 'not available' <<<"$out" || { echo "vm: missing 'not available' msg" >&2; exit 1; }
  grep -q 'good-1, good-2, good-3' <<<"$out" || { echo "vm: valid list not shown cleanly" >&2; exit 1; }
  # valid model -> ok
  ( validate_model faker good-2 spawn ) || { echo "vm: valid model wrongly rejected" >&2; exit 1; }
  # empty model (default) -> ok
  ( validate_model faker "" spawn ) || { echo "vm: empty model should be allowed" >&2; exit 1; }
  # provider that can't enumerate -> FAIL OPEN (any model allowed)
  faker2_valid_models() { return 1; }
  ( validate_model faker2 anything-goes spawn ) || { echo "vm: must fail open when no cache" >&2; exit 1; }
  rm -rf "$vmlib"
)
# Pins: real caches are read; contract includes valid_models; fail-open comment present.
grep -q 'models_cache.json' "$root/lib/providers/codex.sh" || { echo "codex: model cache source missing" >&2; exit 1; }
grep -q 'valid_models' "$root/lib/core.sh" || { echo "core: valid_models not in provider contract" >&2; exit 1; }

# Thin bundle-before-reap (2026-07-10): archive only the lane's OWN commits
# (fork-point..tip), not full branch history — the dominant cost of batch reap on a
# big fleet. Must stay recoverable, and fall back to full when there's no fork point.
(
  export WASPFLOW_HOME="$state_home"
  export WASPFLOW_ARCHIVE_DIR="$state_home/archive"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/fanin.sh"
  br="$(mktemp -d "$scratch/waspflow-thin-XXXXXX")"
  ( cd "$br" && git init -q && git config user.email t@e.invalid && git config user.name T
    for i in 1 2 3 4 5 6 7 8; do echo "base$i" >> base.txt; git add -A; git commit -q -m "b$i"; done
    git branch -m main 2>/dev/null || true
    git checkout -q -b waspflow/thinlane; echo work > w.txt; git add -A; git commit -q -m work
    git checkout -q main )
  mkdir -p "$state_home/lanes/thinlane"
  jq -n --arg c "$br" '{provider:"codex", repo_root:$c}' > "$state_home/lanes/thinlane/state.json"
  fanin_bundle_lane thinlane >/dev/null 2>&1 || { echo "thin: bundle failed" >&2; exit 1; }
  bun="$(jq -r '.archive_bundle' "$state_home/lanes/thinlane/state.json")"
  [[ -n "$bun" && -f "$bun" ]] || { echo "thin: no bundle recorded" >&2; exit 1; }
  git -C "$br" bundle verify "$bun" >/dev/null 2>&1 || { echo "thin: bundle not recoverable" >&2; exit 1; }
  [[ -n "$(jq -r '.archive_base // empty' "$state_home/lanes/thinlane/state.json")" ]]     || { echo "thin: archive_base not recorded (not a thin bundle)" >&2; exit 1; }
  # a full-history bundle of the same branch must be LARGER (proves we shipped the thin one)
  git -C "$br" bundle create "$br/full.bundle" waspflow/thinlane >/dev/null 2>&1
  [[ "$(stat -c%s "$bun")" -lt "$(stat -c%s "$br/full.bundle")" ]]     || { echo "thin: thin bundle not smaller than full — thinning didn't happen" >&2; exit 1; }
  rm -rf "$br"
)

# lane_set concurrency (2026-07-10): the per-lane flock must prevent lost updates
# when many writes hit the SAME lane at once (was last-writer-wins, ~7/40 survived).
(
  export WASPFLOW_HOME="$state_home"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  mkdir -p "$state_home/lanes/conc"; echo '{}' > "$state_home/lanes/conc/state.json"
  for i in $(seq 1 30); do ( lane_set conc "k$i" "v$i" ) & done
  wait
  jq empty "$state_home/lanes/conc/state.json" 2>/dev/null || { echo "conc: state.json corrupted" >&2; exit 1; }
  n="$(jq '[keys[]|select(startswith("k"))]|length' "$state_home/lanes/conc/state.json")"
  [[ "$n" -eq 30 ]] || { echo "conc: lost updates ($n/30 fields survived)" >&2; exit 1; }
  # lock/temp files must not surface as lanes
  list_lanes | grep -q '\.state' && { echo "conc: lock/temp file leaked into list_lanes" >&2; exit 1; }
  true
)
grep -q 'flock' "$root/lib/core.sh" || { echo "core: lane_set concurrency lock missing" >&2; exit 1; }

# Excellence-audit seam fixes (2026-07-10): clean input validation + honest state
# handling on the read/control verbs — no raw tool errors, no silent laundering.
(
  set +e   # these tests intentionally run commands expected to FAIL and check rc/output
  export WASPFLOW_HOME="$state_home"
  export WASPFLOW_TMUX_SESSION="waspflow-verify-seam-$$"
  BF="$root/bin/waspflow"
  mkdir -p "$state_home/lanes/sgood"
  printf 'l1\n' > "$state_home/lanes/sgood/transcript.log"
  jq -n --arg c "$fixture" --arg t "$state_home/lanes/sgood/transcript.log"     '{provider:"codex",status:"live",cwd:$c,transcript:$t}' > "$state_home/lanes/sgood/state.json"

  # Seam 4B: non-numeric --timeout is a clean error, NOT a bash crash.
  o="$(WASPFLOW_HOME="$state_home" "$BF" wait sgood --timeout nope 2>&1)"; rc=$?
  [[ "$rc" -ne 0 ]] && grep -q 'timeout must be a positive integer' <<<"$o"     || { echo "seam: wait --timeout nope not cleanly rejected" >&2; exit 1; }
  grep -qi 'unbound variable' <<<"$o" && { echo "seam: wait leaked a bash crash" >&2; exit 1; }

  # Seam 4A: non-numeric --lines is a clean error, NOT a raw tail error.
  o="$(WASPFLOW_HOME="$state_home" "$BF" peek sgood --lines nope 2>&1)"
  grep -q 'lines must be a positive integer' <<<"$o" || { echo "seam: peek --lines nope not cleanly rejected" >&2; exit 1; }
  grep -qi 'tail:' <<<"$o" && { echo "seam: peek leaked a tail error" >&2; exit 1; }

  # Seam 4C: unknown flag on list is rejected (not silently ignored).
  WASPFLOW_HOME="$state_home" "$BF" list --wat >/dev/null 2>&1 && { echo "seam: list --wat silently accepted" >&2; exit 1; }

  # Seam 5: peek --help does not leak grep usage.
  o="$(WASPFLOW_HOME="$state_home" "$BF" peek sgood --help 2>&1)"
  grep -qi 'Usage: grep' <<<"$o" && { echo "seam: peek --help leaked grep usage" >&2; exit 1; }

  # Seam 3: list surfaces a corrupt lane as CORRUPT and exits nonzero (no laundering).
  mkdir -p "$state_home/lanes/scorrupt"; printf '{"provider":' > "$state_home/lanes/scorrupt/state.json"
  o="$(WASPFLOW_HOME="$state_home" "$BF" list 2>/dev/null)"; rc=$?
  grep -q 'CORRUPT' <<<"$o" || { echo "seam: corrupt lane not marked CORRUPT in list" >&2; exit 1; }
  [[ "$rc" -eq 2 ]] || { echo "seam: list should exit 2 with a corrupt lane, got $rc" >&2; exit 1; }
  rm -rf "$state_home/lanes/scorrupt"

  # Seam 2: reap does NOT launder an unknown result value into success.
  mkdir -p "$state_home/lanes/smystery"
  jq -n --arg c "$fixture" '{provider:"codex",status:"live",cwd:$c,result:"mystery",no_recovery:"true",git_tracked:"false"}'     > "$state_home/lanes/smystery/state.json"
  WASPFLOW_HOME="$state_home" "$BF" reap smystery --no-archive --force >/dev/null 2>&1
  [[ "$(jq -r .result "$state_home/lanes/smystery/state.json")" == "corrupt_result" ]]     || { echo "seam: reap laundered an unknown result instead of flagging it" >&2; exit 1; }
)

echo "waspflow verify: ok"
