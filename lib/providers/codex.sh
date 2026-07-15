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
    [[ -n "$out" ]] && { printf 'source=live_query\n%s\n' "$out"; return 0; }
  fi
  [[ -r "$CODEX_MODELS_CACHE" ]] || { printf 'source=none\n'; return 0; }
  out="$(jq -r '.models[].slug // empty' "$CODEX_MODELS_CACHE" 2>/dev/null)"
  [[ -n "$out" ]] || { printf 'source=none\n'; return 0; }
  printf 'source=local_cache\n%s\n' "$out"
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

# Discover the session UUID for a lane. Prefer the recorded value; otherwise
# locate the lane's rollout by its unique spawn-time marker. A READ-ONLY
# ORACLE: never mutates lane state (no lane_set here) — callers that want the
# resolved rollout path cached (e.g. after a successful spawn) record it
# themselves; discovery itself must be safe to call from any read path (wait,
# park's safety predicate, gc's dry-run scan) without a side effect.
#
# FAILS CLOSED when no marker is recorded: a cwd-only match is AMBIGUOUS
# whenever more than one Codex lane (past or present) has ever run in that
# directory, and silently attaching to the wrong rollout is worse than
# reporting "not found" — it mixes a stale/unrelated session's history into
# this lane (wrong turns read as this lane's, a `revise`/recovery/park
# resuming a COMPLETELY DIFFERENT conversation). codex_spawn always records a
# marker before submitting, so an empty marker on a live codex lane is itself
# anomalous (a bug or manually-crafted state) — never a normal case to paper
# over with a guess. Real-world incident (2026-07-11): several concurrent
# same-cwd lanes were each mis-attached to one unrelated ~5-week-old rollout via
# a cwd-only fallback this replaced, mixing prompts and turn histories across
# lanes and later causing a connection-refused/dead lane to read as "idle" and
# get "recovered" against someone else's session.
codex_discover_session() {
  local lane="$1" recorded lane_cwd marker
  recorded="$(lane_get "$lane" session_id)"
  if [[ -n "$recorded" ]]; then echo "$recorded"; return 0; fi

  lane_cwd="$(lane_get "$lane" cwd)"
  [[ -n "$lane_cwd" ]] || { echo ""; return 0; }
  marker="$(lane_get "$lane" codex_marker)"
  [[ -n "$marker" ]] || { echo ""; return 0; }

  local marker_match marker_sid
  marker_match="$(_codex_find_rollout_for_marker "$lane_cwd" "$marker" || true)"
  if [[ -n "$marker_match" ]]; then
    marker_sid="$(_codex_rollout_session_id "$marker_match")"
    [[ -n "$marker_sid" ]] && { echo "$marker_sid"; return 0; }
  fi
  echo ""
  return 0
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

  # Wrap with tokensmash launch for study actuation ONLY when the crossover
  # study is live. While the study mode is off, wrapping is a pure no-op that
  # still spawns a ~0.4s tokensmash process per spawn, so we skip it. Re-enable
  # by setting the tokensmash study back to live (no change needed here).
  local ts_prefix=()
  local ts_study_config="${TOKENSMASH_STUDY_CONFIG:-$HOME/.local/state/tokensmash/study/config.json}"
  if command -v tokensmash >/dev/null 2>&1 \
     && [[ -f "$ts_study_config" ]] \
     && grep -q '"mode"[[:space:]]*:[[:space:]]*"live"' "$ts_study_config" 2>/dev/null; then
    ts_prefix=(tokensmash launch codex --)
  fi

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

# Type the prompt and submit, then verify that one rollout for this cwd contains
# the exact full user message. A marker-only event proves only that correlation
# text arrived; it can coexist with the real task still queued in the composer.
# If no complete message appears, re-send Enter (the most common failure is the
# Enter racing hook output). Up to a few attempts.
_codex_submit_prompt() {
  local lane="$1" cwd="$2" target="$3" prompt="$4" marker="${5:-}" attempt
  # A marker is REQUIRED to confirm submission safely: codex_spawn always sets
  # one before calling here. Without it, the only way to find "our" rollout is
  # cwd alone, which is AMBIGUOUS — any other lane (or a stale rollout from
  # weeks ago) in the same directory would match just as well, mis-attaching
  # this lane to someone else's session. Fail closed instead of guessing.
  [[ -n "$marker" ]] || { err "codex spawn: internal error — no marker for lane '$lane' (refusing an ambiguous cwd-only submission check)"; return 1; }
  local full_prompt="$marker
Ignore the line above; it is for waspflow session correlation.

$prompt"
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
      rollout="$(_codex_find_rollout_for_submitted_prompt "$cwd" "$full_prompt" || true)"
      if [[ -n "$rollout" ]]; then
        local sid
        sid="$(_codex_rollout_session_id "$rollout")"
        if [[ -n "$sid" ]]; then
          lane_set "$lane" session_id "$sid" rollout "$rollout"
          codex_refresh_runtime_settings "$lane"
        fi
        return 0
      fi
      sleep 1
    done
    warn "codex spawn: submit attempt $attempt did not start a turn for lane '$lane'; retrying Enter"
  done
  warn "codex spawn: prompt was not confirmed submitted for lane '$lane' (no rollout contains the complete task). Inspect: waspflow attach $lane"
  # Real failure signal: no exact full prompt appeared after 5 Enter attempts,
  # so the task was NOT confirmed submitted (dead-on-arrival). Return nonzero so
  # cmd_spawn surfaces it loudly + exits 3, instead of a phantom "spawned".
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
# ONLY selector for Codex lanes; cwd alone is ambiguous whenever more than one
# lane (past or present) has run in the same repo, so callers must never fall
# back to a cwd-only match (see codex_discover_session).
#
# Sort newest-first by FILENAME, lexically (plain `sort -r`), not `sort -rn`:
# these filenames (rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl) are not numeric, so
# `-n` parses no leading digits from any of them, treats every line as the
# value 0, and produces an order with no reliable relationship to session time.
# Lexical order on this zero-padded ISO-8601-like prefix sorts correctly.
# Newest-first only matters for early-exit performance here — correctness comes
# from the marker match (a fresh UUID per spawn), not from ordering.
_codex_find_rollout_for_marker() {
  local cwd="$1" marker="$2" f fcwd
  [[ -n "$marker" ]] || return 1
  local listing; listing="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -printf '%f\t%p\n' 2>/dev/null | sort -r | cut -f2-)"
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

# Echo the newest rollout in cwd containing the exact initial user message.
# This is intentionally separate from marker lookup: marker-only lookup remains
# the durable session-discovery key, while spawn receipt requires evidence that
# the complete task crossed the tmux/Codex boundary. Args: cwd full_prompt
_codex_find_rollout_for_submitted_prompt() {
  local cwd="$1" full_prompt="$2" f fcwd
  local listing; listing="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -printf '%f\t%p\n' 2>/dev/null | sort -r | cut -f2-)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fcwd="$(head -1 "$f" 2>/dev/null | jq -rc 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null)"
    [[ "$fcwd" == "$cwd" ]] || continue
    jq -e --arg full_prompt "$full_prompt" \
      'select((.payload.type // .type) == "user_message" and (.payload.message // "") == $full_prompt)' \
      "$f" >/dev/null 2>&1 || continue
    echo "$f"
    return 0
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

# Refresh the runtime-settings receipt from the rollout that belongs to THIS
# session. This deliberately reads only typed configuration events: it never
# inspects the TUI, user messages, prompts, or assistant transcript content.
# `thread_settings_applied` is authoritative when present; otherwise the latest
# `turn_context` is the best available observation. Missing/malformed logs stay
# honest rather than turning the launch request into claimed runtime truth.
codex_refresh_runtime_settings() {
  local lane="$1" sid rollout snapshot snapshot_size last_byte line parsed source observed_at runtime_model runtime_effort
  local line_number=0 last_line=0 malformed="" in_flight=0
  _codex_runtime_refresh_health() {
    lane_set "$lane" runtime_refresh_state "$1" runtime_refresh_error "${2:-}" runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || {
    _codex_runtime_refresh_health unknown no-session
    return 0
  }
  rollout="$(lane_get "$lane" rollout)"
  if [[ -z "$rollout" || ! -f "$rollout" ]]; then
    rollout="$(find "$CODEX_SESSIONS_DIR" -type f -name "*${sid}.jsonl" 2>/dev/null | head -1)"
  fi
  [[ -n "$rollout" && -f "$rollout" ]] || {
    _codex_runtime_refresh_health unknown missing-rollout
    return 0
  }

  # Codex writes append-only JSONL. Freeze the byte length first, then copy only
  # that prefix: later appends cannot change this snapshot's earlier records.
  snapshot_size="$(wc -c <"$rollout" 2>/dev/null || echo '')"
  [[ "$snapshot_size" =~ ^[0-9]+$ ]] || { _codex_runtime_refresh_health error snapshot-stat-failed; return 0; }
  snapshot="$(mktemp "$(lane_dir "$lane")/.runtime-rollout.XXXXXX")" || { _codex_runtime_refresh_health error snapshot-create-failed; return 0; }
  head -c "$snapshot_size" "$rollout" >"$snapshot" 2>/dev/null || { rm -f "$snapshot"; _codex_runtime_refresh_health error snapshot-read-failed; return 0; }
  [[ "$(wc -c <"$snapshot" 2>/dev/null || echo -1)" == "$snapshot_size" ]] || { rm -f "$snapshot"; _codex_runtime_refresh_health in_flight snapshot-short-read; return 0; }
  last_byte="$(tail -c 1 "$snapshot" 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1)); last_line=$line_number
  done <"$snapshot"
  source=""; observed_at=""; runtime_model=""; runtime_effort=""
  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if ! parsed="$(jq -c . <<<"$line" 2>/dev/null)"; then
      if [[ "$line_number" == "$last_line" && "$last_byte" != 0a ]]; then in_flight=1; break; fi
      malformed="line-$line_number"; break
    fi
    if [[ "$(jq -r --arg sid "$sid" 'select(.type == "session_meta" and (.payload.id // "") == $sid) | 1' <<<"$parsed")" == 1 ]]; then
      : # exact session correlation established below from the same snapshot
    fi
    local event_source event_at event_model event_effort
    event_source="$(jq -r 'if .type == "turn_context" then "turn_context" elif .type == "event_msg" and .payload.type == "thread_settings_applied" then "thread_settings_applied" else empty end' <<<"$parsed")"
    [[ -n "$event_source" ]] || continue
    event_at="$(jq -r '.timestamp // ""' <<<"$parsed")"
    if [[ "$event_source" == turn_context ]]; then
      event_model="$(jq -r '.payload.model // ""' <<<"$parsed")"
      event_effort="$(jq -r '.payload.effort // .payload.reasoning_effort // ""' <<<"$parsed")"
    else
      event_model="$(jq -r '.payload.thread_settings.model // ""' <<<"$parsed")"
      event_effort="$(jq -r '.payload.thread_settings.reasoning_effort // .payload.thread_settings.effort // ""' <<<"$parsed")"
    fi
    if [[ "$event_source" == thread_settings_applied || "$source" != thread_settings_applied ]]; then
      source="$event_source"; observed_at="$event_at"; runtime_model="$event_model"; runtime_effort="$event_effort"
    fi
  done <"$snapshot"
  local meta
  meta="$(jq -Rrc --arg sid "$sid" 'fromjson? | select(.type == "session_meta" and (.payload.id // "") == $sid) | 1' "$snapshot" 2>/dev/null | tail -1)"
  rm -f "$snapshot"
  if [[ -n "$malformed" ]]; then _codex_runtime_refresh_health error "malformed-rollout:$malformed"; return 0; fi
  if [[ "$in_flight" -eq 1 ]]; then _codex_runtime_refresh_health in_flight incomplete-final-record; return 0; fi
  if [[ "$meta" != 1 ]]; then _codex_runtime_refresh_health unknown uncorrelated-rollout; return 0; fi
  if [[ -z "$source" || -z "$runtime_model" || -z "$runtime_effort" ]]; then
    _codex_runtime_refresh_health unknown no-settings-event
    return 0
  fi

  local requested_model requested_effort match prior_match prior_at prior_warned_at
  requested_model="$(lane_get "$lane" model_requested)"
  [[ -n "$requested_model" ]] || requested_model="$(lane_get "$lane" model)"
  requested_effort="$(lane_get "$lane" effort_requested)"
  [[ -n "$requested_effort" ]] || requested_effort="$(lane_get "$lane" effort)"
  if [[ -z "$requested_model" && -z "$requested_effort" ]]; then
    match=unknown
  elif { [[ -z "$requested_model" || "$requested_model" == "$runtime_model" ]]; } && \
       { [[ -z "$requested_effort" || "$requested_effort" == "$runtime_effort" ]]; }; then
    match=true
  else
    match=false
  fi
  prior_match="$(lane_get "$lane" runtime_settings_match_requested)"
  prior_at="$(lane_get "$lane" runtime_settings_observed_at)"
  prior_warned_at="$(lane_get "$lane" runtime_settings_warned_observed_at)"
  lane_set "$lane" rollout "$rollout" runtime_settings_state observed runtime_settings_error "" runtime_refresh_state observed runtime_refresh_error "" runtime_refresh_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    runtime_model "$runtime_model" runtime_effort "$runtime_effort" runtime_settings_source "$source" \
    runtime_settings_observed_at "$observed_at" runtime_settings_match_requested "$match"
  if [[ "$match" == false && "$prior_warned_at" != "$observed_at" ]]; then
    lane_set "$lane" runtime_settings_warned_observed_at "$observed_at"
    warn "codex runtime settings drift for lane '$lane': requested ${requested_model:-default}/${requested_effort:-default}, observed $runtime_model/$runtime_effort ($source)"
  fi
  return 0
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

# Count started Codex turns in one rollout. A queued user_message is intentionally
# not a receipt: only task_started proves Codex left the composer for that turn.
_codex_task_started_mark() {
  local rollout="$1"
  [[ -f "$rollout" ]] || { echo 0; return 0; }
  jq -rc 'select((.payload.type // .type) == "task_started") | 1' "$rollout" 2>/dev/null | wc -l
}

# Normalize an existing directory without resolving a report filename. This is
# the capability boundary for external recovery reports: the command line must
# receive a physical directory, never a lexical path that can contain `..`.
_codex_normalize_directory() {
  local directory="$1"
  (cd -P "$directory" && pwd -P)
}

# Revise. If the tmux window is live, steer in-pane via paste-buffer; otherwise
# resume headlessly via `codex exec resume <SID> "<msg>" -o <FILE>`. The optional
# fourth argument is a normalized report-parent capability for recovery only.
# Ordinary revisions never supply it and retain workspace-only access.
# Args: lane message out_file [recovery_report_parent]
codex_revise() {
  local lane="$1" message="$2" out_file="${3:-}" recovery_report_parent="${4:-}"
  local sid cwd model
  # A live revise starts unconfirmed before any discovery or billing preflight.
  # Those early failures must never leave a prior turn's confirmed receipt in
  # state, and must not disturb cmd_wait's completed-turn barrier.
  if tmux_window_exists "$lane"; then
    lane_set "$lane" revise_submitted false \
      revise_submission_state unconfirmed-pending \
      revise_submission_error pending revise_task_started_mark ""
  fi
  sid="$(codex_discover_session "$lane")"
  [[ -n "$sid" ]] || {
    if tmux_window_exists "$lane"; then
      lane_set "$lane" revise_submission_state unconfirmed-no-session revise_submission_error no-session
    fi
    err "no session_id for lane '$lane' (has it run a turn yet?)"
    return 1
  }
  cwd="$(lane_get "$lane" cwd)"
  model="$(lane_get "$lane" model)"

  # Billing notice covers both the live-pane and headless-resume paths (parity
  # with claude_revise). For codex this is a soft notice, not a hard stop.
  billing_preflight_provider codex || return 1

  if tmux_window_exists "$lane"; then
    # Live in-pane steer. The Enter can race pane state, so verify a NEW
    # task_started event, not merely rollout growth: a user_message can remain
    # queued in Codex's composer without a task having started.
    local target rollout before after attempt j attempts polls
    target="$(tmux_window_target "$lane")"
    # codex_discover_session is a read-only oracle (no lane_set side effect), so
    # `rollout` may not be cached in lane state. Resolve it the same safe way
    # codex_is_idle/codex_turn_mark do: the cached path if present, else a
    # find scoped by the unique session UUID — NEVER an ambiguous cwd-only
    # search (same hazard class as the discovery path itself).
    rollout="$(lane_get "$lane" rollout)"
    if [[ -z "$rollout" || ! -f "$rollout" ]]; then
      rollout="$(find "$CODEX_SESSIONS_DIR" -type f -name "*${sid}.jsonl" 2>/dev/null | head -1)"
    fi
    [[ -n "$rollout" && -f "$rollout" ]] || {
      lane_set "$lane" revise_submitted false \
        revise_submission_state unconfirmed-missing-rollout \
        revise_submission_error missing-rollout revise_task_started_mark ""
      err "codex revise: lane '$lane' has a session_id but no resolved rollout file (inconsistent state)"
      return 1
    }
    before="$(_codex_task_started_mark "$rollout")"
    tmux send-keys -t "$target" C-u
    sleep 0.3
    tmux_paste_text "$target" "$message"
    sleep 1
    # These bounded defaults are production behavior. The env seams only let
    # deterministic tests exercise every receipt outcome without waiting.
    attempts="${WASPFLOW_CODEX_REVISE_ATTEMPTS:-5}"
    polls="${WASPFLOW_CODEX_REVISE_POLLS:-6}"
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=5
    [[ "$polls" =~ ^[1-9][0-9]*$ ]] || polls=6
    for attempt in $(seq 1 "$attempts"); do
      tmux send-keys -t "$target" Enter
      for j in $(seq 1 "$polls"); do
        after="$(_codex_task_started_mark "$rollout")"
        if [[ "$after" -gt "$before" ]]; then
          lane_set "$lane" revise_submitted true \
            revise_submission_state confirmed-task-started \
            revise_submission_error "" revise_task_started_mark "$after"
          codex_refresh_runtime_settings "$lane"
          return 0
        fi
        sleep 1
      done
      warn "codex revise: steer attempt $attempt didn't start a turn for lane '$lane'; retrying Enter"
    done
    lane_set "$lane" revise_submitted false \
      revise_submission_state unconfirmed-no-task-started \
      revise_submission_error no-task-started revise_task_started_mark "$before"
    # Keep the caller's completed-turn barrier intact. A human can still submit
    # the pasted message later, and wait must not mistake the prior idle for it.
    warn "codex revise: message was not confirmed submitted for lane '$lane' (no new task_started event)"
    return 1
  fi

  # Headless resumed turn. Run from the lane's cwd so any repo context resolves.
  # Grant workspace-write + non-interactive approvals explicitly so a resumed
  # turn can write files inside its workspace regardless of the user's default
  # sandbox config. Recovery may additionally write its one required external
  # report directory; ordinary revise calls have no such capability.
  local model_args=() effort_args=() effort
  [[ -n "$model" ]] && model_args=(-m "$model")
  effort="$(lane_get "$lane" effort_passed)"
  [[ -n "$effort" ]] || effort="$(lane_get "$lane" effort_requested)"
  case "$effort" in
    "") ;;
    minimal|low|medium|high|xhigh) effort_args=(-c "model_reasoning_effort=${effort}") ;;
    *) err "codex revise: stored effort '$effort' cannot be reasserted honestly"; return 1 ;;
  esac
  codex_load_process_mcp_policy "$lane" "$cwd" revise || return 1
  local recovery_report_dir="" normalized_cwd
  local -a recovery_dir_args=()
  if [[ -n "$recovery_report_parent" ]]; then
    recovery_report_dir="$(_codex_normalize_directory "$recovery_report_parent")" || {
      err "codex revise: recovery report parent is not an accessible directory: $recovery_report_parent"
      return 1
    }
    [[ "$recovery_report_parent" == "$recovery_report_dir" ]] || {
      err "codex revise: recovery report parent must be normalized: $recovery_report_parent"
      return 1
    }
    normalized_cwd="$(_codex_normalize_directory "$cwd")" || {
      err "codex revise: lane '$lane' has an inaccessible working directory: $cwd"
      return 1
    }
    if [[ "$recovery_report_dir" != "$normalized_cwd" && "$recovery_report_dir" != "$normalized_cwd/"* ]]; then
      recovery_dir_args=(--add-dir "$recovery_report_dir")
    fi
  fi
  local tmp; tmp="${out_file:-$(mktemp)}"
  tmux_run_owned_lane_command "$lane" "${cwd:-$PWD}" headless-revise -- \
    codex exec "${recovery_dir_args[@]}" resume "$sid" "$message" "${model_args[@]}" "${effort_args[@]}" \
    -c sandbox_mode=workspace-write -c approval_policy=never "${MCP_ARGV[@]}" -o "$tmp" \
    >/dev/null 2>&1
  codex_refresh_runtime_settings "$lane"
  if [[ -z "$out_file" ]]; then cat "$tmp"; rm -f "$tmp"; fi
  return 0
}
