#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}"
mkdir -p "$scratch"

bash -n "$root/bin/waspflow" "$root"/lib/*.sh "$root"/lib/providers/*.sh

fixture="$(mktemp -d "$scratch/waspflow-verify-XXXXXX")"
state_home="$(mktemp -d "$scratch/waspflow-state-XXXXXX")"
cleanup() {
  rm -rf "$fixture" "$state_home"
}
trap cleanup EXIT

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
lane_check="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" check --no-fail)"
grep -q "OK: no lanes for this project" <<<"$lane_check"

init_print="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" init --profile live-stack-mutex --print)"
printf '%s\n' "$init_print" | jq -e '.mutexes[0].name == "live-stack"' >/dev/null

demo_preview="$(WASPFLOW_HOME="$state_home" "$root/bin/waspflow" demo --provider codex --lane preview-only)"
grep -q "waspflow demo --provider codex --lane preview-only" <<<"$demo_preview"

echo "waspflow verify: ok"
