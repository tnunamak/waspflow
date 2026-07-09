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

# ---- state home -------------------------------------------------------------
# All lane state (one dir per lane) lives here. Survives across the orchestrating
# session's own compaction/restart — that's the whole point.
WASPFLOW_HOME="${WASPFLOW_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/waspflow}"
WASPFLOW_LANES_DIR="$WASPFLOW_HOME/lanes"

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

# Lane names become tmux window names and dir names; keep them tame.
validate_lane_name() {
  local lane="$1"
  [[ -n "$lane" ]] || die "lane name is required"
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
lane_set() {
  local lane="$1"; shift
  local dir sf tmp
  dir="$(lane_dir "$lane")"
  mkdir -p "$dir"
  sf="$dir/state.json"
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
  tmp="$(mktemp)"
  jq "${jq_args[@]}" "$jq_set" "$sf" >"$tmp" && mv "$tmp" "$sf"
}

list_lanes() {
  [[ -d "$WASPFLOW_LANES_DIR" ]] || return 0
  find "$WASPFLOW_LANES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# ---- tmux helpers -----------------------------------------------------------
# All windows live in a dedicated session so we never disturb the user's tmux.
tmux_ensure_session() {
  tmux has-session -t "$WASPFLOW_TMUX_SESSION" 2>/dev/null && return 0
  # Create detached with a placeholder window we immediately leave alone.
  tmux new-session -d -s "$WASPFLOW_TMUX_SESSION" -n _waspflow_home 2>/dev/null || true
}

tmux_window_target() { echo "$WASPFLOW_TMUX_SESSION:$1"; }

tmux_window_exists() {
  tmux list-windows -t "$WASPFLOW_TMUX_SESSION" -F '#{window_name}' 2>/dev/null \
    | grep -qxF "$1"
}

# Paste literal text into a tmux pane without key-name parsing. Use this for
# prompts/messages; `tmux send-keys -- "$text"` is unreliable for long text and
# can mangle spaces or special characters.
tmux_paste_text() {
  local target="$1" text="$2" tmp buffer
  tmp="$(mktemp)"
  buffer="waspflow-$$-$RANDOM"
  printf '%s' "$text" >"$tmp"
  tmux load-buffer -b "$buffer" "$tmp"
  tmux paste-buffer -d -b "$buffer" -t "$target"
  rm -f "$tmp"
}

# Strip ANSI escapes from captured pane text for human/log consumption.
strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][AB0]//g'; }

# ---- provider adapter dispatch ---------------------------------------------
# Each provider is a file lib/providers/<provider>.sh defining shell functions
# named  <provider>_spawn  <provider>_is_idle  <provider>_revise
#        <provider>_preflight  <provider>_discover_session
# core.sh sources the right one and calls through these names.
load_provider() {
  local provider="$1"
  local f="$WASPFLOW_LIB/providers/$provider.sh"
  [[ -f "$f" ]] || die "unknown provider '$provider' (no adapter at $f)"
  # shellcheck disable=SC1090
  source "$f"
  local fn
  for fn in spawn is_idle revise preflight discover_session session_resumable; do
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
