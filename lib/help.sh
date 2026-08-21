# help.sh — parser-derived CLI help registry.
#
# This module owns the public command list and its help text. `main` consults
# the same list before dispatching, and verify.sh sources it for help coverage.

help_command_registry() {
  cat <<'EOF'
spawn cmd_spawn
exec cmd_exec
ops cmd_ops
init cmd_init
demo cmd_demo
list cmd_list
receipts cmd_receipts
status cmd_status
events cmd_events
inspect cmd_inspect
peek cmd_peek
wait cmd_wait
park cmd_park
gc cmd_gc
revise cmd_revise
accept-runtime cmd_accept_runtime
attach cmd_attach
close cmd_close
captured cmd_captured
verify cmd_verify
escalate cmd_escalate
reap cmd_reap
check cmd_check
doctor cmd_doctor
EOF
}

help_command_names() {
  local command handler
  while read -r command handler; do
    [[ -n "$command" ]] && printf '%s\n' "$command"
  done < <(help_command_registry)
}

help_canonical_command() {
  case "$1" in
    ls) printf '%s\n' list ;;
    *) printf '%s\n' "$1" ;;
  esac
}

help_command_handler() {
  local wanted="$1" command
  local handler
  while read -r command handler; do
    if [[ "$command" == "$wanted" ]]; then
      printf '%s\n' "$handler"
      return 0
    fi
  done < <(help_command_registry)
  return 1
}

# Help flags after `--` belong to a prompt or message, not the CLI. Before
# that delimiter, skip values for every value-taking parser flag so a literal
# `--help` value retains its original command behavior.
help_requested() {
  local argument value_next=false
  for argument in "$@"; do
    [[ "$argument" == "--" ]] && return 1
    if [[ "$value_next" == true ]]; then
      value_next=false
      continue
    fi
    [[ "$argument" == "--help" || "$argument" == "-h" ]] && return 0
    case "$argument" in
      --provider|--op|--lane|--model|--effort|--mcp|--cwd|--report|--verify|--verify-name|--verify-timeout|--verify-strength|--prepare|--parent-ref|--arg|-o|--task|--constraint|--profile|--status|--lifecycle-state|--project|--limit|--tail-events|--lines|--timeout|--interval|--reason|--lane-age|--out|--into|--by|--in|--to|--note|--config)
        value_next=true
        ;;
    esac
  done
  return 1
}

help_usage() {
  case "$1" in
    spawn) help_usage_spawn ;;
    exec) help_usage_exec ;;
    ops) help_usage_ops ;;
    init) help_usage_init ;;
    demo) help_usage_demo ;;
    list) help_usage_list ;;
    receipts) help_usage_receipts ;;
    status) help_usage_status ;;
    events) help_usage_events ;;
    inspect) help_usage_inspect ;;
    peek) help_usage_peek ;;
    wait) help_usage_wait ;;
    park) help_usage_park ;;
    gc) help_usage_gc ;;
    revise) help_usage_revise ;;
    accept-runtime) help_usage_accept_runtime ;;
    attach) help_usage_attach ;;
    close) help_usage_close ;;
    captured) help_usage_captured ;;
    verify) help_usage_verify ;;
    escalate) help_usage_escalate ;;
    reap) help_usage_reap ;;
    check) help_usage_check ;;
    doctor) help_usage_doctor ;;
    *) return 1 ;;
  esac
  cat <<'EOF'

Help:
  --help, -h                  Print this help text.
EOF
}

help_command_list() {
  local command description
  while IFS= read -r command; do
    [[ -n "$command" ]] || continue
    description="$(help_usage "$command" | sed -n '1p')"
    printf '  %-16s %s\n' "$command" "$description"
  done < <(help_command_names)
}

help_global_usage() {
  cat <<EOF
waspflow — turnkey live orchestration of Claude/Codex/Grok/Antigravity/Qwen/DeepSeek agents in tmux.

First successful run:
  waspflow doctor
  waspflow demo --provider codex
  waspflow demo --provider codex --run

Commands:
EOF
  help_command_list
  cat <<EOF

Detailed flags and examples:
  waspflow <command> --help

Operating points (not cheap/default/max profiles):
  waspflow ops list --task implementation
  waspflow ops explain implement.standard
  waspflow ops resolve review.audit --json
  waspflow spawn --op implement.standard --lane fix -- "…"
  # explicit flags always win over --op expansion

Fan-in (docs/lane-closeout-and-fan-in.md):
  close   <lane> --status harvested  --into <pr#|ref>   # work landed here
  close   <lane> --status superseded --by   <lane|ref>  # a better version won
  close   <lane> --status abandoned  --reason "..."     # dead end, dropped
  list    --status harvested,superseded,abandoned        # the reap-safe set
  reap    --status harvested,superseded,abandoned        # fan-in cleanup, one command

Provider command forms:
$(help_usage spawn | sed -n '4p')
$(help_usage exec | sed -n '4p')
$(help_usage demo | sed -n '4p')

Billing safety:
  Claude workers refuse to launch when ANTHROPIC_API_KEY is set because that
  bills pay-as-you-go API rates instead of subscription/Agent-SDK credit.
  Unset ANTHROPIC_API_KEY, or intentionally override with:
    WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude ...

State: $WASPFLOW_HOME (default ~/.local/state/waspflow)
tmux:  $WASPFLOW_TMUX_SESSION (default waspflow)

Exit codes: 1 usage/error; 2 failed contract; 3 launch unconfirmed; 4 stalled;
            5 selection_required (nothing launched; choose an arm and retry)
EOF
}

