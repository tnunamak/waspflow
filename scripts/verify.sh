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
grep -q 'tmux jq git flock' "$root/bin/waspflow"
grep -q '`flock`' "$root/docs/prerequisites.md"
# Lane provenance: --op spawn records policy_version + catalog_ref
grep -Eq 'policy_version' "$root/bin/waspflow"
grep -Eq 'catalog_ref' "$root/bin/waspflow"
! grep -E 'high\|xhigh\|max' "$root/lib/providers/codex.sh"
! grep -E 'high\|xhigh\|max' "$root/lib/exec.sh"

fixture="$(mktemp -d "$scratch/waspflow-verify-XXXXXX")"
state_home="$(mktemp -d "$scratch/waspflow-state-XXXXXX")"

# HERMETIC ISOLATION. The suite must be deterministic regardless of the machine's
# live state. It isolates WASPFLOW_HOME *and* uses a unique tmux socket via a
# tiny PATH wrapper: session names alone still share the operator's tmux server.
# Every direct tmux probe and every bin/waspflow child inherits this wrapper, so
# test cleanup can never kill a production tmux session.
real_tmux="$(command -v tmux)"
tmux_wrapper="$(mktemp -d "$scratch/waspflow-tmux-wrapper-XXXXXX")"
tmux_socket_dir="$(mktemp -d "$HOME/.tmp/wf-tmux-XXXXXX")"
export WASPFLOW_TMUX_SOCKET="wf-$$"
export TMUX_TMPDIR="$tmux_socket_dir"
cat >"$tmux_wrapper/tmux" <<EOF
#!/usr/bin/env bash
unset TMUX TMUX_PANE
exec "$real_tmux" -L "\${WASPFLOW_TMUX_SOCKET:?}" "\$@"
EOF
chmod +x "$tmux_wrapper/tmux"
export PATH="$tmux_wrapper:$PATH"
export WASPFLOW_TMUX_SESSION="waspflow-verify-$$"
cleanup() {
  tmux kill-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null || true
  # This is a test-only, uniquely named isolated socket. If a later assertion
  # aborts before its per-session cleanup, stop that isolated server so no fake
  # worker or inherited lock fd survives the suite.
  tmux kill-server 2>/dev/null || true
  rm -rf "$fixture" "$state_home" "$tmux_wrapper" "$tmux_socket_dir"
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

# Multiline prompts must cross tmux as bracketed, literal paste: otherwise tmux
# translates LF to CR and the TUI can keep the real task in its composer.
(
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  paste_argv="$(mktemp "$scratch/waspflow-paste-argv-XXXXXX")"
  tmux() { printf '%s\n' "$@" >"$paste_argv"; }
  tmux_paste_text 'fake:0' $'first line\nsecond line\nthird line'
  [[ "$(cat "$paste_argv")" == "$(printf 'paste-buffer\n-p\n-r\n-d\n-b\n%s\n-t\nfake:0' "$(sed -n '6p' "$paste_argv")")" ]] \
    || { echo "tmux paste: expected bracketed literal paste-buffer -p -r" >&2; exit 1; }
  rm -f "$paste_argv"
)

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
  marker_before="$(cksum "$(lane_state_file marker-a)")"
  [[ "$(codex_discover_session marker-a)" == "11111111-1111-1111-1111-111111111111" ]]
  [[ "$(codex_discover_session marker-b)" == "22222222-2222-2222-2222-222222222222" ]]
  [[ "$(cksum "$(lane_state_file marker-a)")" == "$marker_before" ]] \
    || { echo "codex discovery: read-only oracle mutated lane state" >&2; exit 1; }
)

# Spawn receipt needs the complete initial prompt, not only the durable marker:
# a marker-only JSONL entry is possible when a multiline paste leaves the task
# in Codex's composer. The same mocked TUI proves the complete prompt succeeds
# on the first Enter, without a retry.
(
  spawn_home="$(mktemp -d "$scratch/waspflow-codex-spawn-home-XXXXXX")"
  spawn_sessions="$(mktemp -d "$scratch/waspflow-codex-spawn-sessions-XXXXXX")"
  spawn_cwd="$fixture"
  export WASPFLOW_HOME="$spawn_home" CODEX_SESSIONS_DIR="$spawn_sessions"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  sleep() { :; }
  spawn_sid="66666666-6666-6666-6666-666666666666"
  spawn_rollout="$spawn_sessions/rollout-2026-07-14T00-00-01-$spawn_sid.jsonl"
  spawn_marker='WASPFLOW_LANE_MARKER:spawn-receipt:marker'
  pasted_prompt=""; enter_count=0; spawn_mode=""
  tmux_paste_text() { pasted_prompt="$2"; }
  tmux() {
    local last="${!#}"
    [[ "$last" == Enter ]] || return 0
    ((++enter_count))
    jq -cn --arg sid "$spawn_sid" --arg cwd "$spawn_cwd" \
      '{type:"session_meta",payload:{id:$sid,cwd:$cwd}}' >"$spawn_rollout"
    case "$spawn_mode" in
      marker) jq -cn --arg message "$spawn_marker" '{type:"event_msg",payload:{type:"user_message",message:$message}}' >>"$spawn_rollout" ;;
      full)   jq -cn --arg message "$pasted_prompt" '{type:"event_msg",payload:{type:"user_message",message:$message}}' >>"$spawn_rollout" ;;
    esac
  }
  lane_set spawn-receipt cwd "$spawn_cwd"
  spawn_mode=marker; enter_count=0
  set +e; _codex_submit_prompt spawn-receipt "$spawn_cwd" fake:0 $'three\nline\ntask' "$spawn_marker"; rc=$?; set -e
  [[ "$rc" -ne 0 && -z "$(lane_get spawn-receipt session_id)" ]] \
    || { echo "codex spawn: marker-only rollout was accepted as task receipt" >&2; exit 1; }
  lane_set spawn-receipt session_id "" rollout ""
  spawn_mode=full; enter_count=0
  _codex_submit_prompt spawn-receipt "$spawn_cwd" fake:0 $'three\nline\ntask' "$spawn_marker"
  [[ "$enter_count" -eq 1 && "$(lane_get spawn-receipt rollout)" == "$spawn_rollout" ]] \
    || { echo "codex spawn: complete multiline prompt did not confirm on first Enter" >&2; exit 1; }
  rm -rf "$spawn_home" "$spawn_sessions"
)

# ---------------------------------------------------------------------------
# Codex session-isolation hardening (2026-07-11). Real incident: concurrent
# same-cwd Codex lanes were mis-attached to one unrelated ~5-week-old rollout,
# mixing prompts/turn histories across lanes; a dead/connection-refused lane
# then read as "idle" and got recovery-"resolved" against someone else's
# session. Root cause: codex_discover_session's cwd-only "legacy" fallback
# (used whenever codex_marker is unset/lost) matched ANY rollout for the cwd —
# ambiguous the moment more than one Codex session has ever run there. Fixed
# by failing CLOSED: no marker -> no session, ever, regardless of cwd history.
# ---------------------------------------------------------------------------

