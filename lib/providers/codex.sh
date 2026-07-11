#!/usr/bin/env bash
#
# codex.sh — waspflow provider adapter for OpenAI Codex CLI.
#
# Mechanics verified by the 2026-06-15 live spike (see waspflow/docs/spike.md):
#   - Interactive TUI requires a REAL PTY. `codex | tee` fails ("stdout is not a
#     terminal") — so transcripts use `tmux pipe-pane`, never a pipe.
#   - `--skip-git-repo-check` is an `exec`-only flag, NOT valid on bare `codex`.
#   - Bare `codex` in a non-trusted dir blocks on a TRUST prompt
#     ("Do you trust the contents of this directory?"). We pre-trust by git-init'ing
#     a throwaway cwd, but also auto-answer the prompt via send-keys as a belt.
#   - The rollout JSONL  ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
#     is created LAZILY ON FIRST TURN (not at boot). Its filename encodes the
#     session UUID — that's the resume handle.
#   - IDLE when the last rollout event is  event_msg / payload.type == task_complete.
#   - Revise headlessly:  codex exec resume <SID> "<msg>" -o <FILE>
#     (re-enters the SAME session with full context; -o gives a clean last-message).
#   - If Codex is configured to route model calls through a local proxy, spawning
#     without it up yields a turn that never completes — so we PREFLIGHT a
#     configurable health URL ($WASPFLOW_CODEX_BACKEND_HEALTH_URL) when set.

CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
# The local cache is only a fallback. `codex debug models` is the
# provider-owned, auth-scoped source of truth at launch time.
CODEX_MODELS_CACHE="${CODEX_MODELS_CACHE:-$HOME/.codex/models_cache.json}"

# Valid model slugs for the CURRENT Codex auth. Prefer the live provider command;
# its local cache is a fail-open fallback only. Never curate slugs here: Codex's
# auth-scoped availability changes independently of waspflow releases.
codex_valid_models() {
  local source out
  if command -v codex >/dev/null 2>&1; then
    source="$(codex debug models 2>/dev/null || true)"
    out="$(jq -r '.models[].slug // empty' <<<"$source" 2>/dev/null || true)"
    [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
  fi
  [[ -r "$CODEX_MODELS_CACHE" ]] || return 1
  out="$(jq -r '.models[].slug // empty' "$CODEX_MODELS_CACHE" 2>/dev/null)"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Provider-owned MCP policy. `auto` means MCP-minimal for Codex today: disable
# every server the current Codex profile reports, discovered live at launch. This
# is deliberately not a waspflow list, so renamed/new servers cannot escape it.
# Args: requested policy; stdout: {resolved,warning,argv,env}
codex_mcp_policy() {
  local requested="$1" effective_cwd="${2:-$PWD}" raw names_json args_json='[]' name config
  case "$requested" in
    inherit)
      printf '%s\n' '{"resolved":"inherit","warning":"","argv":[],"env":{}}'
      return 0
      ;;
    auto|none) ;;
    *) return 1 ;;
  esac
  raw="$(cd "$effective_cwd" && codex mcp list --json 2>/dev/null)" || {
    err "codex: live MCP discovery failed; refusing '$requested' because configured servers may remain enabled"
    return 1
  }
  # Capture the installed CLI's real schema exactly: a top-level array of
  # server records with string names. Do not imagine compatibility shapes;
  # accepting an unknown shape as an empty list would silently inherit MCPs.
  names_json="$(jq -ce '
    if type != "array" then error("expected a top-level array") else
      [ .[] | if type == "object" and (.name | type) == "string" and (.name | length) > 0
               then .name else error("server record is missing a string name") end ]
    end
  ' <<<"$raw" 2>/dev/null)" || {
    err "codex: live MCP discovery returned an unsupported JSON schema"
    return 1
  }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # Codex's -c dotted-path parser accepts MCP slugs (including hyphens) but
    # interprets quoted path segments as a different, invalid config shape.
    # Reject anything outside that provider slug grammar rather than injecting
    # an untrusted path or silently leaving a server enabled.
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || {
      err "codex: MCP server name cannot be represented safely in a config override: $name"
      return 1
    }
    config="mcp_servers.${name}.enabled=false"
    args_json="$(jq -c --arg config "$config" '. + ["-c", $config]' <<<"$args_json")"
  done < <(jq -r '.[]' <<<"$names_json" | sort -u)
  jq -cn --argjson argv "$args_json" '{resolved:"none",warning:"",argv:$argv,env:{}}'
}