help_usage_spawn() {
  cat <<'EOF'
Start a durable worker lane.

Usage:
  waspflow spawn (--provider <claude|codex|grok|antigravity|qwen|deepseek> | --op <id>) --lane <name> [options] -- <task>

Flags:
  --provider <provider>       Choose the worker provider.
  --op <id>                   Expand an operating point into launch settings.
  --lane <name>               Name the durable lane.
  --model <id>                Override the provider model.
  --auto                      Select the operating point fallback; requires --op.
  --ack-deprecated            Permit --auto to use an edge-deprecated fallback.
  --accept-provider-default   Explicitly use the provider default model.
  --effort <level>            Pass a reasoning-effort level to the provider.
  --mcp <auto|none|inherit>   Set the MCP policy; defaults to auto.
  --cwd <dir>                 Set the worker directory; defaults to the current directory.
  --isolate, --worktree       Create an isolated Git worktree for the lane.
  --report <path>             Require this report when the lane is reaped.
  --no-recovery               Do not make the one report-recovery attempt at reap.
  --verify <command>          Configure the lane verification command.
  --verify-name <name>        Label verification receipts; defaults to verify.
  --verify-timeout <seconds>  Set the verification timeout; defaults to 1800.
  --verify-strength <level>   Declare verification strength as suite or smoke.
  --prepare <command>         Run this setup command before verification.
  --parent-ref <ref>          Record an opaque parent-session reference in provenance.
  --arg <flag>                Pass one extra argument to the provider CLI; repeatable.

Examples:
  waspflow spawn --provider codex --accept-provider-default --lane fix -- "Fix the failing test."
  waspflow spawn --op implement.standard --lane api --isolate --verify 'npm test' -- "Add pagination."
EOF
}

help_usage_exec() {
  cat <<'EOF'
Run a headless one-shot task without creating a lane.

Usage:
  waspflow exec (--provider <claude|codex|grok|antigravity|qwen|deepseek> | --op <id>) [options] -- <task>

Flags:
  --provider <provider>       Choose the headless worker provider.
  --op <id>                   Expand an operating point into execution settings.
  --model <id>                Override the provider model.
  --auto                      Select the operating point fallback; requires --op.
  --ack-deprecated            Permit --auto to use an edge-deprecated fallback.
  --accept-provider-default   Explicitly use the provider default model.
  --effort <level>            Pass a reasoning-effort level to the provider.
  --mcp <auto|none|inherit>   Set the MCP policy; defaults to auto.
  --cwd <dir>                 Set the task directory; defaults to the current directory.
  -o <file>                   Write the final message to this file instead of stdout.

Examples:
  waspflow exec --provider codex --accept-provider-default -- "Summarize this repository."
  waspflow exec --op review.audit -o findings.txt -- "Review the auth changes."
EOF
}

help_usage_ops() {
  cat <<'EOF'
Resolve task-shaped operating points to explicit launch settings.

Usage:
  waspflow ops list [--task <family>] [--constraint <family>]
  waspflow ops explain <op-id>
  waspflow ops resolve <op-id> [--json]
  waspflow ops path

Flags:
  --task <family>             Filter ops list results by task family.
  --constraint <family>       Filter ops list results by constraint family.
  --json                      Emit the resolved operating point as JSON.

Examples:
  waspflow ops list --task implementation
  waspflow ops resolve review.audit --json
EOF
}

help_usage_init() {
  cat <<'EOF'
Write a project .waspflow/config.json from reusable profiles.

Usage:
  waspflow init [--cwd <dir>] [--profile <name>]... [--force] [--print]

Flags:
  --cwd <dir>                 Choose the project directory; defaults to the current directory.
  --profile <name>            Add a composable profile; repeatable.
  --force                     Replace an existing configuration file.
  --print                     Print generated JSON instead of writing it.

Examples:
  waspflow init --profile serious-repo
  waspflow init --profile openspec --print
EOF
}

