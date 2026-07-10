# Excellence audit — waspflow command surface

Scope audited: `bin/waspflow`, `lib/*.sh`, and `lib/providers/*.sh`.
All documented reproducers below use a disposable `WASPFLOW_HOME` and a unique
`WASPFLOW_TMUX_SESSION`; no finding relies on a real-worker result. Confidence:
high for every SEAM — each was reproduced against this worktree on 2026-07-10.

## 1. SEAM-MAJOR — concurrent state updates silently lose fields

`lane_set` is an atomic-file replacement, but not an atomic read-modify-write.
Two normal Waspflow processes acting on the same lane can both read the old JSON,
then the later `mv` discards the earlier process's update. The state remains valid
JSON, so the loss is silent. That is a serious mismatch for a tool whose central
promise is durable, trustworthy lane state.

Reproducer:

```bash
bash -c 'set -euo pipefail
home="$(mktemp -d)/wfhome"; export WASPFLOW_HOME="$home"
source lib/core.sh
lane_set race counter 0
for i in $(seq 1 24); do (lane_set race "field_$i" "value_$i") & done
wait
jq "[keys[] | select(startswith(\"field_\"))] | length" \
  "$home/lanes/race/state.json"'
```

Observed output:

```text
3
```

All 24 callers completed successfully; only three `field_*` values remained.
This can erase a result, session handle, barrier mark, or outcome provenance when
commands overlap. `lib/core.sh:119-143` needs per-lane serialization or a
compare-and-retry merge, plus a concurrency regression test.

## 2. SEAM-MAJOR — `reap` converts an unknown result into a false success

An invalid or newer `result` value is not treated as corruption/unknown. During
finalization, it falls through and is replaced with `succeeded`; `reap` then exits
0 and announces success. This hides evidence rather than preserving or surfacing
it.

Reproducer:

```bash
home="$(mktemp -d)/wfhome"
mkdir -p "$home/lanes/invalid-result"
jq -n --arg cwd "$PWD" \
  '{provider:"codex",status:"live",cwd:$cwd,origin_cwd:$cwd,
    result:"mystery",git_tracked:"false",no_recovery:"true}' \
  > "$home/lanes/invalid-result/state.json"
WASPFLOW_HOME="$home" WASPFLOW_TMUX_SESSION="audit-$$" \
  bin/waspflow reap invalid-result --no-archive
jq -r '.result' "$home/lanes/invalid-result/state.json"
```

Observed output:

```text
waspflow: reap: lane 'invalid-result' reaped — result=succeeded
succeeded
```

The honest result is unknown, not success. `lib/artifacts.sh:70-75` should reject
or retain unknown terminal values and make `reap` nonzero with an explicit
corrupted/unsupported-state diagnosis.

## 3. SEAM-MAJOR — `list` silently launders corrupted lane state into a blank lane

`status` has a good corruption guard, but `list` reads every field through
`lane_get`, which turns a failing `jq` read into an empty string. A corrupt state
therefore looks like an ordinary exited/open lane and exits 0 — exactly the wrong
answer for an orchestration overview.

Reproducer:

```bash
home="$(mktemp -d)/wfhome"
mkdir -p "$home/lanes/corrupt"
printf '{"provider":"codex",' > "$home/lanes/corrupt/state.json"
WASPFLOW_HOME="$home" WASPFLOW_TMUX_SESSION="audit-$$" bin/waspflow list
```

Observed output:

```text
LANE                 PROVIDER STATE    OUTCOME     CWD
corrupt                       exited   open
```

This is inconsistent with `waspflow status corrupt`, which correctly says the
state is corrupted. List/check/reap need one shared state-read/schema boundary;
they should mark the lane corrupt and return a meaningful nonzero status when
that makes the requested answer unreliable.

## 4. SEAM-MAJOR — malformed flags leak tool errors or silently alter the requested operation