# Profiles and raw config can introduce servers that were absent from the live
# discovery snapshot. Under auto/none, refuse that unbounded combination rather
# than claiming an isolation boundary we cannot prove.
codex_mcp_validate_extra() {
  local requested="$1"; shift
  [[ "$requested" == "inherit" ]] && return 0
  local arg
  for arg in "$@"; do
    case "$arg" in
      -c|-c*|--config|--config=*|-p|-p*|--profile|--profile=*) return 1 ;;
    esac
  done
  return 0
}

# Load the policy for a newly launched Codex process. Auto/none must be
# re-discovered from the effective cwd every time because user/project config
# can change between spawn and a later headless resume.
codex_load_process_mcp_policy() {
  local lane="$1" cwd="$2" context="$3" requested
  requested="$(lane_get "$lane" mcp_requested)"
  if [[ "$requested" == "auto" || "$requested" == "none" ]]; then
    resolve_mcp_policy codex "$requested" "${cwd:-$PWD}" || {
      err "codex $context: MCP discovery failed; refusing to launch lane '$lane'"
      return 1
    }
    lane_set "$lane" mcp_resolved "$MCP_RESOLVED" mcp_warning "$MCP_WARNING" \
      mcp_argv "$MCP_ARGV_JSON" mcp_env "$MCP_ENV_JSON"
    mcp_policy_load_json "$MCP_ARGV_JSON" "$MCP_ENV_JSON" "lane '$lane'"
  else
    mcp_policy_load_lane "$lane"
  fi
}