help_usage_demo() {
  cat <<'EOF'
Show or run a safe first worker-lane demonstration.

Usage:
  waspflow demo [--provider <claude|codex|grok|antigravity|qwen|deepseek>] [--lane <name>] [--cwd <dir>] [--run]

Flags:
  --provider <provider>       Choose the provider; otherwise detect one on PATH.
  --lane <name>               Set the demo lane name; defaults to a timestamped name.
  --cwd <dir>                 Set the demo directory; defaults to the current directory.
  --run                       Run the spawn, wait, peek, and reap demonstration.

Examples:
  waspflow demo --provider codex
  waspflow demo --provider codex --lane first-run --run
EOF
}

help_usage_list() {
  cat <<'EOF'
List durable lanes from the global lane index.

Usage:
  waspflow list [--status <outcomes>] [--lifecycle-state <states>] [--project <dir>] [--limit <n>] [--json]

Flags:
  --status <outcomes>         Filter by comma-separated fan-in outcomes.
  --lifecycle-state <states>  Filter by comma-separated live, exited, parked, or reaped states.
  --project <dir>             Filter to lanes for this project directory.
  --limit <n>                 Limit output to a positive number of lanes.
  --json                      Emit lane rows as JSON.

Examples:
  waspflow list --lifecycle-state live,exited
  waspflow list --project . --json
EOF
}

help_usage_receipts() {
  cat <<'EOF'
Summarize the append-only outcome receipt ledger.

Usage:
  waspflow receipts
  waspflow receipts summary [--json]

Flags:
  --json                      Emit the receipt summary as JSON.

Examples:
  waspflow receipts
  waspflow receipts summary --json
EOF
}

help_usage_status() {
  cat <<'EOF'
Show one lane's saved state or a safe provider-event tail.

Usage:
  waspflow status <lane> [--tail-events <n> --json]

Flags:
  --tail-events <n>           Read this many provider events; requires --json.
  --json                      Enable the required machine schema for --tail-events.

Examples:
  waspflow status fix
  waspflow status fix --tail-events 20 --json
EOF
}

help_usage_events() {
  cat <<'EOF'
Read a normalized provider-event tail for one lane.

Usage:
  waspflow events <lane> [--lines <n>] [--json]

Flags:
  --lines <n>                 Set the number of events to read; defaults to 40.
  --json                      Emit the normalized event tail as JSON.

Examples:
  waspflow events fix
  waspflow events fix --lines 20 --json
EOF
}

help_usage_inspect() {
  cat <<'EOF'
Inspect read-only lane reconciliation and cleanup classifications.

Usage:
  waspflow inspect <lane>
  waspflow inspect --json

Flags:
  --json                      Request fleet inspection; required when no lane is given and ignored for one lane.

Examples:
  waspflow inspect fix
  waspflow inspect --json
EOF
}

help_usage_peek() {
  cat <<'EOF'
Capture a lane pane for UI diagnosis or read its provider events.

Usage:
  waspflow peek <lane> [--lines <n>] [--events]

Flags:
  --lines <n>                 Set the number of lines to show; defaults to 40.
  --events                    Read the normalized provider-event tail instead of the pane.

Examples:
  waspflow peek fix
  waspflow peek fix --events --lines 20
EOF
}

help_usage_wait() {
  cat <<'EOF'
Wait for a lane to become idle, with optional reap.

Usage:
  waspflow wait <lane> [--timeout <seconds>] [--interval <seconds>] [--reap]

Flags:
  --timeout <seconds>         Stop waiting after this many seconds; defaults to 600.
  --interval <seconds>        Poll at this interval; defaults to 2.
  --reap                      Reap only after the lane becomes idle.

Examples:
  waspflow wait fix
  waspflow wait fix --timeout 300 --reap
EOF
}

help_usage_park() {
  cat <<'EOF'
Stop a verified-idle owned tmux window while preserving the lane.

Usage:
  waspflow park <lane> [--reason <text>] [--adopt-legacy]

Flags:
  --reason <text>             Record why the lane was parked; defaults to operator requested.
  --adopt-legacy              Adopt verified legacy window ownership before parking.

Examples:
  waspflow park fix --reason "Waiting for product input"
  waspflow park old-lane --adopt-legacy
EOF
}

help_usage_gc() {
  cat <<'EOF'
Select old safely parkable lanes, and optionally park them.

Usage:
  waspflow gc [--lane-age <seconds>] [--project <dir>] [--adopt-legacy] [--apply]

Flags:
  --lane-age <seconds>        Select lanes at least this old; defaults from WASPFLOW_GC_LANE_AGE_SECONDS or 86400.
  --project <dir>             Limit selection to this project directory.
  --adopt-legacy              Allow verified legacy ownership adoption before parking.
  --apply                     Park selected lanes; without it, gc is a dry run.

Examples:
  waspflow gc --lane-age 86400
  waspflow gc --project . --apply
EOF
}