Argument parsing is strict in `spawn`, `exec`, `init`, and `check`, but the
read/control verbs often ignore unknown options or pass invalid values to shell
tools. That makes an agent's typo look like a real command result.

Reproducer A — invalid numeric values leak implementation errors:

```bash
home="$(mktemp -d)/wfhome"; mkdir -p "$home/lanes/good"
printf 'line one\n' > "$home/lanes/good/transcript.log"
jq -n --arg cwd "$PWD" --arg t "$home/lanes/good/transcript.log" \
  '{provider:"codex",status:"live",cwd:$cwd,transcript:$t}' \
  > "$home/lanes/good/state.json"
WASPFLOW_HOME="$home" WASPFLOW_TMUX_SESSION="audit-$$" \
  bin/waspflow peek good --lines nope
```

Observed output:

```text
tail: invalid number of lines: 'ope'
```

Reproducer B — an invalid `wait` timeout leaks Bash internals:

```bash
WASPFLOW_HOME="$home" WASPFLOW_TMUX_SESSION="audit-$$" \
  bin/waspflow wait good --timeout nope --interval 1
```

Observed output:

```text
bin/waspflow: line 519: nope: unbound variable
```

Reproducer C — an unknown list option is silently ignored and returns a full,
successful listing:

```bash
WASPFLOW_HOME="$home" WASPFLOW_TMUX_SESSION="audit-$$" bin/waspflow list --wat
```

Observed output (exit 0):

```text
LANE                 PROVIDER STATE    OUTCOME     CWD
good                 codex    exited   open        /…/waspflow-waspflow-xaudit
```

Each parser should reject unknown flags, require a value when a flag takes one,
and validate `--lines`, `--timeout`, and `--interval` before side effects. Every
failure should be a concise `waspflow: <verb>: …` message rather than `tail`,
`sleep`, `grep`, or Bash diagnostics.

## 5. SEAM-MINOR — help and reference discovery are incomplete at the point of use

Most advertised verbs do not support `<verb> --help`; some error, some execute
another code path, and `peek --help` leaks `grep` usage because `--help` reaches
the tmux-window name check. The README's Commands table also omits `ops`, `close`,
and `captured`; only `ops` appears later as an option reference.

Reproducer:

```bash
for verb in spawn exec list status peek wait revise attach close captured reap doctor; do
  out="$(WASPFLOW_HOME="$(mktemp -d)/wfhome" \
    WASPFLOW_TMUX_SESSION="audit-help-$$" bin/waspflow "$verb" --help 2>&1)"
  printf '%-9s rc=%s  %s\n' "$verb" "$?" "$(printf '%s\n' "$out" | sed -n '1p')"
done
```

Observed output excerpt:

```text
spawn     rc=1  waspflow: spawn: unknown option '--help'
list      rc=0  (no lanes)
peek      rc=1  Usage: grep [OPTION]... PATTERNS [FILE]...
close     rc=1  waspflow: close: unknown option '--help'
doctor    rc=0  waspflow doctor
```

For an agent-operable CLI, every verb needs a stable `--help` contract (including
argument grammar, defaults, exits, and recovery guidance). Add the three omitted
verbs to the README table and ensure docs and the top-level usage stay in parity.

## What's already excellent

- The deterministic shipped verification suite passes under an isolated tmux
  socket: `bash -n bin/waspflow lib/*.sh lib/providers/*.sh` followed by
  `scripts/verify.sh` ended with `waspflow verify: ok`.
- Recent honesty hardening is real: oversized lane names are rejected before the
  filesystem does it, `status` turns malformed JSON into a clear Waspflow error,
  and the suite covers submission confirmation, stale-idle barriers, stall
  surfacing, verification receipts, and provider idle predicates.
- `spawn` and `exec` have notably stronger argument validation and billing
  messaging than the older read/control verbs. That consistency target is clear;
  extending it is a focused cleanup, not a redesign.
