#!/usr/bin/env bash
#
# core.sh — waspflow shared engine. Sourced by the CLI and every provider
# adapter. Owns: paths, lane-state store, logging, small utilities, and the
# provider-adapter dispatch contract. NO provider-specific logic lives here.
#
# Portability contract (so this moves to another machine/user as a config swap,
# never a rewrite):
#   - No hardcoded repo paths. The tool runs from ANY cwd.
#   - State lives under $WASPFLOW_HOME (default ~/.local/state/waspflow).
#   - Anything machine-specific (the Codex backend health URL, session dirs)
#     is a variable with an env override, defined here, used by adapters.

set -euo pipefail

# ---- locate ourselves -------------------------------------------------------
# WASPFLOW_LIB is the dir holding this file; WASPFLOW_ROOT is the repo root.
WASPFLOW_LIB="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WASPFLOW_ROOT="${WASPFLOW_ROOT:-$(cd "$WASPFLOW_LIB/.." && pwd)}"

# Generated effort unions from minnows capabilities (optional; adapters hard-fail themselves).
if [[ -f "$WASPFLOW_LIB/generated/effort-whitelists.sh" ]]; then
  # shellcheck source=/dev/null
  source "$WASPFLOW_LIB/generated/effort-whitelists.sh"
fi

# ---- state home -------------------------------------------------------------
# All lane state (one dir per lane) lives here. Survives across the orchestrating
# session's own compaction/restart — that's the whole point.
WASPFLOW_HOME="${WASPFLOW_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/waspflow}"
WASPFLOW_LANES_DIR="$WASPFLOW_HOME/lanes"
WASPFLOW_LOCKS_DIR="$WASPFLOW_HOME/locks"

# ---- machine-specific knobs (env-overridable) -------------------------------
# If Codex is configured to route its model calls through a local proxy, set this
# to that proxy's health URL; the codex adapter preflights it before spawning a
# Codex lane, since a turn never completes if the proxy is down. Leave EMPTY
# (the default) when Codex reaches its model directly — then no preflight runs.
# Example: export WASPFLOW_CODEX_BACKEND_HEALTH_URL=http://127.0.0.1:8787/health
WASPFLOW_CODEX_BACKEND_HEALTH_URL="${WASPFLOW_CODEX_BACKEND_HEALTH_URL:-}"

# tmux session that holds all waspflow windows. Keeping them in one named
# session makes list/attach/reap predictable and avoids polluting the user's
# default session.
WASPFLOW_TMUX_SESSION="${WASPFLOW_TMUX_SESSION:-waspflow}"

# ---- logging ----------------------------------------------------------------
_wf_is_tty() { [[ -t 2 ]]; }
_wf_color() { _wf_is_tty && printf '\033[%sm' "$1" || true; }
_wf_reset() { _wf_is_tty && printf '\033[0m' || true; }

log()  { printf '%swaspflow:%s %s\n' "$(_wf_color 36)" "$(_wf_reset)" "$*" >&2; }
warn() { printf '%swaspflow:%s %s\n' "$(_wf_color 33)" "$(_wf_reset)" "$*" >&2; }
err()  { printf '%swaspflow:%s %s\n' "$(_wf_color 31)" "$(_wf_reset)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# shellcheck disable=SC1090
source "$WASPFLOW_LIB/billing.sh"

# ---- dependency checks ------------------------------------------------------
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required command(s): ${missing[*]}"
}

# ---- ids --------------------------------------------------------------------
new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    die "no UUID source (need /proc/sys/kernel/random/uuid or uuidgen)"
  fi
}

# Refuse to hand a worker the filesystem root as its cwd. Real incident: grok
# workers spawned with `--cwd /` crashed and dumped multi-GB cores. Root is never
# a legitimate workspace; require an explicit opt-in to allow it. The caller must
# pass an ALREADY-RESOLVED absolute path (post `cd && pwd`). Args: resolved_cwd
guard_cwd() {
  local cwd="$1"
  if [[ "$cwd" == "/" && "${WASPFLOW_ALLOW_ROOT_CWD:-0}" != "1" ]]; then
    die "refusing to run a worker with cwd '/' (known crash class: multi-GB core dumps). Set WASPFLOW_ALLOW_ROOT_CWD=1 to override."
  fi
}