# BUG: no codex_marker recorded (crash/partial-state/pre-marker-era lane) must
# NOT fall back to a cwd-only match — even when a real, completed, unrelated
# rollout exists for that exact cwd. Two different lanes sharing a cwd must
# BOTH come back empty, never both silently converge on the same stale session.
(
  stale_dir="$(mktemp -d "$scratch/waspflow-codex-stale-XXXXXX")"
  stale_home="$(mktemp -d "$scratch/waspflow-codex-stale-home-XXXXXX")"
  stale_sessions="$(mktemp -d "$scratch/waspflow-codex-stale-sessions-XXXXXX")"
  mkdir -p "$stale_sessions/2026/06/08"
  stale_cwd="$stale_dir/repo"; mkdir -p "$stale_cwd"
  cat >"$stale_sessions/2026/06/08/rollout-2026-06-08T10-00-00-old00000-0000-0000-0000-000000000000.jsonl" <<JSONL
{"type":"session_meta","payload":{"id":"old00000-0000-0000-0000-000000000000","cwd":"$stale_cwd"}}
{"type":"event_msg","payload":{"type":"user_message","message":"an unrelated task from five weeks ago"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
  (
    export WASPFLOW_HOME="$stale_home"
    export CODEX_SESSIONS_DIR="$stale_sessions"
    # shellcheck disable=SC1090
    source "$root/lib/core.sh"
    # shellcheck disable=SC1090
    source "$root/lib/providers/codex.sh"
    # Two DIFFERENT lanes, same cwd, NEITHER has a codex_marker recorded.
    lane_set new-x provider codex status live cwd "$stale_cwd"
    lane_set new-y provider codex status live cwd "$stale_cwd"
    sid_x="$(codex_discover_session new-x)"
    sid_y="$(codex_discover_session new-y)"
    [[ -z "$sid_x" ]] || { echo "session-isolation: lane new-x got a stale session_id '$sid_x' via cwd-only fallback" >&2; exit 1; }
    [[ -z "$sid_y" ]] || { echo "session-isolation: lane new-y got a stale session_id '$sid_y' via cwd-only fallback" >&2; exit 1; }
    # And a live-looking idle check must not read that stale rollout as this
    # lane's own idle turn (the "dead lane silently reads as idle" symptom).
    if codex_is_idle new-x; then
      echo "session-isolation: codex_is_idle falsely reported idle via stale cwd match" >&2; exit 1
    fi
  )
  rm -rf "$stale_dir" "$stale_home" "$stale_sessions"
)

# BUG: connection-refused / crashed-before-first-turn Codex lane (marker IS
# recorded — codex_spawn always sets one first — but no rollout ever contains
# it because the process died before flushing) must read as NOT idle, not as
# a false-idle via ambiguous fallback, even with an unrelated completed rollout
# sitting in the very same cwd.
(
  cr_dir="$(mktemp -d "$scratch/waspflow-codex-connrefused-XXXXXX")"
  cr_home="$(mktemp -d "$scratch/waspflow-codex-connrefused-home-XXXXXX")"
  cr_sessions="$(mktemp -d "$scratch/waspflow-codex-connrefused-sessions-XXXXXX")"
  mkdir -p "$cr_sessions/2026/06/08"
  cr_cwd="$cr_dir/repo"; mkdir -p "$cr_cwd"
  cat >"$cr_sessions/2026/06/08/rollout-2026-06-08T10-00-00-old11111-0000-0000-0000-000000000000.jsonl" <<JSONL
{"type":"session_meta","payload":{"id":"old11111-0000-0000-0000-000000000000","cwd":"$cr_cwd"}}
{"type":"event_msg","payload":{"type":"user_message","message":"an unrelated completed task"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
  (
    export WASPFLOW_HOME="$cr_home"
    export CODEX_SESSIONS_DIR="$cr_sessions"
    # shellcheck disable=SC1090
    source "$root/lib/core.sh"
    # shellcheck disable=SC1090
    source "$root/lib/providers/codex.sh"
    lane_set health-contract-redteam provider codex status live cwd "$cr_cwd" \
      codex_marker "WASPFLOW_LANE_MARKER:health-contract-redteam:neverlanded"
    sid="$(codex_discover_session health-contract-redteam)"
    [[ -z "$sid" ]] || { echo "session-isolation: connection-refused lane got session_id '$sid' from an unrelated rollout" >&2; exit 1; }
    if codex_is_idle health-contract-redteam; then
      echo "session-isolation: connection-refused lane falsely read as idle" >&2; exit 1
    fi
    if codex_session_resumable health-contract-redteam; then
      echo "session-isolation: connection-refused lane falsely read as resumable (would let recovery resume a STRANGER's session)" >&2; exit 1
    fi
  )
  rm -rf "$cr_dir" "$cr_home" "$cr_sessions"
)

# Pin: the ambiguous cwd-only fallback must not exist in the shipped adapter.
! grep -q '_codex_find_rollout_for_cwd' "$root/lib/providers/codex.sh" \
  || { echo "codex: ambiguous cwd-only rollout fallback regressed back in" >&2; exit 1; }
grep -q 'FAILS' "$root/lib/providers/codex.sh" || { echo "codex: fail-closed discovery comment missing" >&2; exit 1; }

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

# Live Codex revise needs a receipt stronger than rollout growth: a user_message
# can be queued while the existing task is still active. Exercise the real adapter
# with a deterministic tmux boundary (the suite's real-tmux uses remain on its
# isolated socket above), no provider process or production tmux server involved.
(
  export WASPFLOW_HOME="$state_home"
  revise_sessions="$(mktemp -d "$scratch/waspflow-codex-revise-XXXXXX")"
  export CODEX_SESSIONS_DIR="$revise_sessions"
  export WASPFLOW_CODEX_REVISE_ATTEMPTS=1 WASPFLOW_CODEX_REVISE_POLLS=1
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  billing_preflight_provider() { return 0; }
  tmux_window_exists() { return 0; }
  tmux_window_target() { printf 'fake:0\n'; }
  tmux_paste_text() { :; }
  sleep() { :; }

  revise_sid="44444444-4444-4444-4444-444444444444"
  mkdir -p "$revise_sessions/2026/07/14"
  revise_rollout="$revise_sessions/2026/07/14/rollout-2026-07-14T00-00-01-$revise_sid.jsonl"
  reset_revise_rollout() {
    cat >"$revise_rollout" <<JSONL
{"type":"session_meta","payload":{"id":"$revise_sid","cwd":"$fixture"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
    lane_set codex-live-revise provider codex status live cwd "$fixture" \
      session_id "$revise_sid" rollout "$revise_rollout" revise_barrier_mark 1 \
      revise_submitted true revise_submission_state confirmed-task-started \
      revise_submission_error "" revise_task_started_mark 99
  }
  enter_count=0
  revise_event=""
  tmux() {
    local last="${!#}"
    if [[ "$last" == Enter ]]; then
      ((++enter_count))
      case "$revise_event" in
        queued)
          printf '%s\n' '{"type":"event_msg","payload":{"type":"user_message"}}' >>"$revise_rollout"
          ;;
        started)
          if [[ "$enter_count" -eq 1 ]]; then
            printf '%s\n' '{"type":"event_msg","payload":{"type":"task_started"}}' >>"$revise_rollout"
          fi
          ;;
      esac
    fi
    return 0
  }

  # An early rollout-resolution failure must overwrite a stale prior success
  # before returning, while preserving cmd_wait's completed-turn barrier.
  reset_revise_rollout; rm -f "$revise_rollout"; enter_count=0
  set +e; codex_revise codex-live-revise "retry this"; rc=$?; set -e
  [[ "$rc" -ne 0 && "$enter_count" -eq 0 ]] \
    || { echo "codex revise: missing rollout must fail before steering" >&2; exit 1; }
  jq -e '.revise_submitted == "false" and .revise_submission_state == "unconfirmed-missing-rollout" and .revise_submission_error == "missing-rollout" and .revise_task_started_mark == "" and .revise_barrier_mark == "1"' \
    "$(lane_state_file codex-live-revise)" >/dev/null \
    || { echo "codex revise: missing-rollout receipt/barrier is not truthful" >&2; exit 1; }

  # No rollout event: adapter must fail, mark the receipt unconfirmed, and leave
  # the caller-established completed-turn barrier untouched.
  reset_revise_rollout; enter_count=0; revise_event=""
  set +e; codex_revise codex-live-revise "retry this"; rc=$?; set -e
  [[ "$rc" -ne 0 ]] || { echo "codex revise: no event must return nonzero" >&2; exit 1; }
  jq -e '.revise_submitted == "false" and .revise_submission_state == "unconfirmed-no-task-started" and .revise_submission_error == "no-task-started" and .revise_barrier_mark == "1"' \
    "$(lane_state_file codex-live-revise)" >/dev/null \
    || { echo "codex revise: no-event receipt/barrier is not truthful" >&2; exit 1; }

  # A queued user message grows the file but is NOT task_started, so it must use
  # the same nonzero/unconfirmed path rather than claiming live steering worked.
  reset_revise_rollout; enter_count=0; revise_event=queued
  set +e; codex_revise codex-live-revise "retry this"; rc=$?; set -e
  [[ "$rc" -ne 0 ]] || { echo "codex revise: queued user_message must return nonzero" >&2; exit 1; }
  [[ "$(_codex_task_started_mark "$revise_rollout")" -eq 0 ]] \
    || { echo "codex revise: queued user_message counted as task_started" >&2; exit 1; }
  jq -e '.revise_submitted == "false" and .revise_submission_state == "unconfirmed-no-task-started"' \
    "$(lane_state_file codex-live-revise)" >/dev/null \
    || { echo "codex revise: queued receipt is not truthful" >&2; exit 1; }

  # Only a new task_started event confirms receipt; preserve the same live path.
  reset_revise_rollout; enter_count=0; revise_event=started
  codex_revise codex-live-revise "retry this"
  jq -e '.revise_submitted == "true" and .revise_submission_state == "confirmed-task-started" and .revise_submission_error == "" and .revise_task_started_mark == "1"' \
    "$(lane_state_file codex-live-revise)" >/dev/null \
    || { echo "codex revise: task_started receipt was not recorded" >&2; exit 1; }
  rm -rf "$revise_sessions"
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

# close(abandoned/superseded) + reap must NOT run report recovery or launder
# to "succeeded" (2026-07-11). Real incident: an operator explicitly closed a
# lane as abandoned, then reap still resumed the worker for a recovery pass
# and — with no --report contract at all — reported result=succeeded outright.
# `outcome` (fan-in ledger) must gate `result` (deliverable honesty) for these
# two terminal, human-declared-done outcomes; `harvested`/`open` must be
# unaffected (a harvested lane's work landed — it should still read succeeded).
(
  fi_home="$(mktemp -d "$scratch/waspflow-fi-reap-home-XXXXXX")"
  fi_repo="$(mktemp -d "$scratch/waspflow-fi-reap-repo-XXXXXX")"
  git -C "$fi_repo" init -q
  git -C "$fi_repo" config user.email t@e.invalid; git -C "$fi_repo" config user.name T
  git -C "$fi_repo" commit -q --allow-empty -m init

  # Case 1: abandoned, WITH an unmet --report contract. Must NOT attempt
  # recovery (no resume of the worker) and must NOT report succeeded/recovered.
  mkdir -p "$fi_home/lanes/fi-abandoned-report"
  jq -n --arg cwd "$fi_repo" '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, git_tracked:"true", report:"/nonexistent/report.md"}' \
    > "$fi_home/lanes/fi-abandoned-report/state.json"
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" close fi-abandoned-report --status abandoned --reason "dead end" >/dev/null
  out="$(WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" reap fi-abandoned-report --no-archive 2>&1)"
  grep -qi 'recovery pass' <<<"$out" && { echo "fi-reap: abandoned lane should NOT run a recovery pass" >&2; exit 1; }
  jq -e '.result == "abandoned"' "$fi_home/lanes/fi-abandoned-report/state.json" >/dev/null \
    || { echo "fi-reap: abandoned lane with unmet report should stamp result=abandoned, not succeeded/failed" >&2; exit 1; }

  # Case 2: abandoned, NO report contract at all — the common case. Must NOT
  # be laundered into "succeeded" just because there was nothing to check.
  mkdir -p "$fi_home/lanes/fi-abandoned-plain"
  jq -n --arg cwd "$fi_repo" '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, git_tracked:"true"}' \
    > "$fi_home/lanes/fi-abandoned-plain/state.json"
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" close fi-abandoned-plain --status abandoned --reason "superseded by a better lane" >/dev/null
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" reap fi-abandoned-plain --no-archive >/dev/null
  jq -e '.result == "abandoned"' "$fi_home/lanes/fi-abandoned-plain/state.json" >/dev/null \
    || { echo "fi-reap: abandoned lane with no report contract was laundered into a non-abandoned result" >&2; exit 1; }

  # Case 3: superseded — same gate applies.
  mkdir -p "$fi_home/lanes/fi-superseded"
  jq -n --arg cwd "$fi_repo" '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, git_tracked:"true"}' \
    > "$fi_home/lanes/fi-superseded/state.json"
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" close fi-superseded --status superseded --by "better-lane" >/dev/null
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" reap fi-superseded --no-archive >/dev/null
  jq -e '.result == "abandoned"' "$fi_home/lanes/fi-superseded/state.json" >/dev/null \
    || { echo "fi-reap: superseded lane should also skip recovery/success laundering" >&2; exit 1; }

  # Control: harvested/open lanes must be UNAFFECTED — still finalize normally.
  mkdir -p "$fi_home/lanes/fi-harvested"
  jq -n --arg cwd "$fi_repo" '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, git_tracked:"true"}' \
    > "$fi_home/lanes/fi-harvested/state.json"
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" close fi-harvested --status harvested --into "PR#99" >/dev/null
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" reap fi-harvested --no-archive >/dev/null
  jq -e '.result == "succeeded"' "$fi_home/lanes/fi-harvested/state.json" >/dev/null \
    || { echo "fi-reap: harvested lane should still finalize as succeeded (control case regressed)" >&2; exit 1; }

  mkdir -p "$fi_home/lanes/fi-open"
  jq -n --arg cwd "$fi_repo" '{provider:"codex", status:"live", result:"", cwd:$cwd, origin_cwd:$cwd, git_tracked:"true"}' \
    > "$fi_home/lanes/fi-open/state.json"
  WASPFLOW_HOME="$fi_home" "$root/bin/waspflow" reap fi-open --no-archive >/dev/null
  jq -e '.result == "succeeded"' "$fi_home/lanes/fi-open/state.json" >/dev/null \
    || { echo "fi-reap: open (default) outcome lane should still finalize as succeeded (control case regressed)" >&2; exit 1; }

  rm -rf "$fi_home" "$fi_repo"
)

# wait/revise stale-idle barrier (2026-07-09, root-caused on a live run). After a
# live revise, wait must NOT honor the PRIOR turn's idle. The barrier keys on the
# provider completed-turn mark: wait honors idle only once turn_mark has advanced
# past revise_barrier_mark. This drives the REAL cmd_wait against a
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
faker_mcp_policy() { printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}'; }
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
deadp_mcp_policy() { printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}'; }
deadp_spawn() {
  tmux_create_owned_lane_window "$1" "$2" "exec sleep 60" >/dev/null || return 1
  return 1
}   # window up, task never confirmed submitted
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
  jq -e '(.tmux_window | startswith("@")) and (.tmux_pane_pid | tonumber > 0)' \
    "$dead_home/lanes/dead/state.json" >/dev/null \
    || { echo "dead-on-arrival: retained worker lacks ownership receipt" >&2; exit 1; }
  tmux kill-session -t "wf-dead-$$" 2>/dev/null || true
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
  tmux has-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null \
    || tmux new-session -d -s "$WASPFLOW_TMUX_SESSION" -n _h
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

# MCP lifecycle (2026-07-11): model validation queries Codex live first and
# falls back to its cache only when discovery is unavailable. MCP minimization
# also queries the live configured server set — there is no waspflow-curated list.
(
  mcpbin="$(mktemp -d "$scratch/waspflow-mcp-bin-XXXXXX")"
  mcpwork="$(mktemp -d "$scratch/waspflow-mcp-work-XXXXXX")"
  mcpcache="$mcpwork/models_cache.json"
  cat >"$mcpbin/codex" <<'CODEX'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "debug models")
    [[ "${CODEX_DEBUG_FAIL:-0}" == 1 ]] && exit 1
    printf '%s\n' '{"models":[{"slug":"gpt-5.6-sol"}]}'
    ;;
  "mcp list")
    [[ "${3:-}" == "--json" ]] || exit 9
    [[ -z "${CODEX_EXPECT_CWD:-}" || "$PWD" == "$CODEX_EXPECT_CWD" ]] || exit 8
    [[ "${CODEX_MCP_BAD_SCHEMA:-0}" == 1 ]] && { printf '%s\n' '{"unexpected":[]}'; exit 0; }
    printf '%s\n' '[{"name":"alpha"},{"name":"beta-server"}]'
    ;;
  *) exit 9 ;;
esac
CODEX
  chmod +x "$mcpbin/codex"
  printf '%s\n' '{"models":[{"slug":"stale-cache-model"}]}' >"$mcpcache"
  export PATH="$mcpbin:$PATH" CODEX_MODELS_CACHE="$mcpcache"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  live="$(codex_valid_models)"
  [[ "$live" == "gpt-5.6-sol" ]] || { echo "codex models: did not prefer live discovery" >&2; exit 1; }
  ! grep -q 'stale-cache-model' <<<"$live" || { echo "codex models: stale cache won over live discovery" >&2; exit 1; }
  fallback="$(CODEX_DEBUG_FAIL=1 codex_valid_models)"
  [[ "$fallback" == "stale-cache-model" ]] || { echo "codex models: cache did not fail open after live discovery failure" >&2; exit 1; }
  policy="$(CODEX_EXPECT_CWD="$mcpwork" codex_mcp_policy auto "$mcpwork")"
  jq -e '.resolved == "none" and (.argv | index("mcp_servers.alpha.enabled=false")) and (.argv | index("mcp_servers.beta-server.enabled=false"))' \
    >/dev/null <<<"$policy" || { echo "codex MCP: live server overrides missing" >&2; exit 1; }
  ! grep -q 'stale-cache-model' <<<"$policy" || { echo "codex MCP: stale list leaked into overrides" >&2; exit 1; }
  ! rg -q 'alpha|beta-server|stale-cache-model' "$root/lib/providers/codex.sh" \
    || { echo "codex MCP: provider contains a curated server list" >&2; exit 1; }
  CODEX_MCP_BAD_SCHEMA=1 codex_mcp_policy auto >/dev/null 2>&1 \
    && { echo "codex MCP: unknown discovery schema must fail closed" >&2; exit 1; }
  codex_mcp_validate_extra auto -c 'mcp_servers.added.command="npx"' \
    && { echo "codex MCP: raw config must not bypass isolation" >&2; exit 1; }
  codex_mcp_validate_extra auto '-cmcp_servers.added.command="npx"' \
    && { echo "codex MCP: attached short config must not bypass isolation" >&2; exit 1; }
  codex_mcp_validate_extra auto --profile alternate \
    && { echo "codex MCP: profiles must not bypass discovery" >&2; exit 1; }
  codex_mcp_validate_extra auto -palternate \
    && { echo "codex MCP: attached short profile must not bypass discovery" >&2; exit 1; }
  codex_mcp_validate_extra inherit -c 'mcp_servers.added.command="npx"' \
    || { echo "codex MCP: inherit should preserve raw config" >&2; exit 1; }
  ( mcp_policy_load_json '["ok","line\nbreak"]' '{}' test ) >/dev/null 2>&1 \
    && { echo "MCP state: newline must not change argv boundaries" >&2; exit 1; }

  # Exercise Claude's policy producer through the generic parser. This catches
  # malformed nested JSON before a worker launch reaches tmux.
  # shellcheck disable=SC1090
  source "$root/lib/providers/claude.sh"
  for requested in auto none; do
    policy="$(claude_mcp_policy "$requested")"
    jq -e \
      '.resolved == "none"
       and .argv == ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
       and .env == {"ENABLE_CLAUDEAI_MCP_SERVERS":"false"}' \
      >/dev/null <<<"$policy" \
      || { echo "claude MCP: $requested policy is malformed" >&2; exit 1; }
    mcp_policy_load_json \
      "$(jq -c '.argv' <<<"$policy")" \
      "$(jq -c '.env' <<<"$policy")" \
      "claude $requested policy"
    [[ "${MCP_ARGV[2]}" == '{"mcpServers":{}}' ]] \
      || { echo "claude MCP: $requested config changed across parsing" >&2; exit 1; }
  done
  rm -rf "$mcpbin" "$mcpwork"
)

# Provider argv construction: the resolved policy reaches the actual headless
# commands, including Claude's supported strict empty config + environment gate.
(
  argvbin="$(mktemp -d "$scratch/waspflow-mcp-argv-XXXXXX")"
  argvfile="$argvbin/argv" envfile="$argvbin/env" out="$argvbin/out"
  cat >"$argvbin/codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGV_FILE"
for ((i=1; i<=$#; i++)); do
  [[ "${!i}" == -o ]] && { j=$((i+1)); printf 'answer\n' >"${!j}"; }
done
exit 0
FAKE
  cat >"$argvbin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGV_FILE"
printf '%s\n' "${ENABLE_CLAUDEAI_MCP_SERVERS:-}" >"$ENV_FILE"
printf 'answer\n'
FAKE
  chmod +x "$argvbin/codex" "$argvbin/claude"
  export PATH="$argvbin:$PATH" ARGV_FILE="$argvfile" ENV_FILE="$envfile"
  # shellcheck disable=SC1090
  source "$root/lib/exec.sh"
  MCP_ARGV=(-c 'mcp_servers.alpha.enabled=false') MCP_ENV=()
  _exec_codex "$fixture" "" "" "prompt" "$out"
  grep -qx -- '-c' "$argvfile" && grep -qx 'mcp_servers.alpha.enabled=false' "$argvfile" \
    || { echo "codex argv: MCP override was not appended" >&2; exit 1; }
  MCP_ARGV=(--strict-mcp-config --mcp-config '{"mcpServers":{}}') MCP_ENV=(ENABLE_CLAUDEAI_MCP_SERVERS=false)
  _exec_claude "$fixture" "" "" "prompt" "$out"
  grep -qx -- '--strict-mcp-config' "$argvfile" && grep -qx -- '--mcp-config' "$argvfile" \
    && grep -qx '{"mcpServers":{}}' "$argvfile" && grep -qx false "$envfile" \
    && [[ "$(tail -n 2 "$argvfile")" == $'--\nprompt' ]] \
    || { echo "claude argv: strict MCP policy was not applied" >&2; exit 1; }
  rm -rf "$argvbin"
)

# Grok must not pretend it can provide a strict empty MCP boundary.
(
  # shellcheck disable=SC1090
  source "$root/lib/providers/grok.sh"
  grok_mcp_policy auto | jq -e '.resolved == "inherit" and (.warning | length > 0)' >/dev/null \
    || { echo "grok MCP: auto warning/state missing" >&2; exit 1; }
  grok_mcp_policy none >/dev/null 2>&1 && { echo "grok MCP: none must fail closed" >&2; exit 1; }
  : # keep the expected failing probe from becoming this subshell's status
)

# Exited-lane revise/recovery launches a fresh provider process. The original
# receipt must cross that boundary too, and resolved MCP flags must remain last
# so caller pass-through config cannot undo the isolation policy. A report
# recovery may add only its normalized report parent; an ordinary revise must
# not gain any unrelated external write access.
(
  resumebin="$(mktemp -d "$scratch/waspflow-mcp-resume-bin-XXXXXX")"
  resumehome="$(mktemp -d "$scratch/waspflow-mcp-resume-home-XXXXXX")"
  reportdir="$(mktemp -d "$scratch/waspflow-report-parent-XXXXXX")"
  forbidden_dir="$(mktemp -d "$scratch/waspflow-forbidden-parent-XXXXXX")"
  normalized_reportdir="$(cd -P "$reportdir" && pwd -P)"
  reportdir_with_dotdot="$reportdir/../$(basename "$reportdir")"
  argvfile="$resumebin/argv" envfile="$resumebin/env"
  cat >"$resumebin/codex" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "mcp list --json" ]]; then
  printf '%s\n' '[{"name":"alpha"},{"name":"added-after-spawn"}]'
  exit 0
fi
printf '%s\n' "$@" >"$ARGV_FILE"
for ((i=1; i<=$#; i++)); do
  [[ "${!i}" == -o ]] && { j=$((i+1)); printf 'answer\n' >"${!j}"; }
done
exit 0
FAKE
  cat >"$resumebin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGV_FILE"
printf '%s\n' "${ENABLE_CLAUDEAI_MCP_SERVERS:-}" >"$ENV_FILE"
printf 'answer\n'
FAKE
  chmod +x "$resumebin/codex" "$resumebin/claude"
  export PATH="$resumebin:$PATH" ARGV_FILE="$argvfile" ENV_FILE="$envfile"
  export WASPFLOW_HOME="$resumehome"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  tmux_window_exists() { return 1; }
  billing_preflight_provider() { return 0; }

  # shellcheck disable=SC1090
  source "$root/lib/providers/codex.sh"
  codex_discover_session() { printf 'codex-session\n'; }
  lane_set codex-resume cwd "$fixture" model "" session_id codex-session mcp_requested auto \
    mcp_argv '["-c","mcp_servers.alpha.enabled=false"]' mcp_env '{}'
  codex_revise codex-resume prompt "$resumebin/codex-out"
  grep -qx 'mcp_servers.alpha.enabled=false' "$argvfile" \
    && grep -qx 'mcp_servers.added-after-spawn.enabled=false' "$argvfile" \
    || { echo "codex resume: live MCP receipt was not refreshed/reapplied" >&2; exit 1; }
  ! grep -qx -- '--add-dir' "$argvfile" \
    || { echo "codex revise: ordinary revise gained external write access" >&2; exit 1; }

  # The recovery caller passes a normalized capability. It produces one exact
  # --add-dir pair, not the lexical source path and not any unrelated directory.
  codex_revise codex-resume prompt "$resumebin/codex-recovery-out" "$normalized_reportdir"
  [[ "$(grep -Fxc -- '--add-dir' "$argvfile")" -eq 1 ]] \
    || { echo "codex recovery: expected exactly one external write capability" >&2; exit 1; }
  [[ "$(head -n 4 "$argvfile")" == "$(printf 'exec\n--add-dir\n%s\nresume' "$normalized_reportdir")" ]] \
    || { echo "codex recovery: --add-dir must be scoped to codex exec before resume" >&2; exit 1; }
  grep -A1 -Fx -- '--add-dir' "$argvfile" | tail -n 1 | grep -Fx -- "$normalized_reportdir" >/dev/null \
    || { echo "codex recovery: report parent capability was not passed exactly" >&2; exit 1; }
  ! grep -Fx -- "$reportdir_with_dotdot" "$argvfile" >/dev/null \
    || { echo "codex recovery: lexical report parent escaped command boundary" >&2; exit 1; }
  ! grep -Fx -- "$forbidden_dir" "$argvfile" >/dev/null \
    || { echo "codex recovery: unrelated external directory was granted" >&2; exit 1; }
  codex_revise codex-resume prompt "$resumebin/codex-unnormalized-out" "$reportdir_with_dotdot" >/dev/null 2>&1 \
    && { echo "codex recovery: unnormalized report parent was accepted" >&2; exit 1; }
  workspace_reportdir="$fixture/existing-report-dir"; mkdir -p "$workspace_reportdir"
  codex_revise codex-resume prompt "$resumebin/codex-workspace-recovery-out" "$workspace_reportdir"
  ! grep -qx -- '--add-dir' "$argvfile" \
    || { echo "codex recovery: workspace report parent received a redundant external grant" >&2; exit 1; }

  # Artifact recovery, not ordinary revise, is the only caller that derives
  # this capability. Its report path may have lexical components in old lane
  # state, but the provider receives the normalized parent.
  # shellcheck disable=SC1090
  source "$root/lib/artifacts.sh"
  recovery_capability_file="$resumebin/recovery-capability"
  recovery_probe_revise() { printf '%s\n' "$4" >"$recovery_capability_file"; }
  lane_set recovery-probe cwd "$fixture" transcript "$resumebin/transcript" \
    report "$reportdir_with_dotdot/recovered.md"
  _artifacts_recover recovery-probe recovery_probe "$reportdir_with_dotdot/recovered.md"
  [[ "$(cat "$recovery_capability_file")" == "$normalized_reportdir" ]] \
    || { echo "report recovery: normalized report parent was not threaded to provider" >&2; exit 1; }
  lane_set recovery-workspace cwd "$fixture" transcript "$resumebin/transcript" \
    report "$fixture/not-created-yet/recovered.md"
  _artifacts_recover recovery-workspace recovery_probe "$fixture/not-created-yet/recovered.md"
  [[ "$(cat "$recovery_capability_file")" == "" ]] \
    || { echo "report recovery: missing workspace parent gained an external capability" >&2; exit 1; }

  # shellcheck disable=SC1090
  source "$root/lib/providers/claude.sh"
  claude_mcp_validate_extra auto --mcp-config custom.json \
    && { echo "claude MCP: caller config must not bypass isolation" >&2; exit 1; }
  claude_mcp_validate_extra inherit --mcp-config custom.json \
    || { echo "claude MCP: inherit should preserve caller config" >&2; exit 1; }
  claude_discover_session() { printf 'claude-session\n'; }
  lane_set claude-resume cwd "$fixture" model "" session_id claude-session \
    mcp_argv '["--strict-mcp-config","--mcp-config","{\"mcpServers\":{}}"]' \
    mcp_env '{"ENABLE_CLAUDEAI_MCP_SERVERS":"false"}'
  claude_revise claude-resume prompt "$resumebin/claude-out"
  grep -qx -- '--strict-mcp-config' "$argvfile" && grep -qx false "$envfile" \
    && [[ "$(tail -n 2 "$argvfile")" == $'--\nprompt' ]] \
    || { echo "claude resume: MCP receipt was not reapplied" >&2; exit 1; }
  rm -rf "$resumebin" "$resumehome" "$reportdir" "$forbidden_dir"
)

# Public parsing + lane receipts: default auto reaches the adapter and records
# both the requested policy and the provider-resolved result.
(
  mcplib="$(mktemp -d "$scratch/waspflow-mcp-lib-XXXXXX")"; mkdir -p "$mcplib/providers"
  cp "$root"/lib/*.sh "$mcplib/"; cp -r "$root/lib/generated" "$mcplib/" 2>/dev/null || true
  cat >"$mcplib/providers/mcpp.sh" <<'PROV'
mcpp_preflight() { :; }
mcpp_discover_session() { echo x; }
mcpp_session_resumable() { return 0; }
mcpp_is_idle() { return 1; }
mcpp_revise() { :; }
mcpp_turn_mark() { echo 0; }
mcpp_valid_models() { printf 'allowed-model\n'; }
mcpp_mcp_policy() { case "$1" in auto) printf '%s\n' '{"resolved":"none","warning":"test warning","argv":[],"env":{}}' ;; *) return 1 ;; esac; }
mcpp_spawn() {
  local lane="$1" cwd="$2"
  tmux_create_owned_lane_window "$lane" "$cwd" "exec sleep 60" >/dev/null
}
PROV
  sed -i 's/WASPFLOW_PROVIDERS=(claude codex grok)/WASPFLOW_PROVIDERS=(claude codex grok mcpp)/' "$mcplib/core.sh"
  mcphome="$(mktemp -d "$scratch/waspflow-mcp-home-XXXXXX")"
  mcpdir="$(mktemp -d "$scratch/waspflow-mcp-cwd-XXXXXX")"; (cd "$mcpdir" && git init -q)
  set +e
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane invalid-model --model denied -- "reject early" >/dev/null 2>&1
  invalid_model_rc=$?
  set -e
  [[ "$invalid_model_rc" -ne 0 && ! -d "$mcphome/lanes/invalid-model" ]] \
    || { echo "spawn: invalid model polluted the durable lane index" >&2; exit 1; }
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane mcp-state -- "test policy" >/dev/null 2>&1
  jq -e '.mcp_requested == "auto" and .mcp_resolved == "none" and .mcp_warning == "test warning"' \
    "$mcphome/lanes/mcp-state/state.json" >/dev/null \
    || { echo "MCP state: requested/resolved receipt missing" >&2; exit 1; }
  jq -e '(.tmux_session != "") and (.tmux_window | startswith("@")) and (.tmux_pane_pid | tonumber > 0)' \
    "$mcphome/lanes/mcp-state/state.json" >/dev/null \
    || { echo "spawn: tmux ownership receipt missing" >&2; exit 1; }
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane mcp-state -- "must not overwrite" >/dev/null 2>&1 \
    && { echo "spawn: overwrote an unreaped lane" >&2; exit 1; }

  # A stale reaped receipt must not hide a same-name live window, and exact
  # window ownership must prevent tmux duplicate-name ambiguity.
  tmux new-window -d -t "wf-mcp-$$" -n duplicate-name "exec sleep 60"
  mkdir -p "$mcphome/lanes/duplicate-name"
  printf '%s\n' '{"status":"reaped","tmux_window":"@999999"}' >"$mcphome/lanes/duplicate-name/state.json"
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane duplicate-name -- "must refuse duplicate" >/dev/null 2>&1 \
    && { echo "spawn: stale receipt hid a duplicate tmux name" >&2; exit 1; }
  [[ "$(tmux list-windows -t "wf-mcp-$$" -F '#{window_name}' | grep -cxF duplicate-name)" -eq 1 ]] \
    || { echo "spawn: duplicate-name refusal changed the existing window set" >&2; exit 1; }

  set +e
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane concurrent-claim -- "first" >/dev/null 2>&1 & p1=$!
  WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" WASPFLOW_TMUX_SESSION="wf-mcp-$$" \
    "$root/bin/waspflow" spawn --provider mcpp --lane concurrent-claim -- "second" >/dev/null 2>&1 & p2=$!
  wait "$p1"; r1=$?; wait "$p2"; r2=$?
  set -e
  [[ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ]] \
    || { echo "spawn: concurrent same-lane claim did not admit exactly one winner ($r1,$r2)" >&2; exit 1; }
  [[ "$(tmux list-windows -t "wf-mcp-$$" -F '#{window_name}' | grep -cxF concurrent-claim)" -eq 1 ]] \
    || { echo "spawn: concurrent claim created duplicate windows" >&2; exit 1; }
  set +e
  parse_out="$(WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" "$root/bin/waspflow" exec --provider mcpp --mcp invalid -- "x" 2>&1)"; parse_rc=$?
  set -e
  [[ "$parse_rc" -ne 0 ]] && grep -q -- '--mcp must be auto, none, or inherit' <<<"$parse_out" \
    || { echo "MCP parsing: invalid public policy was not rejected" >&2; exit 1; }
  set +e
  missing_out="$(WASPFLOW_LIB="$mcplib" WASPFLOW_HOME="$mcphome" "$root/bin/waspflow" spawn --provider mcpp --lane missing-mcp --mcp 2>&1)"; missing_rc=$?
  set -e
  [[ "$missing_rc" -ne 0 ]] && grep -q -- 'spawn: --mcp requires' <<<"$missing_out" \
    || { echo "MCP parsing: spawn missing value lacks a diagnostic" >&2; exit 1; }
  tmux kill-session -t "wf-mcp-$$" 2>/dev/null || true
  rm -rf "$mcplib" "$mcphome" "$mcpdir"
)

# Active guidance and live-soak must stay on the current GPT-5.6 operating point;
# deliberately exclude historical incident/confidence records from this check.
! rg -n 'gpt-5\.5|gpt-5\.4-mini' \
  "$root/data/model-choice-policy" "$root/scripts/live-soak.sh" "$root/docs/operating-points.md" "$root/README.md" "$root/skill/SKILL.md" \
  || { echo "active model guidance still references an old Codex model" >&2; exit 1; }

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

# Bounded lifecycle controls: use a fake provider terminal oracle plus a real,
# uniquely named tmux session. This proves wait --reap, owned-window parking,
# fleet GC dry-run/apply, and index filters without touching provider accounts or
# the operator's tmux server.
(
  lifelib="$(mktemp -d "$scratch/waspflow-life-lib-XXXXXX")"; mkdir -p "$lifelib/providers"
  cp "$root"/lib/*.sh "$lifelib/"; cp -r "$root/lib/generated" "$lifelib/" 2>/dev/null || true
  cat >"$lifelib/providers/life.sh" <<'PROV'
life_preflight() { :; }
life_discover_session() { lane_get "$1" session_id; }
life_session_resumable() { [[ "$(lane_get "$1" resumable)" == yes ]]; }
life_is_idle() {
  local idle checks
  idle="$(lane_get "$1" terminal_idle)"
  if [[ "$idle" == flip ]]; then
    checks="$(lane_get "$1" idle_checks)"; checks="${checks:-0}"
    lane_set "$1" idle_checks "$((checks + 1))"
    [[ "$checks" -eq 0 ]]
    return
  fi
  [[ "$idle" == yes ]]
}
life_revise() {
  local lane="$1"
  lane_set "$lane" revise_started yes
  if [[ "$(lane_get "$lane" async_revise)" == yes ]]; then
    local sf tmp command
    sf="$(lane_state_file "$lane")"
    lane_set "$lane" terminal_idle no
    command="sleep 1; tmp=\$(mktemp $(printf '%q' "$(lane_dir "$lane")/.async.XXXXXX")); jq '.terminal_idle=\"yes\" | .turn_mark=\"2\"' $(printf '%q' "$sf") >\"\$tmp\"; mv \"\$tmp\" $(printf '%q' "$sf")"
    tmux new-window -d -t "$WASPFLOW_TMUX_SESSION" -n "_async-$lane" "bash -c $(printf '%q' "$command")"
    return 0
  fi
  sleep 1
  lane_set "$lane" turn_mark 2
}
life_turn_mark() { lane_get "$1" turn_mark; }
life_valid_models() { return 1; }
life_mcp_policy() { printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}'; }
life_spawn() { return 1; }
PROV
  lifehome="$(mktemp -d "$scratch/waspflow-life-home-XXXXXX")"
  lifeother="$(mktemp -d "$scratch/waspflow-life-project-XXXXXX")"
  lifesession="waspflow-life-$$"
  export WASPFLOW_LIB="$lifelib" WASPFLOW_HOME="$lifehome" WASPFLOW_TMUX_SESSION="$lifesession"
  tmux new-session -d -s "$lifesession" -n _home

  make_life_lane() {
    local lane="$1" idle="$2" resumable="$3" cwd="$4" spawned="$5" target session window pid transcript
    transcript="$lifehome/lanes/$lane/transcript.log"
    mkdir -p "$(dirname "$transcript")"; printf 'durable transcript for %s\n' "$lane" >"$transcript"
    tmux new-window -d -t "$lifesession" -n "$lane" -c "$cwd" "exec sleep 120"
    target="$lifesession:$lane"
    IFS='|' read -r session window pid < <(tmux display-message -p -t "$target" '#{session_name}|#{window_id}|#{pane_pid}')
    jq -n --arg cwd "$cwd" --arg t "$transcript" --arg session "$session" --arg window "$window" --arg pid "$pid" \
      --arg idle "$idle" --arg resumable "$resumable" --arg spawned "$spawned" \
      '{provider:"life",status:"live",cwd:$cwd,origin_cwd:$cwd,transcript:$t,session_id:"life-session",terminal_idle:$idle,resumable:$resumable,turn_mark:"1",spawn_epoch:$spawned,tmux_session:$session,tmux_window:$window,tmux_pane_pid:$pid}' \
      >"$lifehome/lanes/$lane/state.json"
  }

  now="$(date +%s)"
  make_life_lane wait-reap yes yes "$fixture" "$now"
  "$root/bin/waspflow" wait wait-reap --timeout 3 --interval 1 --reap >/dev/null
  [[ "$(jq -r .status "$lifehome/lanes/wait-reap/state.json")" == reaped ]] \
    || { echo "wait --reap: did not return final reaped state" >&2; exit 1; }
  tmux list-windows -a -F '#{window_id}' | grep -qxF "$(jq -r .tmux_window "$lifehome/lanes/wait-reap/state.json")" \
    && { echo "wait --reap: owned window survived cleanup" >&2; exit 1; }

  make_life_lane wait-reap-fail yes yes "$fixture" "$now"
  jq '. + {verify_command:"false",verify_name:"verify",verify_timeout:"5"}' \
    "$lifehome/lanes/wait-reap-fail/state.json" >"$lifehome/lanes/wait-reap-fail/state.next"
  mv "$lifehome/lanes/wait-reap-fail/state.next" "$lifehome/lanes/wait-reap-fail/state.json"
  set +e; "$root/bin/waspflow" wait wait-reap-fail --timeout 3 --interval 1 --reap >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 2 && "$(jq -r .result "$lifehome/lanes/wait-reap-fail/state.json")" == verify_failed ]] \
    || { echo "wait --reap: did not return final reap failure rc/result" >&2; exit 1; }

  make_life_lane wait-reap-race yes yes "$fixture" "$now"
  jq '. + {async_revise:"yes"}' "$lifehome/lanes/wait-reap-race/state.json" \
    >"$lifehome/lanes/wait-reap-race/state.next"
  mv "$lifehome/lanes/wait-reap-race/state.next" "$lifehome/lanes/wait-reap-race/state.json"
  mkdir -p "$lifehome/locks"
  exec 8>"$lifehome/locks/wait-reap-race.lock"; flock -x 8
  "$root/bin/waspflow" revise wait-reap-race -- "async turn" >/dev/null 2>&1 & race_revise_pid=$!
  sleep 0.1
  race_start_ns="$(date +%s%N)"
  "$root/bin/waspflow" wait wait-reap-race --timeout 5 --interval 1 --reap >/dev/null 2>&1 & race_wait_pid=$!
  sleep 0.2
  flock -u 8; exec 8>&-
  wait "$race_revise_pid"; wait "$race_wait_pid"
  race_elapsed_ms=$(( ( $(date +%s%N) - race_start_ns ) / 1000000 ))
  [[ "$(jq -r .status "$lifehome/lanes/wait-reap-race/state.json")" == reaped && "$race_elapsed_ms" -ge 700 ]] \
    || { echo "wait --reap: stale idle raced a concurrent revise (${race_elapsed_ms}ms)" >&2; exit 1; }

  make_life_lane wait-active no yes "$fixture" "$now"
  set +e; "$root/bin/waspflow" wait wait-active --timeout 1 --interval 1 --reap >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 1 ]] || { echo "wait --reap: timeout rc changed (got $rc)" >&2; exit 1; }
  [[ "$(jq -r .status "$lifehome/lanes/wait-active/state.json")" == live ]] \
    || { echo "wait --reap: active lane was cleaned up" >&2; exit 1; }
  tmux display-message -p -t "$(jq -r .tmux_window "$lifehome/lanes/wait-active/state.json")" >/dev/null \
    || { echo "wait --reap: active window was killed" >&2; exit 1; }

  make_life_lane park-good yes yes "$fixture" "$((now - 1000))"
  printf 'artifact must survive\n' >"$lifehome/lanes/park-good/kept-artifact.txt"
  "$root/bin/waspflow" park park-good --reason "operator paused" >/dev/null
  jq -e '.status == "parked" and (.parked_at | tonumber > 0) and .park_reason == "operator paused"' \
    "$lifehome/lanes/park-good/state.json" >/dev/null \
    || { echo "park: did not record lifecycle receipt" >&2; exit 1; }
  test -f "$lifehome/lanes/park-good/transcript.log" && test -f "$lifehome/lanes/park-good/kept-artifact.txt" \
    || { echo "park: removed durable lane artifacts" >&2; exit 1; }
  tmux list-windows -a -F '#{window_id}' | grep -qxF "$(jq -r .tmux_window "$lifehome/lanes/park-good/state.json")" \
    && { echo "park: owned window was not stopped" >&2; exit 1; }
  "$root/bin/waspflow" revise park-good -- "resume remains available" >/dev/null \
    || { echo "park: parked lane was no longer resumable" >&2; exit 1; }

  make_life_lane park-active no yes "$fixture" "$((now - 1000))"
  "$root/bin/waspflow" park park-active >/dev/null 2>&1 \
    && { echo "park: accepted an active provider lane" >&2; exit 1; }
  tmux display-message -p -t "$(jq -r .tmux_window "$lifehome/lanes/park-active/state.json")" >/dev/null \
    || { echo "park: killed active provider lane" >&2; exit 1; }

  make_life_lane park-race yes yes "$fixture" "$((now - 1000))"
  "$root/bin/waspflow" revise park-race -- "start another turn" >/dev/null 2>&1 & revise_pid=$!
  for _ in $(seq 1 50); do
    [[ "$(jq -r '.revise_started // ""' "$lifehome/lanes/park-race/state.json")" == yes ]] && break
    sleep 0.02
  done
  start_ns="$(date +%s%N)"
  "$root/bin/waspflow" park park-race >/dev/null
  elapsed_ms=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  wait "$revise_pid"
  [[ "$elapsed_ms" -ge 500 ]] \
    || { echo "park/revise: lifecycle operation lock did not close the idle-proof race (${elapsed_ms}ms)" >&2; exit 1; }

  make_life_lane park-legacy yes yes "$fixture" "$((now - 1000))"
  jq 'del(.tmux_session,.tmux_window,.tmux_pane_pid)' \
    "$lifehome/lanes/park-legacy/state.json" >"$lifehome/lanes/park-legacy/state.next"
  mv "$lifehome/lanes/park-legacy/state.next" "$lifehome/lanes/park-legacy/state.json"
  "$root/bin/waspflow" park park-legacy >/dev/null 2>&1 \
    && { echo "park: silently adopted a legacy lane" >&2; exit 1; }
  "$root/bin/waspflow" park park-legacy --adopt-legacy >/dev/null \
    || { echo "park: explicit safe legacy adoption failed" >&2; exit 1; }
  [[ "$(jq -r .status "$lifehome/lanes/park-legacy/state.json")" == parked ]] \
    || { echo "park: legacy lane was not parked after adoption" >&2; exit 1; }

  make_life_lane gc-good yes yes "$fixture" "$((now - 1000))"
  make_life_lane gc-other yes yes "$lifeother" "$((now - 1000))"
  make_life_lane gc-legacy yes yes "$fixture" "$((now - 1000))"
  jq 'del(.tmux_session,.tmux_window,.tmux_pane_pid)' \
    "$lifehome/lanes/gc-legacy/state.json" >"$lifehome/lanes/gc-legacy/state.next"
  mv "$lifehome/lanes/gc-legacy/state.next" "$lifehome/lanes/gc-legacy/state.json"
  gc_adopt_dry="$("$root/bin/waspflow" gc --lane-age 10 --project "$fixture" --adopt-legacy)"
  grep -q 'gc-legacy' <<<"$gc_adopt_dry" \
    || { echo "gc: explicit legacy dry run missed eligible lane" >&2; exit 1; }
  [[ "$(jq -r '.tmux_window // ""' "$lifehome/lanes/gc-legacy/state.json")" == "" ]] \
    || { echo "gc dry run: legacy adoption mutated state" >&2; exit 1; }
  gc_dry="$("$root/bin/waspflow" gc --lane-age 10 --project "$fixture")"
  grep -q 'gc-good' <<<"$gc_dry" || { echo "gc: missed scoped eligible lane" >&2; exit 1; }
  ! grep -q 'gc-other' <<<"$gc_dry" || { echo "gc: ignored project scope" >&2; exit 1; }
  ! grep -q 'gc-legacy' <<<"$gc_dry" || { echo "gc: silently adopted legacy lane" >&2; exit 1; }
  [[ "$(jq -r .status "$lifehome/lanes/gc-good/state.json")" == live ]] \
    || { echo "gc dry run: mutated lifecycle state" >&2; exit 1; }
  "$root/bin/waspflow" gc --lane-age 10 --project "$fixture" --apply >/dev/null
  [[ "$(jq -r .status "$lifehome/lanes/gc-good/state.json")" == parked ]] \
    || { echo "gc apply: did not park selected lane" >&2; exit 1; }
  [[ "$(jq -r .status "$lifehome/lanes/gc-other/state.json")" == live ]] \
    || { echo "gc apply: touched out-of-scope lane" >&2; exit 1; }
  "$root/bin/waspflow" gc --lane-age 10 --project "$fixture" --adopt-legacy --apply >/dev/null
  [[ "$(jq -r .status "$lifehome/lanes/gc-legacy/state.json")" == parked ]] \
    || { echo "gc apply: explicit legacy adoption did not park lane" >&2; exit 1; }

  make_life_lane gc-race flip yes "$fixture" "$((now - 1000))"
  set +e
  "$root/bin/waspflow" gc --lane-age 10 --project "$fixture" --apply >/dev/null 2>&1; rc=$?
  set -e
  [[ "$rc" -eq 2 && "$(jq -r .status "$lifehome/lanes/gc-race/state.json")" == live ]] \
    || { echo "gc apply: partial failure was masked (rc=$rc)" >&2; exit 1; }

  jq '. + {prompt:"DO_NOT_LEAK_BULK_PROMPT",mcp_argv:"DO_NOT_LEAK_ARGV"}' \
    "$lifehome/lanes/gc-good/state.json" >"$lifehome/lanes/gc-good/state.next"
  mv "$lifehome/lanes/gc-good/state.next" "$lifehome/lanes/gc-good/state.json"
  listed="$("$root/bin/waspflow" list --json --project "$fixture" --lifecycle-state parked --limit 1)"
  jq -e 'length == 1 and .[0].lifecycle_state == "parked" and .[0].tmux_session != ""' <<<"$listed" >/dev/null \
    || { echo "list json: lifecycle/project/limit filter failed" >&2; exit 1; }
  ! grep -q 'DO_NOT_LEAK' <<<"$listed" \
    || { echo "list json: bulk index leaked prompt/provider argv" >&2; exit 1; }
  "$root/bin/waspflow" list --lifecycle-state impossible >/dev/null 2>&1 \
    && { echo "list json: invalid lifecycle state was accepted" >&2; exit 1; }
  "$root/bin/waspflow" gc --lane-age not-a-number >/dev/null 2>&1 \
    && { echo "gc: invalid lane age was accepted" >&2; exit 1; }
  mkdir -p "$lifehome/lanes/life-corrupt"; printf '{"provider":' >"$lifehome/lanes/life-corrupt/state.json"
  set +e; corrupt_list="$("$root/bin/waspflow" list --json --project "$fixture" 2>/dev/null)"; rc=$?; set -e
  [[ "$rc" -eq 2 ]] && jq -e 'any(.[]; .corrupt == true and .lane == "life-corrupt")' <<<"$corrupt_list" >/dev/null \
    || { echo "list json: corrupt record was hidden" >&2; exit 1; }

  tmux kill-session -t "$lifesession" 2>/dev/null || true
  rm -rf "$lifelib" "$lifehome" "$lifeother"
)

# Descendant ownership is deliberately exercised with the same adapter seam the
# real providers use. The test socket is private (configured at the top of this
# verifier), and every user scope has a unique waspflow-test unit name; neither
# production tmux nor an unrelated scope is ever selected for cleanup.
if command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1; then
(
  scopelib="$(mktemp -d "$scratch/waspflow-scope-lib-XXXXXX")"; mkdir -p "$scopelib/providers"
  cp "$root"/lib/*.sh "$scopelib/"; cp -r "$root/lib/generated" "$scopelib/" 2>/dev/null || true
  cat >"$scopelib/providers/scopep.sh" <<'PROV'
scopep_preflight() { :; }
scopep_discover_session() { echo scopep-session; }
scopep_session_resumable() { return 0; }
scopep_is_idle() { return 0; }
scopep_turn_mark() { echo 0; }
scopep_valid_models() { return 1; }
scopep_mcp_policy() { printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}'; }
scopep_spawn() {
  local lane="$1" cwd="$2" _model="$3" _sid="$4" _transcript="$5" prompt="$6"
  tmux_create_owned_lane_window "$lane" "$cwd" "exec bash -c $(printf '%q' "$prompt")" >/dev/null
}
# The provider's real headless seam uses the shared argv launcher. A normal
# revise daemonizes exactly like a detached CLI child. Recovery additionally
# writes its requested output/report so the real artifact flow can continue.
scopep_revise() {
  local lane="$1" message="$2" out_file="${3:-}" _recovery_parent="${4:-}" cwd report pid_file
  cwd="$(lane_get "$lane" cwd)"
  if [[ -z "$out_file" ]]; then
    tmux_run_owned_lane_command "$lane" "$cwd" headless-revise -- bash -c "$message"
    return
  fi
  report="$(lane_get "$lane" report)"
  pid_file="$(lane_dir "$lane")/recovery-daemon.pid"
  tmux_run_owned_lane_command "$lane" "$cwd" headless-recovery -- \
    bash -c 'setsid bash -c "sleep 300 & echo \$! > \"$1\"; disown" -- "$2" & disown; printf "%256s\\n" "" | tr " " x > "$3"; cp "$3" "$4"' \
    -- "$pid_file" "$pid_file" "$out_file" "$report"
}
PROV
  sed -i 's/WASPFLOW_PROVIDERS=(claude codex grok)/WASPFLOW_PROVIDERS=(claude codex grok scopep)/' "$scopelib/core.sh"
  scopehome="$(mktemp -d "$scratch/waspflow-scope-home-XXXXXX")"
  scopework="$(mktemp -d "$scratch/waspflow-scope-work-XXXXXX")"; ( cd "$scopework" && git init -q )
  scopesession="waspflow-scope-$$"
  export WASPFLOW_LIB="$scopelib" WASPFLOW_HOME="$scopehome" WASPFLOW_TMUX_SESSION="$scopesession"
  # The receipt-failure probe below calls the shared launcher directly, just as
  # a provider adapter does. Load the isolated copy, never the production one.
  source "$scopelib/core.sh"

  scope_receipts() { jq -r '.cgroup_scope_receipts // [] | .[] | .unit + "\u001e" + .invocation_id' "$scopehome/lanes/$1/state.json"; }
  scope_pids() {
    local lane="$1" unit invocation actual cg
    while IFS=$'\x1e' read -r unit invocation; do
      actual="$(systemctl --user show "$unit" -p InvocationID --value 2>/dev/null || true)"
      [[ "$actual" == "$invocation" ]] || continue
      cg="$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null)"
      [[ -n "$cg" ]] && cat "/sys/fs/cgroup${cg}/cgroup.procs" 2>/dev/null || true
    done < <(scope_receipts "$lane")
  }
  wait_for_receipts() {
    local lane="$1" expected="$2"
    for _ in $(seq 1 60); do
      [[ "$(jq '.cgroup_scope_receipts // [] | length' "$scopehome/lanes/$lane/state.json")" -ge "$expected" ]] && return 0
      sleep 0.1
    done
    return 1
  }
  spawn_scope_lane() { ( cd "$scopework" && "$root/bin/waspflow" spawn --provider scopep --lane "$1" "${@:3}" -- "$2" >/dev/null ); }

  # Normal completion gets a real scope receipt before its short command exits.
  spawn_scope_lane normal-done 'true'
  wait_for_receipts normal-done 1 || { echo "scope: normal pane receipt missing" >&2; exit 1; }
  "$root/bin/waspflow" reap normal-done --no-archive >/dev/null
  [[ "$(jq -r .status "$scopehome/lanes/normal-done/state.json")" == reaped ]] \
    || { echo "scope: normal completion did not reap" >&2; exit 1; }

  # Initial pane + daemonized headless resume create two receipts. Reap must
  # kill both scopes even after the tmux pane vanished.
  spawn_scope_lane multi-scope 'sleep 300'
  wait_for_receipts multi-scope 1 || { echo "scope: initial receipt missing" >&2; exit 1; }
  tmux kill-window -t "$scopesession:multi-scope" 2>/dev/null || true
  "$root/bin/waspflow" revise multi-scope -- 'setsid bash -c "sleep 300 & disown" & disown' >/dev/null
  wait_for_receipts multi-scope 2 || { echo "scope: headless resume did not append a receipt" >&2; exit 1; }
  headless_pids="$(scope_pids multi-scope)"
  [[ -n "$headless_pids" ]] || { echo "scope: daemonized headless resume produced no cgroup member" >&2; exit 1; }

  # A forged receipt for a live bystander must not authorize killing it. This
  # also proves InvocationID comparison protects unit-name reuse.
  bystander="waspflow-bystander-$$.scope"
  systemd-run --user --scope --unit="$bystander" --collect --quiet -- bash -c 'sleep 300' & bystander_runner=$!
  for _ in $(seq 1 60); do
    bystander_invocation="$(systemctl --user show "$bystander" -p InvocationID --value 2>/dev/null || true)"
    [[ -n "$bystander_invocation" ]] && break
    sleep 0.1
  done
  [[ -n "${bystander_invocation:-}" ]] || { echo "scope: bystander scope did not start" >&2; exit 1; }
  jq --arg unit "$bystander" '.cgroup_scope_receipts += [{unit:$unit,invocation_id:"forged-reuse"}]' \
    "$scopehome/lanes/multi-scope/state.json" >"$scopehome/lanes/multi-scope/state.next"
  mv "$scopehome/lanes/multi-scope/state.next" "$scopehome/lanes/multi-scope/state.json"
  "$root/bin/waspflow" reap multi-scope --no-archive >/dev/null
  for _ in $(seq 1 60); do [[ -z "$(scope_pids multi-scope)" ]] && break; sleep 0.1; done
  [[ -z "$(scope_pids multi-scope)" ]] || { echo "scope: reap left an owned cgroup member" >&2; exit 1; }
  systemctl --user show "$bystander" -p InvocationID --value 2>/dev/null | grep -qx "$bystander_invocation" \
    || { echo "scope: reap touched the bystander/reused unit" >&2; exit 1; }
  "$root/bin/waspflow" reap multi-scope --no-archive >/dev/null
  [[ "$(jq -r .status "$scopehome/lanes/multi-scope/state.json")" == reaped ]] \
    || { echo "scope: repeat reap was not idempotent" >&2; exit 1; }
  systemctl --user kill --kill-whom=all --signal=SIGKILL "$bystander" >/dev/null 2>&1 || true
  systemctl --user stop "$bystander" >/dev/null 2>&1 || true
  wait "$bystander_runner" 2>/dev/null || true

  # The real artifact path kills the pane, invokes provider_revise headlessly,
  # then reaps its freshly-created recovery scope and daemon.
  spawn_scope_lane recovery 'sleep 300' --report recovery.md
  wait_for_receipts recovery 1 || { echo "scope: recovery initial receipt missing" >&2; exit 1; }
  "$root/bin/waspflow" reap recovery --no-archive >/dev/null
  recovery_pid="$(cat "$scopehome/lanes/recovery/recovery-daemon.pid")"
  ! kill -0 "$recovery_pid" 2>/dev/null || { echo "scope: recovery daemon survived reap" >&2; exit 1; }
  [[ "$(jq '.cgroup_scope_receipts | length' "$scopehome/lanes/recovery/state.json")" -ge 2 ]] \
    || { echo "scope: recovery did not append a second receipt" >&2; exit 1; }
  [[ -s "$scopework/recovery.md" ]] \
    || { echo "scope: recovery adapter did not write its requested report" >&2; exit 1; }
  [[ "$(jq -r .result "$scopehome/lanes/recovery/state.json")" == recovered ]] \
    || { echo "scope: artifact recovery did not preserve its success contract" >&2; exit 1; }

  # Receipt persistence fails AFTER the scope-entry marker in this reviewer-
  # shaped probe. The launcher must return a terminal failure promptly, leave
  # the provider unstarted, release the operation lock, and let the transient
  # scope go inactive. A marker without a status used to wedge this forever.
  receiptfailbin="$(mktemp -d "$scratch/waspflow-scope-receiptfail-XXXXXX")"
  cat >"$receiptfailbin/jq" <<'FAILJQ'
#!/usr/bin/env bash
marker="$(compgen -G "$WASPFLOW_HOME/lanes/receipt-failure/.scope-started-waspflow-receipt-failure-*.scope" | head -n 1 || true)"
[[ -n "$marker" ]] && printf marker-observed >"$WASPFLOW_HOME/receipt-failure-marker-observed"
exit 1
FAILJQ
  chmod +x "$receiptfailbin/jq"
  receipt_provider_marker="$scopework/receipt-provider-ran"
  RECEIPT_FAIL_UUID="receipt-failure-$$"
  receipt_fail_unit="waspflow-receipt-failure-${RECEIPT_FAIL_UUID}.scope"
  receipt_failure_launch() {
    new_uuid() { printf '%s\n' "$RECEIPT_FAIL_UUID"; }
    tmux_run_owned_lane_command receipt-failure "$scopework" headless-revise -- \
      bash -c 'printf provider-ran > "$1"' -- "$receipt_provider_marker"
  }
  lane_set receipt-failure status live cwd "$scopework"
  old_path="$PATH"; export PATH="$receiptfailbin:$PATH"
  ( set +e; lane_operation_run receipt-failure receipt_failure_launch; echo "$?" >"$scopework/receipt-failure.rc" ) & receipt_failure_pid=$!
  for _ in $(seq 1 70); do
    kill -0 "$receipt_failure_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$receipt_failure_pid" 2>/dev/null; then
    kill "$receipt_failure_pid" 2>/dev/null || true
    wait "$receipt_failure_pid" 2>/dev/null || true
    echo "scope: receipt persistence failure did not return within 7s" >&2
    exit 1
  fi
  wait "$receipt_failure_pid" 2>/dev/null || true
  export PATH="$old_path"
  [[ "$(cat "$scopework/receipt-failure.rc")" == 125 ]] \
    || { echo "scope: receipt persistence failure did not return terminal rc=125" >&2; exit 1; }
  [[ -f "$scopehome/receipt-failure-marker-observed" ]] \
    || { echo "scope: receipt persistence probe did not run after scope marker" >&2; exit 1; }
  [[ ! -e "$receipt_provider_marker" ]] \
    || { echo "scope: receipt persistence failure ran the provider unsupervised" >&2; exit 1; }
  for _ in $(seq 1 30); do
    receipt_active="$(systemctl --user show "$receipt_fail_unit" -p ActiveState --value 2>/dev/null || true)"
    [[ "$receipt_active" != active ]] && break
    sleep 0.1
  done
  [[ "${receipt_active:-}" != active ]] \
    || { echo "scope: receipt persistence failure left its test scope active" >&2; exit 1; }
  jq -e '(.cgroup_scope_receipts // []) == []' "$scopehome/lanes/receipt-failure/state.json" >/dev/null \
    || { echo "scope: failed receipt was recorded as owned" >&2; exit 1; }
  lane_operation_run receipt-failure true \
    || { echo "scope: receipt persistence failure kept the lane operation lock" >&2; exit 1; }
  rm -rf "$receiptfailbin"

  # A preflight-positive but launch-failing systemd-run must execute the original
  # pane command, retain tmux ownership, and record a degraded—not phantom—lane.
  failbin="$(mktemp -d "$scratch/waspflow-scope-failbin-XXXXXX")"
  cat >"$failbin/systemd-run" <<'FAIL'
#!/usr/bin/env bash
exit 73
FAIL
  chmod +x "$failbin/systemd-run"
  old_path="$PATH"; export PATH="$failbin:$PATH"
  spawn_scope_lane scope-fallback 'printf fallback > fallback-ran'
  for _ in $(seq 1 40); do [[ -f "$scopework/fallback-ran" ]] && break; sleep 0.1; done
  [[ -f "$scopework/fallback-ran" ]] || { echo "scope: launch failure skipped original pane command" >&2; exit 1; }
  jq -e '(.cgroup_scope_receipts // []) == [] and .cgroup_fallbacks[-1].reason == "scope-launch-failed" and .tmux_window != ""' \
    "$scopehome/lanes/scope-fallback/state.json" >/dev/null \
    || { echo "scope: failed launch left dishonest ownership state" >&2; exit 1; }
  export PATH="$old_path"
  tmux kill-session -t "$scopesession" 2>/dev/null || true
  rm -rf "$scopelib" "$scopehome" "$scopework" "$failbin"
)
fi

# The unavailable-host path is a first-class, truthful fallback and does not
# require systemd to be installed on the verifier host.
(
  nosystemd_home="$(mktemp -d "$scratch/waspflow-nosystemd-home-XXXXXX")"
  nosystemd_cwd="$(mktemp -d "$scratch/waspflow-nosystemd-cwd-XXXXXX")"
  export WASPFLOW_HOME="$nosystemd_home"
  # shellcheck disable=SC1090
  source "$root/lib/core.sh"
  tmux_cgroup_scope_available() { return 1; }
  lane_set no-systemd status live cwd "$nosystemd_cwd"
  tmux_run_owned_lane_command no-systemd "$nosystemd_cwd" headless-revise -- bash -c 'printf fallback > ran'
  [[ -f "$nosystemd_cwd/ran" ]] \
    && jq -e '(.cgroup_scope_receipts // []) == [] and .cgroup_fallbacks[-1].reason == "scope-unavailable"' \
      "$nosystemd_home/lanes/no-systemd/state.json" >/dev/null \
    || { echo "scope: no-systemd fallback was not truthful/executable" >&2; exit 1; }
  rm -rf "$nosystemd_home" "$nosystemd_cwd"
)

echo "waspflow verify: ok"