# Preflight: codex on PATH + the model backend reachable (else turns hang).
codex_preflight() {
  command -v codex >/dev/null 2>&1 || { err "codex not found on PATH"; return 1; }
  billing_preflight_provider codex || return 1
  local url="$WASPFLOW_CODEX_BACKEND_HEALTH_URL"
  if [[ -n "$url" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      warn "curl not found; cannot verify Codex backend at $url (continuing)"
      return 0
    fi
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || echo 000)"
    if [[ "$code" != "200" ]]; then
      err "Codex model proxy not healthy ($url -> $code). Start the proxy Codex is configured to use,"
      err "  or unset WASPFLOW_CODEX_BACKEND_HEALTH_URL to skip this check when Codex talks to a model directly."
      return 1
    fi
  fi
  return 0
}

# Discover the session UUID + rollout file for a lane. Prefer the recorded value;
# otherwise locate marker-bearing Codex lanes by their lane marker. Cwd-only
# lookup is retained only for older lane state without markers; it is ambiguous
# when multiple Codex lanes share a repo.
codex_discover_session() {
  local lane="$1" recorded lane_cwd marker
  recorded="$(lane_get "$lane" session_id)"
  if [[ -n "$recorded" ]]; then echo "$recorded"; return 0; fi

  lane_cwd="$(lane_get "$lane" cwd)"
  [[ -n "$lane_cwd" ]] || { echo ""; return 0; }
  marker="$(lane_get "$lane" codex_marker)"

  if [[ -n "$marker" ]]; then
    local marker_match marker_sid
    marker_match="$(_codex_find_rollout_for_marker "$lane_cwd" "$marker" || true)"
    if [[ -n "$marker_match" ]]; then
      marker_sid="$(_codex_rollout_session_id "$marker_match")"
      if [[ -n "$marker_sid" ]]; then
        echo "$marker_sid"
        return 0
      fi
    fi
    echo ""
    return 0
  fi

  # Legacy fallback for lanes spawned before codex_marker existed.
  local match sid
  match="$(_codex_find_rollout_for_cwd "$lane_cwd" || true)"
  [[ -n "$match" ]] || { echo ""; return 0; }
  sid="$(_codex_rollout_session_id "$match")"
  if [[ -n "$sid" ]]; then
    echo "$sid"
  else
    echo ""
  fi
}

# Spawn an interactive codex into the lane's tmux window (real PTY).
# Args: lane cwd model session_id(unused; codex mints its own) transcript prompt [extra...]
codex_spawn() {
  local lane="$1" cwd="$2" model="$3" _session_id="$4" transcript="$5" prompt="$6"
  shift 6
  local extra=("$@")
  local marker
  marker="WASPFLOW_LANE_MARKER:${lane}:$(new_uuid)"
  lane_set "$lane" codex_marker "$marker"

  # Pre-trust the cwd by ensuring it's a git repo (codex trusts repos it can read).
  # We do NOT modify a real project repo — only git-init if the dir isn't a repo yet.
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$cwd" init -q 2>/dev/null || true
  fi

  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  codex_load_process_mcp_policy "$lane" "$cwd" spawn || return 1
  # Pass model_reasoning_effort through exactly. Codex supports
  # minimal|low|medium|high|xhigh (OpenAI config reference). Never silently
  # demote xhigh→high. 'max' is not a Codex value — hard fail (use xhigh).
  local effort_args=() effort passed_effort
  effort="$(lane_get "$lane" effort)"
  case "$effort" in
    "" ) ;;
    minimal|low|medium|high|xhigh)
      effort_args=(-c "model_reasoning_effort=${effort}")
      passed_effort="$effort"
      ;;
    max)
      die "codex: effort 'max' is not a Codex model_reasoning_effort value (use xhigh). Never silently remapped."
      ;;
    *)
      die "codex: unsupported effort '$effort' (valid: minimal|low|medium|high|xhigh)"
      ;;
  esac
  # requested vs passed (org-side caps may still alter observed effort later)
  local requested_effort="$effort"
  [[ -n "$requested_effort" ]] && lane_set "$lane" effort_requested "$requested_effort"
  [[ -n "${passed_effort:-}" ]] && lane_set "$lane" effort_passed "$passed_effort"

  # Wrap with tokensmash launch for study actuation when available.
  local ts_prefix=()
  command -v tokensmash >/dev/null 2>&1 && ts_prefix=(tokensmash launch codex --)

  # Bare interactive codex (NO --skip-git-repo-check — that's exec-only).
  # Resolved policy comes last so pass-through --arg values cannot turn a
  # disabled server back on after the isolation boundary was established.
  local argv=("${ts_prefix[@]}" codex "${model_args[@]}" "${effort_args[@]}" "${extra[@]}" "${MCP_ARGV[@]}")
  local quoted=""
  local a
  for a in "${argv[@]}"; do quoted+=" $(printf '%q' "$a")"; done

  local target
  target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc $(printf '%q' "${quoted# }")")" \
    || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true

  # Drive the TUI deterministically. The startup is racy (trust prompt, hook
  # output, "model: loading"), so we synchronize on observable pane state at each
  # step instead of fixed sleeps, then VERIFY submission by waiting for a rollout
  # file to appear for THIS cwd — re-sending Enter if it didn't take.
  _codex_clear_trust_prompt "$target"
  _codex_wait_composer_ready "$target"
  _codex_submit_prompt "$lane" "$cwd" "$target" "$prompt" "$marker"
}

# A pane snapshot, de-escaped, for state checks.
_codex_pane() { tmux capture-pane -p -t "$1" -S -60 2>/dev/null | strip_ansi; }

# Clear the "Do you trust this directory?" prompt if/when it appears. We poll up
# to ~20s; the prompt may appear a beat after launch. Selecting "1" + Enter =
# "Yes, continue". If it never appears (already-trusted dir), this is a no-op.
_codex_clear_trust_prompt() {
  local target="$1" i pane
  for i in $(seq 1 20); do
    pane="$(_codex_pane "$target")"
    if grep -qi "Do you trust" <<<"$pane"; then
      tmux send-keys -t "$target" "1"
      sleep 1
      tmux send-keys -t "$target" Enter
      # Wait for the prompt to actually clear before returning.
      local j
      for j in $(seq 1 10); do
        grep -qi "Do you trust" <<<"$(_codex_pane "$target")" || return 0
        sleep 1
      done
      return 0
    fi
    # If the composer is already up (no trust prompt), nothing to clear.
    grep -qiE "OpenAI Codex|/model to change" <<<"$pane" && return 0
    sleep 1
  done
  return 0
}