# Fail a bad --model FAST, with the valid set, instead of 30s into the run (or —
# worse — silently running the wrong model). Providers own model discovery; a
# live provider query is preferred and a local cache is only its fail-open
# fallback. If neither can enumerate, the CLI remains the real backstop.
# Args: provider model verb
validate_model() {
  local provider="$1" model="$2" verb="${3:-spawn}"
  [[ -n "$model" ]] || return 0
  local valid; valid="$("${provider}_valid_models" 2>/dev/null || true)"
  [[ -n "$valid" ]] || return 0                       # fail open: nothing to check against
  grep -qxF "$model" <<<"$valid" && return 0
  err "$verb: model '$model' is not available for $provider on the current auth."
  err "  valid models: $(tr '\n' ' ' <<<"$valid" | tr -s ' ' | sed 's/ /, /g; s/, $//')"
  die "  fix --model (or omit it to use the provider default)"
}

# Resolve the public MCP policy through the provider adapter. The adapter returns
# a compact command description, keeping provider flags, environment knobs, and
# discovery out of cmd_spawn/exec. Globals are deliberately grouped here because
# bash has no structured return values:
#   MCP_RESOLVED, MCP_WARNING, MCP_ARGV_JSON, MCP_ENV_JSON
# Args: provider requested(auto|none|inherit) effective_cwd
resolve_mcp_policy() {
  local provider="$1" requested="$2" effective_cwd="${3:-$PWD}" raw
  case "$requested" in auto|none|inherit) ;; *) err "--mcp must be auto, none, or inherit (got: $requested)"; return 1 ;; esac
  raw="$("${provider}_mcp_policy" "$requested" "$effective_cwd")" || return 1
  jq -e '.resolved | strings' >/dev/null <<<"$raw" \
    && jq -e '.warning | strings' >/dev/null <<<"$raw" \
    && jq -e '(.argv | arrays) and (.env | objects)' >/dev/null <<<"$raw" || {
      err "$provider: invalid MCP policy response"
      return 1
    }
  MCP_RESOLVED="$(jq -r '.resolved' <<<"$raw")"
  MCP_WARNING="$(jq -r '.warning' <<<"$raw")"
  MCP_ARGV_JSON="$(jq -c '.argv' <<<"$raw")"
  MCP_ENV_JSON="$(jq -c '.env' <<<"$raw")"
}

# Raw provider flags are intentionally powerful. Under an isolation policy,
# let the provider reject flag families that can introduce MCP configuration
# after discovery. `inherit` remains the explicit escape hatch.
validate_mcp_extra() {
  local provider="$1" requested="$2"; shift 2
  if declare -F "${provider}_mcp_validate_extra" >/dev/null; then
    "${provider}_mcp_validate_extra" "$requested" "$@" \
      || die "$provider: pass-through flags conflict with --mcp $requested (use --mcp inherit only when the task needs custom MCP configuration)"
  fi
}

# Decode the persisted, provider-resolved command description for an adapter.
# Older lanes have no policy fields and intentionally preserve their old behavior.
mcp_policy_load_lane() {
  local lane="$1" argv_json env_json
  argv_json="$(lane_get "$lane" mcp_argv)"
  env_json="$(lane_get "$lane" mcp_env)"
  mcp_policy_load_json "$argv_json" "$env_json" "lane '$lane'"
}

# Decode a resolved policy for a direct provider command (exec) or lane command.
# Args: argv_json env_json error_subject
mcp_policy_load_json() {
  local argv_json="$1" env_json="$2" subject="$3"
  [[ -n "$argv_json" ]] || argv_json='[]'
  [[ -n "$env_json" ]] || env_json='{}'
  jq -e 'type == "array" and all(.[]; type == "string" and (test("[\\r\\n]") | not))' \
    >/dev/null <<<"$argv_json" || die "$subject has invalid MCP argv state"
  jq -e 'type == "object" and all(to_entries[];
      (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and
      (.value | type == "string" and (test("[\\r\\n]") | not)))' \
    >/dev/null <<<"$env_json" || die "$subject has invalid MCP env state"
  MCP_ARGV=()
  MCP_ENV=()
  mapfile -t MCP_ARGV < <(jq -r '.[]' <<<"$argv_json")
  mapfile -t MCP_ENV < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env_json")
}