help_usage_revise() {
  cat <<'EOF'
Send another instruction to an existing lane.

Usage:
  waspflow revise <lane> [--out <file>] -- <message>

Flags:
  --out <file>                Send the provider response to this file.

Examples:
  waspflow revise fix -- "Add a regression test too."
  waspflow revise fix --out reply.txt -- "Summarize remaining risk."
EOF
}

help_usage_accept_runtime() {
  cat <<'EOF'
Record acceptance of an observed Codex runtime mismatch.

Usage:
  waspflow accept-runtime <lane> --reason <text>

Flags:
  --reason <text>             Record why the observed runtime mismatch is accepted.

Examples:
  waspflow accept-runtime fix --reason "Provider fallback approved for this run"
EOF
}

help_usage_attach() {
  cat <<'EOF'
Attach the terminal to a lane's live tmux pane.

Usage:
  waspflow attach <lane>

Flags:
  No command-specific flags.

Examples:
  waspflow attach fix
EOF
}

help_usage_close() {
  cat <<'EOF'
Record a lane's fan-in outcome and provenance.

Usage:
  waspflow close <lane> --status <harvested|superseded|abandoned|open> [--into <ref> | --by <lane-or-ref> | --reason <text>]

Flags:
  --status <outcome>          Set the required fan-in outcome.
  --into <ref>                Record where harvested work landed.
  --by <lane-or-ref>          Record which lane or ref superseded the work.
  --reason <text>             Record why the work was abandoned.

Examples:
  waspflow close fix --status harvested --into PR#42
  waspflow close experiment --status abandoned --reason "Approach was invalid"
EOF
}

help_usage_captured() {
  cat <<'EOF'
Check whether a lane's work is already present in a Git ref by content.

Usage:
  waspflow captured <lane> --in <ref>

Flags:
  --in <ref>                  Compare the lane's work against this Git ref.

Examples:
  waspflow captured fix --in main
EOF
}

help_usage_verify() {
  cat <<'EOF'
Run a lane's configured verification contract without teardown.

Usage:
  waspflow verify <lane> [--json]

Flags:
  --json                      Emit the verification result as JSON.

Examples:
  waspflow verify fix
  waspflow verify fix --json
EOF
}

help_usage_escalate() {
  cat <<'EOF'
Switch a failed lane to another operating point or provider arm.

Usage:
  waspflow escalate <lane> [--to <op-id|provider/model[/effort]>] [--handoff] [--reset-tree] [--force] [--ack-deprecated] [--note <text>] [--json] [--resume-transition | --abort-transition]

Flags:
  --to <target>               Select the target operating point or provider/model[/effort].
  --handoff                   Start the target as a fresh handoff instead of reusing the session.
  --reset-tree                Reset the worktree during a handoff.
  --force                     Escalate without an eligible failed checkpoint.
  --ack-deprecated            Permit a deprecated target fallback.
  --note <text>               Record an escalation note in the transition.
  --json                      Emit escalation results as JSON.
  --resume-transition         Continue a persisted escalation transition.
  --abort-transition          Abort a persisted escalation transition.

Examples:
  waspflow escalate fix --to review.audit
  waspflow escalate fix --to review.audit --handoff --json
EOF
}

help_usage_reap() {
  cat <<'EOF'
Finalize one lane or a selected set of fan-in outcomes.

Usage:
  waspflow reap <lane> [--force] [--keep-worktree] [--no-archive]
  waspflow reap --status <outcomes> [--force] [--keep-worktree] [--no-archive]

Flags:
  --status <outcomes>         Reap lanes with comma-separated fan-in outcomes.
  --force                     Force cleanup when normal checks refuse it.
  --keep-worktree             Preserve an isolated worktree during reap.
  --no-archive                Do not archive the lane during reap.

Examples:
  waspflow reap fix
  waspflow reap --status harvested,superseded,abandoned
EOF
}

help_usage_check() {
  cat <<'EOF'
Run the project integrity gate for Git, lanes, and optional config checks.

Usage:
  waspflow check [--cwd <dir>] [--config <file>] [--no-fail] [--explain]

Flags:
  --cwd <dir>                 Choose the project directory; defaults to the current directory.
  --config <file>             Use this configuration file instead of discovery.
  --no-fail                   Report risks without failing the command.
  --explain                   Add remediation advice for reported risks.

Examples:
  waspflow check
  waspflow check --cwd ../api --explain
EOF
}

help_usage_doctor() {
  cat <<'EOF'
Check local prerequisites and supported agent CLIs.

Usage:
  waspflow doctor

Flags:
  No command-specific flags.

Examples:
  waspflow doctor
EOF
}