# Wait until the composer is genuinely ready: the model line shows a model (not
# "loading") and the trust prompt is gone. Best-effort with a cap.
_codex_wait_composer_ready() {
  local target="$1" i pane
  for i in $(seq 1 30); do
    pane="$(_codex_pane "$target")"
    if ! grep -qi "Do you trust" <<<"$pane" \
       && grep -qiE "model: *gpt-|gpt-[0-9].* (medium|low|high|default) " <<<"$pane"; then
      return 0
    fi
    sleep 1
  done
  return 0  # proceed regardless; the submit step verifies real success
}

# Type the prompt and submit, then VERIFY by polling for a rollout file whose
# session_meta.cwd == our cwd. If none appears, re-send Enter (the most common
# failure is the Enter racing hook output). Up to a few attempts.
_codex_submit_prompt() {
  local lane="$1" cwd="$2" target="$3" prompt="$4" marker="${5:-}" attempt
  local full_prompt="$prompt"
  if [[ -n "$marker" ]]; then
    full_prompt="$marker
Ignore the line above; it is for waspflow session correlation.

$prompt"
  fi
  # Clear any starter text ("Implement {feature}") and paste literally. Plain
  # send-keys is brittle for long prompts: it can mangle spaces and queue text
  # as a follow-up instead of submitting the intended first turn.
  tmux send-keys -t "$target" C-u
  sleep 0.3
  tmux_paste_text "$target" "$full_prompt"
  sleep 1
  for attempt in 1 2 3 4 5; do
    tmux send-keys -t "$target" Enter
    # Give the turn a moment to start + write its session_meta line.
    local j
    for j in $(seq 1 6); do
      local rollout=""
      if [[ -n "$marker" ]]; then
        rollout="$(_codex_find_rollout_for_marker "$cwd" "$marker" || true)"
      else
        rollout="$(_codex_find_rollout_for_cwd "$cwd" || true)"
      fi
      if [[ -n "$rollout" ]]; then
        local sid
        sid="$(_codex_rollout_session_id "$rollout")"
        [[ -n "$sid" ]] && lane_set "$lane" session_id "$sid" rollout "$rollout"
        return 0
      fi
      sleep 1
    done
    warn "codex spawn: submit attempt $attempt did not start a turn for lane '$lane'; retrying Enter"
  done
  warn "codex spawn: prompt may not have submitted for lane '$lane' (no rollout for $cwd). Inspect: waspflow attach $lane"
  # Real failure signal: no rollout appeared after 5 Enter attempts, so the task
  # was NOT confirmed submitted (dead-on-arrival). Return nonzero so cmd_spawn
  # surfaces it loudly + exits 3, instead of a phantom "spawned" (parity with claude).
  return 1
}

# Extract Codex's session id from a rollout path.
_codex_rollout_session_id() {
  local rollout="$1" sid
  sid="$(head -1 "$rollout" 2>/dev/null | jq -rc '.payload.id // .payload.session_id // empty' 2>/dev/null)"
  [[ -n "$sid" ]] || sid="$(basename "$rollout" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  echo "$sid"
}

# Echo the rollout file path whose cwd and lane marker match. This is the
# authoritative selector for new Codex lanes; cwd alone is ambiguous when several
# lanes run in the same repo.
_codex_find_rollout_for_marker() {
  local cwd="$1" marker="$2" f fcwd
  [[ -n "$marker" ]] || return 1
  local listing; listing="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -printf '%f\t%p\n' 2>/dev/null | sort -rn | cut -f2-)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fcwd="$(head -1 "$f" 2>/dev/null | jq -rc 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null)"
    [[ "$fcwd" == "$cwd" ]] || continue
    grep -Fq "$marker" "$f" 2>/dev/null || continue
    echo "$f"
    return 0
  done <<<"$listing"
  return 1
}

# Echo the rollout file path whose session_meta.cwd == $1, newest-first by
# filename (session start time). Non-zero if none. Reads only line 1 per file.
_codex_find_rollout_for_cwd() {
  local cwd="$1" f fcwd
  # Materialize the candidate list first so an early `return` doesn't SIGPIPE the
  # find|sort|cut producer (which prints harmless "broken pipe" to stderr).
  local listing; listing="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -printf '%f\t%p\n' 2>/dev/null | sort -rn | cut -f2-)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fcwd="$(head -1 "$f" 2>/dev/null | jq -rc 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null)"
    if [[ "$fcwd" == "$cwd" ]]; then echo "$f"; return 0; fi
  done <<<"$listing"
  return 1
}