# Lane names become tmux window names and dir names; keep them tame.
validate_lane_name() {
  local lane="$1"
  [[ -n "$lane" ]] || die "lane name is required"
  # Length cap: a lane name becomes a directory component. Over ~255 bytes the
  # later mkdir fails with a raw "File name too long" from the OS; catch it here
  # with a clear waspflow error instead. (Red-team finding, 2026-07-10.)
  [[ "${#lane}" -le 100 ]] \
    || die "lane name too long (${#lane} chars; max 100) — keep lane names short and unique"
  [[ "$lane" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "invalid lane name '$lane' (use letters, digits, . _ -)"
}

# ---- lane state store -------------------------------------------------------
# One dir per lane: $WASPFLOW_LANES_DIR/<lane>/state.json (+ transcript.log).
# state.json is the single source of truth an orchestrator reads after its own
# compaction to recover what it spawned.
lane_dir()        { echo "$WASPFLOW_LANES_DIR/$1"; }
lane_state_file() { echo "$(lane_dir "$1")/state.json"; }
lane_transcript() { echo "$(lane_dir "$1")/transcript.log"; }

lane_exists() { [[ -f "$(lane_state_file "$1")" ]]; }

# Read one field from a lane's state.json. Empty string if absent.
lane_get() {
  local lane="$1" field="$2" sf
  sf="$(lane_state_file "$lane")"
  [[ -f "$sf" ]] || { echo ""; return 0; }
  jq -r --arg f "$field" '.[$f] // ""' "$sf" 2>/dev/null || echo ""
}

# Write/merge fields into a lane's state.json. Args: lane k1 v1 k2 v2 ...
# Always stamps updated_at (epoch). Creates the dir + file if absent.
#
# CONCURRENCY: the read-modify-write (read state.json, merge fields via jq, write
# back) is serialized per-lane with flock, so two concurrent lane_set calls to the
# SAME lane can't lose each other's fields (last-writer-wins-with-lost-updates was a
# real fleet seam). The lock is per-lane, so different lanes never contend. Falls
# back to the un-locked path if flock is unavailable (rare) — the atomic mv still
# prevents a torn/corrupt file, only concurrent-same-lane updates could be lost.
lane_set() {
  local lane="$1"; shift
  local dir; dir="$(lane_dir "$lane")"
  mkdir -p "$dir"
  if command -v flock >/dev/null 2>&1; then
    local lockf="$dir/.state.lock"
    ( flock 9; _lane_set_locked "$dir" "$@" ) 9>"$lockf"
  else
    _lane_set_locked "$dir" "$@"
  fi
}

# Serialize lifecycle transitions that must re-check provider/tmux state and
# then act on it atomically with respect to other waspflow commands. State-file
# writes have their own short lock; this longer operation lock covers
# revise/park/reap so a revise cannot start between park's idle proof and kill.
lane_operation_run() {
  local lane="$1"; shift
  command -v flock >/dev/null 2>&1 || {
    err "lane '$lane': flock is required for safe lifecycle transitions"
    return 1
  }
  local lockf
  mkdir -p "$WASPFLOW_LOCKS_DIR"
  lockf="$WASPFLOW_LOCKS_DIR/$lane.lock"
  ( flock -x 9; "$@" ) 9>"$lockf"
}

# The critical section: read → merge → atomic write. MUST run under the lane lock
# (or single-threaded). Args: dir k1 v1 k2 v2 ...
_lane_set_locked() {
  local dir="$1"; shift
  local sf="$dir/state.json" tmp
  [[ -f "$sf" ]] || echo '{}' >"$sf"
  # Build a jq assignment object from the k/v pairs.
  local jq_args=() jq_set='.'
  local i=0
  while [[ $# -gt 0 ]]; do
    local k="$1" v="${2:-}"; shift 2 || shift $#
    jq_args+=(--arg "k$i" "$k" --arg "v$i" "$v")
    jq_set="$jq_set | .[\$k$i] = \$v$i"
    i=$((i+1))
  done
  jq_set="$jq_set | .updated_at = (now | floor | tostring)"
  tmp="$(mktemp "$dir/.state.XXXXXX")"   # same dir → mv is atomic (same filesystem)
  if jq "${jq_args[@]}" "$jq_set" "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"   # never leave a partial temp or clobber good state on jq failure
    return 1
  fi
}

list_lanes() {
  [[ -d "$WASPFLOW_LANES_DIR" ]] || return 0
  find "$WASPFLOW_LANES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# The lane directory is the durable, global lane index.  Paths in a record are
# intentionally compared as paths rather than by a transient shell cwd, so a
# caller can scope a fleet query to a project after restarting its harness.
lane_matches_project() {
  local lane="$1" project="$2" candidate
  for candidate in "$(lane_get "$lane" repo_root)" "$(lane_get "$lane" cwd)" "$(lane_get "$lane" origin_cwd)"; do
    [[ -n "$candidate" ]] || continue
    case "$candidate" in "$project"|"$project"/*) return 0 ;; esac
  done
  return 1
}

# ---- tmux helpers -----------------------------------------------------------
# All windows live in a dedicated session so we never disturb the user's tmux.
tmux_ensure_session() {
  tmux has-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null && return 0
  # Create detached with a placeholder window we immediately leave alone.
  tmux new-session -d -s "$WASPFLOW_TMUX_SESSION" -n _waspflow_home 2>/dev/null || true
}

tmux_window_target() {
  local recorded
  recorded="$(lane_get "$1" tmux_window)"
  [[ -n "$recorded" ]] && printf '%s\n' "$recorded" \
    || printf '%s:%s\n' "$WASPFLOW_TMUX_SESSION" "$1"
}

# Record the exact tmux objects created for a successful spawn. Window ids are
# server-unique; the pane PID adds a cheap identity check before lifecycle code
# kills anything. They contain no prompts, session tokens, or provider secrets.
tmux_capture_lane_ownership() {
  local lane="$1" target="${2:-$(tmux_window_target "$1")}" session window pane_pid
  IFS='|' read -r session window pane_pid < <(
    tmux display-message -p -t "$target" '#{session_name}|#{window_id}|#{pane_pid}' 2>/dev/null
  ) || return 1
  [[ -n "$session" && -n "$window" && "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  lane_set "$lane" tmux_session "$session" tmux_window "$window" tmux_pane_pid "$pane_pid"
}

# ---- descendant-process ownership (cgroup scopes) -------------------------
# tmux identifies a pane, not every descendant of the command it started. A
# process can setsid/double-fork, outlive that pane, and still be owned by the
# lane. A transient user scope is the ownership boundary for those descendants:
# a child retains its cgroup even after reparenting.
#
# A lane can run more than one command over its life (initial pane, headless
# revise, report recovery). Each successful command gets a distinct receipt.
# Receipts are append-only because an older scope can still hold a daemon when a
# later headless resume starts. The InvocationID makes a reused unit name safe:
# cleanup may signal a unit only when it is still the invocation we created.
tmux_cgroup_scope_available() {
  command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1
}

_lane_cgroup_receipt_append_locked() {
  local dir="$1" unit="$2" invocation="$3" sf="$dir/state.json" tmp
  [[ -f "$sf" ]] || echo '{}' >"$sf"
  tmp="$(mktemp "$dir/.state.XXXXXX")"
  if jq --arg unit "$unit" --arg invocation "$invocation" '
      .cgroup_scope_receipts = (
        (.cgroup_scope_receipts // [])
        | if type == "array" then . else [] end
        | if any(.[]; .unit == $unit and .invocation_id == $invocation) then .
          else . + [{unit:$unit, invocation_id:$invocation}]
          end
      )
      | .cgroup_supervision = "systemd-scope"
      | .updated_at = (now | floor | tostring)
    ' "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Record an actual scope only after code running INSIDE that scope has read its
# InvocationID. This makes the receipt proof of ownership rather than a planned
# unit name. The per-lane lock preserves earlier receipts while a headless turn
# is being started.
tmux_append_lane_scope_receipt() {
  local lane="$1" unit="$2" invocation="$3" dir
  [[ "$unit" =~ ^waspflow-[A-Za-z0-9._-]+\.scope$ && "$invocation" =~ ^[A-Fa-f0-9-]+$ ]] || return 1
  dir="$(lane_dir "$lane")"
  mkdir -p "$dir"
  if command -v flock >/dev/null 2>&1; then
    ( flock 9; _lane_cgroup_receipt_append_locked "$dir" "$unit" "$invocation" ) 9>"$dir/.state.lock"
  else
    _lane_cgroup_receipt_append_locked "$dir" "$unit" "$invocation"
  fi
}

_lane_cgroup_fallback_append_locked() {
  local dir="$1" execution="$2" reason="$3" sf="$dir/state.json" tmp
  [[ -f "$sf" ]] || echo '{}' >"$sf"
  tmp="$(mktemp "$dir/.state.XXXXXX")"
  if jq --arg execution "$execution" --arg reason "$reason" '
      .cgroup_fallbacks = (
        (.cgroup_fallbacks // [])
        | if type == "array" then . else [] end
        | . + [{execution:$execution, reason:$reason, at:(now | floor | tostring)}]
      )
      | .cgroup_supervision = "degraded-tmux-only"
      | .updated_at = (now | floor | tostring)
    ' "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
    return 1
  fi
}

# A fallback is an explicit, durable fact: the command ran with the historical
# tmux-only ownership model because a scope was unavailable or failed to launch.
tmux_record_lane_cgroup_fallback() {
  local lane="$1" execution="$2" reason="$3" dir
  dir="$(lane_dir "$lane")"
  mkdir -p "$dir"
  if command -v flock >/dev/null 2>&1; then
    ( flock 9; _lane_cgroup_fallback_append_locked "$dir" "$execution" "$reason" ) 9>"$dir/.state.lock"
  else
    _lane_cgroup_fallback_append_locked "$dir" "$execution" "$reason"
  fi
}

tmux_lane_scope_start_marker() {
  local lane="$1" unit="$2"
  printf '%s/.scope-started-%s\n' "$(lane_dir "$lane")" "$unit"
}

# Runs inside the newly-created scope. The marker distinguishes "the scope
# started but receipt persistence failed" from "systemd-run could not create a
# scope"; only the latter may execute the original command outside a scope.
tmux_enter_lane_scope() {
  local lane="$1" unit="$2" marker invocation
  shift 2
  # revise/reap hold the lane operation lock on fd 9. A detached child must
  # never inherit it or it can keep the lane permanently locked after its CLI
  # parent returns.
  { exec 9>&-; } 2>/dev/null || true
  marker="$(tmux_lane_scope_start_marker "$lane" "$unit")"
  : >"$marker"
  invocation="$(systemctl --user show "$unit" -p InvocationID --value 2>/dev/null)" || return 125
  [[ -n "$invocation" ]] || return 125
  tmux_append_lane_scope_receipt "$lane" "$unit" "$invocation" || return 125
  exec "$@"
}

tmux_enter_lane_scope_and_capture() {
  local lane="$1" unit="$2" run_dir="$3" marker invocation rc
  shift 3
  { exec 9>&-; } 2>/dev/null || true
  marker="$(tmux_lane_scope_start_marker "$lane" "$unit")"
  : >"$marker"
  invocation="$(systemctl --user show "$unit" -p InvocationID --value 2>/dev/null)" || return 125
  [[ -n "$invocation" ]] || return 125
  tmux_append_lane_scope_receipt "$lane" "$unit" "$invocation" || return 125
  # A headless CLI may daemonize. Do not make its caller wait for the detached
  # child (the scope rightly stays alive for reap); wait only for the CLI's own
  # result and replay its output to the caller after the completion receipt.
  set +e
  "$@" >"$run_dir/stdout" 2>"$run_dir/stderr"
  rc=$?
  printf '%s\n' "$rc" >"$run_dir/status"
  return "$rc"
}

# Run one lane-owned argv command. The scope wrapper writes its receipt before
# exec. If systemd accepted the scope but receipt recording failed, do NOT run a
# second unsupervised copy: return the failure instead. If scope creation itself
# fails after preflight, run the original command and record the degraded truth.
# Args: lane cwd execution -- command [args...]
tmux_run_owned_lane_command() {
  local lane="$1" cwd="$2" execution="$3" unit marker rc=0 run_dir=""
  shift 3
  [[ "${1:-}" == "--" ]] || return 2
  shift
  [[ $# -gt 0 ]] || return 2

  if ! tmux_cgroup_scope_available; then
    tmux_record_lane_cgroup_fallback "$lane" "$execution" "scope-unavailable" || return 1
    ( cd "$cwd" && "$@" )
    return $?
  fi

  unit="waspflow-${lane}-$(new_uuid).scope"
  marker="$(tmux_lane_scope_start_marker "$lane" "$unit")"
  rm -f "$marker"

  if [[ "$execution" == pane ]]; then
    ( cd "$cwd" && systemd-run --user --scope --unit="$unit" --collect --quiet -- \
        env "WASPFLOW_HOME=$WASPFLOW_HOME" "WASPFLOW_LIB=$WASPFLOW_LIB" \
        "WASPFLOW_TMUX_SESSION=$WASPFLOW_TMUX_SESSION" "PATH=$PATH" \
        bash -c 'source "$1"; tmux_enter_lane_scope "$2" "$3" "${@:4}"' -- \
        "$WASPFLOW_LIB/core.sh" "$lane" "$unit" "$@" ) || rc=$?
  else
    run_dir="$(mktemp -d "$(lane_dir "$lane")/.scope-run.XXXXXX")"
    ( cd "$cwd" && systemd-run --user --scope --no-block --unit="$unit" --collect --quiet -- \
        env "WASPFLOW_HOME=$WASPFLOW_HOME" "WASPFLOW_LIB=$WASPFLOW_LIB" \
        "WASPFLOW_TMUX_SESSION=$WASPFLOW_TMUX_SESSION" "PATH=$PATH" \
        bash -c 'source "$1"; tmux_enter_lane_scope_and_capture "$2" "$3" "$4" "${@:5}"' -- \
        "$WASPFLOW_LIB/core.sh" "$lane" "$unit" "$run_dir" "$@" ) || rc=$?
    # A successful no-block submission is not proof the unit started. Wait for
    # the in-scope marker, then for the primary CLI's completion receipt.
    local tries=0
    while [[ ! -f "$marker" && "$tries" -lt 50 ]]; do sleep 0.1; tries=$((tries + 1)); done
    if [[ -f "$marker" ]]; then
      while [[ ! -f "$run_dir/status" ]]; do sleep 0.1; done
      rc="$(<"$run_dir/status")"
      cat "$run_dir/stdout" "$run_dir/stderr"
      rm -rf "$run_dir" "$marker"
      return "$rc"
    fi
    rm -rf "$run_dir"
  fi

  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    return "$rc"
  fi

  # A no-block request that systemd accepted but never started is ambiguous: do
  # not duplicate a command that may be about to run outside our observation.
  # A definite launch failure (nonzero systemd-run, no start marker) is the P2
  # fallback case below.
  if [[ "$execution" != pane && "$rc" -eq 0 ]]; then
    lane_set "$lane" cgroup_supervision "scope-start-unconfirmed" || true
    return 1
  fi

  tmux_record_lane_cgroup_fallback "$lane" "$execution" "scope-launch-failed" || return 1
  ( cd "$cwd" && "$@" )
}

# A pane command is arbitrary shell syntax assembled by a provider adapter.
# Keep parsing at this boundary, then use the argv-based launcher above for the
# actual scope and fallback lifecycle.
tmux_run_owned_lane_shell_command() {
  local lane="$1" cwd="$2" execution="$3" shell_command="$4"
  tmux_run_owned_lane_command "$lane" "$cwd" "$execution" -- bash -c "$shell_command"
}

# Emit each receipt as unit<RS>InvocationID. Legacy scalar fields are read for
# compatibility with the rejected v1 experiment, but all new writes use the
# append-only array above.
tmux_lane_scope_receipts() {
  local lane="$1" sf
  sf="$(lane_state_file "$lane")"
  [[ -f "$sf" ]] || return 0
  jq -r '
    ((.cgroup_scope_receipts // []) | if type == "array" then . else [] end)
    + (if (.cgroup_scope // "") != "" and (.cgroup_scope_invocation_id // "") != ""
       then [{unit:.cgroup_scope, invocation_id:.cgroup_scope_invocation_id}] else [] end)
    | unique_by(.unit, .invocation_id)[]
    | select(.unit | type == "string")
    | select(.invocation_id | type == "string")
    | .unit + "\u001e" + .invocation_id
  ' "$sf" 2>/dev/null || true
}

# Reap every receipt independently. A stale/reused unit is harmless because its
# current InvocationID must equal the recorded value before it is signalled.
tmux_kill_owned_lane_scopes() {
  local lane="$1" unit invocation actual
  command -v systemctl >/dev/null 2>&1 || return 0
  while IFS=$'\x1e' read -r unit invocation; do
    [[ -n "$unit" && -n "$invocation" ]] || continue
    actual="$(systemctl --user show "$unit" -p InvocationID --value 2>/dev/null)" || continue
    [[ "$actual" == "$invocation" ]] || continue
    systemctl --user kill --kill-whom=all --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
    # The kill is the lifecycle action. Do not let a manager bookkeeping delay
    # (or a pathological descendant) block lane reaping after the signal was
    # issued; the verifier polls the cgroup independently.
    systemctl --user stop --no-block "$unit" >/dev/null 2>&1 || true
  done < <(tmux_lane_scope_receipts "$lane")
}

# Create and claim a lane window as one provider-facing operation. `-P` returns
# the exact new window id, avoiding tmux's ambiguous name lookup when duplicate
# names exist. If ownership capture fails, kill that exact id before returning.
# Args: lane cwd shell_command. Echoes the exact window id.
tmux_create_owned_lane_window() {
  local lane="$1" cwd="$2" shell_command="$3" window launcher
  # tmux panes inherit the tmux SERVER's environment, not necessarily the
  # caller's current WASPFLOW_HOME. Export the lane runtime coordinates into the
  # pane explicitly before it sources core, or its scope receipt would be
  # written to the operator's default state directory.
  launcher="export WASPFLOW_HOME=$(printf '%q' "$WASPFLOW_HOME") WASPFLOW_LIB=$(printf '%q' "$WASPFLOW_LIB") WASPFLOW_TMUX_SESSION=$(printf '%q' "$WASPFLOW_TMUX_SESSION") PATH=$(printf '%q' "$PATH"); source $(printf '%q' "$WASPFLOW_LIB/core.sh"); tmux_run_owned_lane_shell_command $(printf '%q' "$lane") $(printf '%q' "$cwd") pane $(printf '%q' "$shell_command")"
  tmux_ensure_session
  window="$(tmux new-window -d -P -F '#{window_id}' -t "$WASPFLOW_TMUX_SESSION" \
    -n "$lane" -c "$cwd" "bash -c $(printf '%q' "$launcher")")" || return 1
  [[ "$window" == @* ]] || return 1
  if ! tmux_capture_lane_ownership "$lane" "$window"; then
    tmux kill-window -t "$window" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$window"
}

# Echo a recorded window id only when it still names the same pane in the same
# tmux session. This is the ownership boundary used by park: a stale/reused
# window id must be refused, never killed.
tmux_owned_lane_window_target() {
  local lane="$1" session window pane_pid got_session got_window got_pid
  session="$(lane_get "$lane" tmux_session)"
  window="$(lane_get "$lane" tmux_window)"
  pane_pid="$(lane_get "$lane" tmux_pane_pid)"
  [[ -n "$session" && -n "$window" && "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  IFS='|' read -r got_session got_window got_pid < <(
    tmux display-message -p -t "$window" '#{session_name}|#{window_id}|#{pane_pid}' 2>/dev/null
  ) || return 1
  [[ "$got_session" == "$session" && "$got_window" == "$window" && "$got_pid" == "$pane_pid" ]] || return 1
  printf '%s\n' "$window"
}

tmux_owned_lane_window_exists() {
  tmux_owned_lane_window_target "$1" >/dev/null
}

tmux_kill_owned_lane_window() {
  local target
  target="$(tmux_owned_lane_window_target "$1")" || return 1
  tmux kill-window -t "$target"
}

# Name lookup exists only for explicit legacy adoption. Safety-critical cleanup
# otherwise uses recorded window-id + pane-pid ownership.
tmux_named_lane_window_exists() {
  tmux list-windows -t "$WASPFLOW_TMUX_SESSION" -F '#{window_name}' 2>/dev/null \
    | grep -qxF "$1"
}

# One-shot fleet inventory for bulk list/audit. Format is internal and chosen
# from validated lane-name/window-id/PID alphabets so it can be parsed without
# tmux's non-interpreted escape sequences.
tmux_fleet_snapshot() {
  tmux list-windows -t "$WASPFLOW_TMUX_SESSION" \
    -F '#{window_id}|#{window_name}|#{pane_pid}' 2>/dev/null || true
}

tmux_snapshot_has_lane() {
  local lane="$1" snapshot="$2" window pane_pid
  window="$(lane_get "$lane" tmux_window)"
  pane_pid="$(lane_get "$lane" tmux_pane_pid)"
  if [[ -n "$window" && "$pane_pid" =~ ^[0-9]+$ ]]; then
    awk -F '|' -v w="$window" -v p="$pane_pid" '$1 == w && $3 == p { found=1 } END { exit !found }' <<<"$snapshot"
  else
    awk -F '|' -v n="$lane" '$2 == n { found=1 } END { exit !found }' <<<"$snapshot"
  fi
}

tmux_window_exists() {
  # New lanes use recorded ownership. Keep the name fallback for pre-ownership
  # records so existing callers retain their historical behavior; safety-critical
  # park deliberately uses tmux_owned_lane_window_exists instead.
  if [[ -n "$(lane_get "$1" tmux_window)" ]]; then
    tmux_owned_lane_window_exists "$1" && return 0
    return 1
  fi
  tmux_named_lane_window_exists "$1"
}

# Paste literal text into a tmux pane without key-name parsing or newline
# translation. `-p -r` enables bracketed paste and preserves LF bytes; without
# it tmux turns LF into CR, which can leave a multiline task in the composer.
# Use this for prompts/messages; `tmux send-keys -- "$text"` is unreliable for
# long text and can mangle spaces or special characters.
tmux_paste_text() {
  local target="$1" text="$2" tmp buffer
  tmp="$(mktemp)"
  buffer="waspflow-$$-$RANDOM"
  printf '%s' "$text" >"$tmp"
  tmux load-buffer -b "$buffer" "$tmp"
  tmux paste-buffer -p -r -d -b "$buffer" -t "$target"
  rm -f "$tmp"
}

# Strip ANSI escapes from captured pane text for human/log consumption.
strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][AB0]//g'; }

# Does a captured pane look like it is BLOCKED on an interactive prompt that
# expects a human keystroke? These appear MID-RUN and can't be predicted per
# provider — quota/model-downgrade offers ("switch to a lesser model"),
# security-check waits ("additional verification, keep waiting?"), y/n
# confirmations, numbered menus. We DETECT and SURFACE them (so `wait` returns a
# distinct blocked state instead of stalling blind), but deliberately DO NOT
# auto-answer: guessing could downgrade the model or approve something unwanted.
# The caller answers via `revise`. Matches a question/choice STRUCTURE, not the
# bare composer `❯`, so an actively-working pane isn't flagged (and `wait` only
# calls this once it has ALSO confirmed the session log stopped growing).
# Echoes a short reason if blocked; empty (rc 1) if not. Args: pane_text
wf_pane_looks_blocked() {
  local pane="$1"
  # A numbered choice menu with a selection cursor (trust gate, downgrade offers).
  if grep -qiE '(^|\n)[[:space:]]*(❯|>|\*)?[[:space:]]*[12]\.[[:space:]]*(yes|no|continue|proceed|keep|switch|use)' <<<"$pane"; then
    echo "numbered choice prompt"; return 0
  fi
  # Explicit y/n or Enter-to-confirm gates.
  if grep -qiE '\[y/n\]|\(y/n\)|\(y/N\)|\[Y/n\]|press enter|enter to confirm|enter to continue' <<<"$pane"; then
    echo "confirm/keystroke prompt"; return 0
  fi
  # Known interactive question phrasings a human is expected to answer.
  if grep -qiE 'switch to a (lesser|smaller|different) model|approaching your (usage )?limit|additional (security|verification)|keep waiting\?|do you want to (continue|proceed|keep)|would you like to (continue|switch)' <<<"$pane"; then
    echo "interactive question awaiting input"; return 0
  fi
  return 1
}

# ---- provider adapter dispatch ---------------------------------------------
# Each provider is a file lib/providers/<provider>.sh defining shell functions
# named  <provider>_spawn  <provider>_is_idle  <provider>_revise
#        <provider>_preflight  <provider>_discover_session <provider>_mcp_policy
# core.sh sources the right one and calls through these names.
load_provider() {
  local provider="$1"
  local f="$WASPFLOW_LIB/providers/$provider.sh"
  [[ -f "$f" ]] || die "unknown provider '$provider' (no adapter at $f)"
  # shellcheck disable=SC1090
  source "$f"
  local fn
  for fn in spawn is_idle revise preflight discover_session session_resumable turn_mark valid_models mcp_policy; do
    declare -F "${provider}_${fn}" >/dev/null \
      || die "provider '$provider' adapter is missing function ${provider}_${fn}"
  done
}

# Known providers (for validation / help).
WASPFLOW_PROVIDERS=(claude codex grok)
is_known_provider() {
  local p
  for p in "${WASPFLOW_PROVIDERS[@]}"; do [[ "$p" == "$1" ]] && return 0; done
  return 1
}
