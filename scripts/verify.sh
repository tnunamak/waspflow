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
cleanup() {
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

# wait/revise stale-idle barrier (2026-07-09, confirmed live): after a live-pane
# revise, `wait` must NOT return on the prior turn's idle. pending_turn is the
# barrier. Deterministic test via a fake provider whose idle predicate is always
# "idle" — with pending_turn set, wait must block until the lane is seen busy.
(
  export WASPFLOW_HOME="$state_home"
  fakelib="$(mktemp -d "$scratch/waspflow-fakeprov-XXXXXX")"
  # A fake provider adapter: idle predicate returns idle iff a sentinel file says so.
  cat >"$fakelib/faker.sh" <<'PROV'
faker_spawn() { :; }
faker_revise() { :; }
faker_preflight() { :; }
faker_discover_session() { echo "x"; }
faker_session_resumable() { return 0; }
# Idle unless the "busy" sentinel exists.
faker_is_idle() { [[ ! -f "$FAKER_BUSY" ]]; }
PROV
  # Point core at our fake provider dir by symlinking into the real providers dir
  # is intrusive; instead source core + our adapter and drive cmd_wait's loop
  # logic through the same pending_turn contract at the state layer.
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$fakelib/faker.sh"

  lane_set barlane provider faker status live cwd "$fixture" pending_turn "1"
  export FAKER_BUSY="$fakelib/busy"

  # Simulate the wait barrier by hand (mirrors cmd_wait): with pending_turn=1 and
  # the lane idle, wait must NOT honor idle. Once the lane goes busy, the barrier
  # clears; the next idle is then honored.
  pending="$(lane_get barlane pending_turn)"
  [[ "$pending" == "1" ]] || { echo "barrier: pending_turn should be 1" >&2; exit 1; }
  # Lane is idle now (no busy sentinel) but pending -> must be treated as NOT done.
  if faker_is_idle barlane && [[ "$pending" != "1" ]]; then
    echo "barrier: should not honor idle while pending" >&2; exit 1
  fi
  # Lane goes busy -> barrier clears.
  : > "$FAKER_BUSY"
  if faker_is_idle barlane; then echo "barrier: lane should read busy" >&2; exit 1; fi
  lane_set barlane pending_turn ""      # (cmd_wait clears on first busy observation)
  # Turn completes -> idle, pending cleared -> honored.
  rm -f "$FAKER_BUSY"
  faker_is_idle barlane || { echo "barrier: lane should read idle after busy" >&2; exit 1; }
  [[ "$(lane_get barlane pending_turn)" == "" ]] || { echo "barrier: pending_turn should be cleared" >&2; exit 1; }
  rm -rf "$fakelib"
)
# Static guard: cmd_wait honors the pending_turn barrier, cmd_revise sets it on
# the live path. Pin the wiring so a refactor can't silently drop the fix.
grep -q 'pending_turn' "$root/bin/waspflow" || { echo "wait/revise: pending_turn barrier missing from bin/waspflow" >&2; exit 1; }

echo "waspflow verify: ok"