# Is the session resumable yet? For Codex the rollout file is written eagerly, so
# once we can discover the session it is resumable. Args: lane
codex_session_resumable() {
  local lane="$1" sid
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]]
}

# IDLE predicate: last rollout event is task_complete.
# Args: lane
codex_is_idle() {
  local lane="$1" sid rollout last
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || return 1
  rollout="$(lane_get "$lane" rollout)"
  if [[ -z "$rollout" || ! -f "$rollout" ]]; then
    rollout="$(find "$CODEX_SESSIONS_DIR" -type f -name "*${sid}.jsonl" 2>/dev/null | head -1)"
  fi
  [[ -n "$rollout" && -f "$rollout" ]] || return 1
  last="$(tail -1 "$rollout" 2>/dev/null \
          | jq -rc '(.payload.type // .type) // empty' 2>/dev/null)"
  [[ "$last" == "task_complete" ]]
}

# turn_mark: count of COMPLETED turns (task_complete events) in the rollout. Like
# claude's, this advances ONLY when a turn finishes — not on the submitted user
# message — so the wait barrier clears exactly when the revised turn completes.
codex_turn_mark() {
  local lane="$1" sid rollout
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || { echo 0; return 0; }
  rollout="$(lane_get "$lane" rollout)"
  if [[ -z "$rollout" || ! -f "$rollout" ]]; then
    rollout="$(find "$CODEX_SESSIONS_DIR" -type f -name "*${sid}.jsonl" 2>/dev/null | head -1)"
  fi
  [[ -n "$rollout" && -f "$rollout" ]] || { echo 0; return 0; }
  jq -rc 'select((.payload.type // .type) == "task_complete") | 1' "$rollout" 2>/dev/null | wc -l
}

# Revise. If the tmux window is live, steer in-pane via paste-buffer; otherwise
# resume headlessly via `codex exec resume <SID> "<msg>" -o <FILE>`.
# Args: lane message out_file
codex_revise() {
  local lane="$1" message="$2" out_file="${3:-}"
  local sid cwd model
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || { err "no session_id for lane '$lane' (has it run a turn yet?)"; return 1; }
  cwd="$(lane_get "$lane" cwd)"
  model="$(lane_get "$lane" model)"

  # Billing notice covers both the live-pane and headless-resume paths (parity
  # with claude_revise). For codex this is a soft notice, not a hard stop.
  billing_preflight_provider codex || return 1

  if tmux_window_exists "$lane"; then
    # Live in-pane steer. The Enter can race pane state, so VERIFY the turn
    # actually started by watching the rollout grow, re-sending Enter if not.
    local target rollout before after attempt j
    target="$(tmux_window_target "$lane")"
    rollout="$(lane_get "$lane" rollout)"
    [[ -n "$rollout" && -f "$rollout" ]] || rollout="$(_codex_find_rollout_for_cwd "$cwd" || true)"
    before="$(wc -l <"$rollout" 2>/dev/null || echo 0)"
    tmux send-keys -t "$target" C-u
    sleep 0.3
    tmux_paste_text "$target" "$message"
    sleep 1
    for attempt in 1 2 3 4 5; do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 6); do
        after="$(wc -l <"$rollout" 2>/dev/null || echo 0)"
        # A new turn appends a task_started + the user message; line count grows.
        [[ "$after" -gt "$before" ]] && return 0
        sleep 1
      done
      warn "codex revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    warn "codex revise: message may not have submitted for lane '$lane' (rollout did not grow)"
    return 0
  fi

  # Headless resumed turn. Run from the lane's cwd so any repo context resolves.
  # Grant workspace-write + non-interactive approvals explicitly so a resumed
  # turn can write files (e.g. a recovery report) regardless of the user's
  # default sandbox config — keeps behavior portable, not reliant on a permissive
  # global config.
  local model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  codex_load_process_mcp_policy "$lane" "$cwd" revise || return 1
  local tmp; tmp="${out_file:-$(mktemp)}"
  ( cd "${cwd:-$PWD}" && codex exec resume "$sid" "$message" "${model_args[@]}" \
      -c sandbox_mode=workspace-write -c approval_policy=never "${MCP_ARGV[@]}" -o "$tmp" ) \
    >/dev/null 2>&1
  if [[ -z "$out_file" ]]; then cat "$tmp"; rm -f "$tmp"; fi
  return 0
}
