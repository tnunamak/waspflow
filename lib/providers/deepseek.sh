#!/usr/bin/env bash
# deepseek.sh - waspflow adapter for DeepSeek Harness (`dsh` CLI).
#
# TESTED AGAINST: @deepseek-ai/dsh 0.1.0-rc.6 (developer preview, MIT,
# github.com/deepseek-ai/deepseek-harness).  v0.1 is explicitly pre-stable;
# re-probe `dsh --profile headless --help` and `dsh --profile headless
# --dump-config` before bumping.  NOTE: `pip install deepseek-harness` is an
# UNRELATED third-party project that also ships a `dsh` binary — only the npm
# @deepseek-ai/dsh package is supported here.
#
# PROBE PROVENANCE: every claim below was observed against the real rc.6 binary.
# Live API reachability was confirmed (a headless run produced a genuine HTTP
# 402 from api.deepseek.com), but the available credential had zero balance, so
# NO SUCCEEDING TURN was ever observed.  The success path — stdout carrying the
# assistant text, exit 0 — is derived from the runner source, not from a live
# green run.  The only live model ids are deepseek-v4-flash (the profile
# default) and deepseek-v4-pro; deepseek-chat / deepseek-reasoner are retired.
#
# ── The interface, as observed (not as wished for) ─────────────────────────
#
# The launcher parses only its own flags (-V/--version, --profile, --patch,
# --dump-config, --dump-default-config); the first unrecognized token begins
# the booted app's argv.  The headless app's ENTIRE option set is `-h`:
#
#   Usage: dsh --profile headless [options] [task...]
#     Arguments:  task        the task text; multiple words are joined by spaces
#     Options:    -h, --help  show this help
#
# There is therefore NO --model, NO --output-format, NO streaming JSON, NO
# session-id flag, NO --resume, and NO --yolo.  Passing any of them is a hard
# usage error ("error: unknown option '--model'").
#
# Stdout is the final assistant text plus one newline — plain text, never JSON.
# On failure the runner writes `dsh: <CODE>: <message>` to stderr and exits
# non-zero; exit 0 happens only when the turn's reason is `completed`.
#
# ── Model / effort selection ───────────────────────────────────────────────
#
# Selection is configuration, not argv.  Two seams exist and both were probed
# live against rc.6:
#
#   * `--patch <file>`: a YAML patch list re-configuring the `agent-default-model`
#     entry.  Verified to reach the real LLM route (the session log's
#     request/context showed the patched model).  Its schema is
#     z.object({provider, model}) ONLY — a `reasoningEffort` key survives into
#     --dump-config but is dropped before the request.  So --patch carries the
#     model and cannot carry effort.
#   * `$DSH_HOME/settings.yaml` section `agent-default-model`: accepts provider,
#     model AND reasoningEffort (verified: request header showed
#     reasoningEffort:max).  This is USER-OWNED global state, so the adapter
#     reads it but never writes it — a per-lane write would silently retarget
#     every other dsh process on the machine.
#
# The adapter uses --patch (per-lane, side-effect free).  Effort is therefore
# refused rather than silently ignored: see deepseek_validate_model_effort.
#
# ── Sessions ───────────────────────────────────────────────────────────────
#
# The headless runner mints `session-<randomUUID>` per invocation and NEVER
# reads an existing session (verified in @deepseek-ai/dsh-headless: it calls
# agents.create({sessionId: SessionId(`session-${randomUUID()}`)}) on every run).
# One-shot is the whole contract; conversational resume does not exist in v0.1.
#
# Sessions are nonetheless persisted, by @deepseek-ai/dsh-session-persistence-jsonl
# rooted at `$DSH_HOME/sessions` ($DSH_HOME defaults to ~/.dsh):
#
#   $DSH_HOME/sessions/--<lossily-encoded-cwd>--/session-<uuid>/session.jsonl[.zstd]
#
# The default compression is zstd.  The project-directory key is a LOSSY
# encoding (separator runs collapse, unsafe code units become ~XXXX, the whole
# key is truncated to 251 chars), so this adapter deliberately does NOT
# reimplement it — discovery scans the sessions root for a session directory
# newer than a spawn marker instead, which is encoding-independent.
#
# A session log is written even when the run fails (e.g. MISSING_CREDENTIAL),
# so the presence of a session proves invocation, never success.  Lifecycle
# truth lives in the waspflow-owned receipt JSONL; the dsh session log is used
# only for session-id discovery and runtime attestation.

DEEPSEEK_RECEIPTS_NAME="deepseek-receipts.jsonl"
DEEPSEEK_MARKER_NAME=".deepseek-spawn-marker"
DEEPSEEK_SID_NAME=".deepseek-sid"
DEEPSEEK_PATCH_NAME=".deepseek-model.patch.yml"

# The dsh harness home; $DSH_HOME wins, else ~/.dsh (verified: resolveDshHome).
_deepseek_home() { printf '%s\n' "${DSH_HOME:-$HOME/.dsh}"; }

# dsh ships no model-enumeration command and no on-disk catalog: the default
# catalog (deepseek-v4-flash, deepseek-v4-pro) is a JS constant inside
# @deepseek-ai/dsh-llm-deepseek, and a deployment may override it from the
# `llm-deepseek` settings section.  A user-authored catalog IS enumerable, so
# report it as local_cache; otherwise report non_enumerable rather than
# pretending the hardcoded pair is authoritative.
deepseek_valid_models() {
  local settings; settings="$(_deepseek_home)/settings.yaml"
  local models=""
  if [[ -f "$settings" ]] && command -v python3 >/dev/null 2>&1; then
    models="$(python3 - "$settings" <<'PY' 2>/dev/null || true
import sys
try:
    import yaml
except Exception:
    sys.exit(0)
try:
    with open(sys.argv[1]) as fh:
        doc = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)
section = doc.get("llm-deepseek") or {}
for model in (section.get("models") or []):
    if isinstance(model, dict) and model.get("id"):
        print(model["id"])
PY
)"
  fi
  if [[ -n "$models" ]]; then
    printf 'source=local_cache\n'
    printf '%s\n' "$models" | awk 'NF && !seen[$0]++'
    return 0
  fi
  printf 'source=non_enumerable\n'
}

# dsh v0.1 has no MCP-disable flag on the headless profile.  MCP servers are
# ordinary plugins in the profile tree, so "no MCP" would mean rewriting the
# user's profile — not a boundary this adapter can honestly assert.
deepseek_mcp_policy() {
  local requested="$1" cwd="${2:-$PWD}" state="absent" profile
  profile="$(_deepseek_home)/profiles/headless/cordis.patch.yml"
  if [[ -f "$profile" ]] && grep -q 'mcp' "$profile" 2>/dev/null; then state="present"; fi
  case "$requested" in
    inherit) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "dsh MCP configuration inherited from the headless profile patch layer." else "dsh MCP configuration inheritance is provider-controlled; no MCP entries found in the headless profile patch layer." end),argv:[],env:{}}' ;;
    auto) jq -cn --arg s "$state" '{resolved:"inherit",warning:(if $s == "present" then "dsh MCP auto resolves to inherit: MCP entries are configured in the headless profile." else "dsh MCP auto resolves to inherit: dsh v0.1 has no MCP-disable flag; MCP servers are profile plugins." end),argv:[],env:{}}' ;;
    none)
      err "deepseek: --mcp none is unsupported; dsh v0.1 has no MCP-disable flag (MCP servers are plugins in the profile tree). Refusing an unverified MCP boundary (config=$state)"
      return 1
      ;;
    *) return 1 ;;
  esac
}

deepseek_preflight() {
  command -v dsh >/dev/null 2>&1 || { err "dsh not found on PATH (install the DeepSeek Harness CLI: npm i -g @deepseek-ai/dsh)"; return 1; }
  # The headless profile is what waspflow drives; a dsh install without it
  # fails at boot with a profile-does-not-exist error, so check up front.
  [[ -d "$(_deepseek_home)/profiles/headless" ]] || {
    err "deepseek: the dsh 'headless' profile does not exist under $(_deepseek_home)/profiles (create it with: dsh plugin --profile headless add @deepseek-ai/dsh-headless)"
    return 1
  }
  billing_preflight_provider deepseek 2>/dev/null || true
  return 0
}

# Discover the dsh session ID for a lane.
#
# Three-tier fallback chain:
#   1. lane state   — written by the generated script on completion (primary)
#   2. .deepseek-sid — written by the generated script immediately after
#                      reading the session id off disk, BEFORE lane_set.
#                      Survives crashes between discovery and state persistence.
#   3. filesystem   — scans $DSH_HOME/sessions for exactly one session-*
#                      directory newer than the spawn marker.  Last resort;
#                      the marker bounds it, but a concurrent dsh run started
#                      in the same window would make it ambiguous (in which
#                      case it deliberately returns nothing rather than guess).
deepseek_discover_session() {
  local lane="$1" sid sid_file marker root candidates

  sid="$(lane_get "$lane" session_id)"
  [[ -n "$sid" ]] && { printf '%s\n' "$sid"; return 0; }

  sid_file="$(_deepseek_sid_file "$lane")"
  if [[ -s "$sid_file" ]]; then
    sid="$(cat "$sid_file")"
    if [[ -n "$sid" ]]; then
      lane_set "$lane" session_id "$sid"
      printf '%s\n' "$sid"
      return 0
    fi
  fi

  marker="$(lane_dir "$lane")/$DEEPSEEK_MARKER_NAME"
  [[ -f "$marker" ]] || return 0
  root="$(_deepseek_home)/sessions"
  [[ -d "$root" ]] || return 0

  # The project-key encoding is lossy, so scan by mtime rather than by path.
  candidates="$(find "$root" -mindepth 2 -maxdepth 2 -type d -name 'session-*' -newer "$marker" 2>/dev/null)"
  [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$candidates")" -eq 1 ]] || return 0
  sid="$(basename "$candidates")"
  lane_set "$lane" session_id "$sid"
  printf '%s\n' "$sid"
}

_deepseek_receipt_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$DEEPSEEK_RECEIPTS_NAME"; }
_deepseek_marker_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$DEEPSEEK_MARKER_NAME"; }
_deepseek_sid_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$DEEPSEEK_SID_NAME"; }
_deepseek_patch_file() { printf '%s/%s\n' "$(lane_dir "$1")" "$DEEPSEEK_PATCH_NAME"; }

_deepseek_receipt() {
  local lane="$1" phase="$2" outcome="$3" rc="$4" sid="$5" started="$6" finished="$7" prompt_kind="$8"
  local file; file="$(_deepseek_receipt_file "$lane")"
  mkdir -p "$(dirname "$file")"
  jq -cn --arg lane "$lane" --arg phase "$phase" --arg outcome "$outcome" --arg sid "$sid" \
    --arg kind "$prompt_kind" --argjson rc "${rc:-0}" --argjson started "${started:-0}" --argjson finished "${finished:-0}" \
    '{schema_version:1,provider:"deepseek",lane:$lane,phase:$phase,outcome:$outcome,session_id:($sid|if .=="" then null else . end),prompt_kind:$kind,exit_code:$rc,started_epoch:$started,completed_epoch:$finished}' \
    >>"$file"
}

# Locate a session's log file, tolerating either compression setting.
# Args: session-id.  Prints the path, or nothing.
_deepseek_session_log() {
  local sid="$1" root; root="$(_deepseek_home)/sessions"
  [[ -n "$sid" && -d "$root" ]] || return 0
  find "$root" -mindepth 3 -maxdepth 3 -type f -path "*/$sid/session.jsonl*" 2>/dev/null | head -1
}

# Stream a session log as plain JSONL regardless of compression.
_deepseek_session_lines() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  case "$log" in
    *.zstd) command -v zstdcat >/dev/null 2>&1 || return 1; zstdcat "$log" 2>/dev/null ;;
    *) cat "$log" ;;
  esac
}

# Write the per-lane --patch overlay that retargets `agent-default-model`.
# Emitting nothing (and printing no path) when no model is requested keeps the
# provider's own default authoritative.
_deepseek_write_model_patch() {
  local lane="$1" model="$2" file
  [[ -n "$model" ]] || return 0
  file="$(_deepseek_patch_file "$lane")"
  mkdir -p "$(dirname "$file")"
  # dsh reads this as a YAML patch list; the id targets the composed entry.
  {
    printf -- '- id: agent-default-model\n'
    printf -- '  config:\n'
    printf -- '    provider: %s\n' "${DEEPSEEK_PROVIDER_ROUTE:-deepseek-official}"
    printf -- '    model: %s\n' "$model"
  } >"$file"
  printf '%s\n' "$file"
}

# Build the shell script evaluated inside the lane-owned tmux process.
#
# The generated script:
#   1. sources core.sh + deepseek.sh for receipt/lane helpers
#   2. touches the spawn marker (discovery race boundary)
#   3. writes an invocation receipt
#   4. runs `dsh --profile headless [--patch <model>] -- <task>` tee'd to a log
#   5. checks PIPESTATUS for both dsh and tee
#   6. discovers the session ID from $DSH_HOME/sessions (marker-scoped)
#   7. writes a completion receipt with the correct outcome
#   8. persists the session ID to lane state
#   9. cleans up the log via an EXIT trap
#
# API keys are NEVER passed via argv; dsh reads DEEPSEEK_API_KEY from the
# inherited environment (which, per dsh-credentials-local, outranks its own
# managed store).
_deepseek_shell() {
  local lane="$1" model="$2" session_id="$3" prompt="$4" kind="$5"
  shift 5
  local extra=("$@")
  local log adapter core marker patch
  log="$(lane_dir "$lane")/.deepseek-log.$$"
  marker="$(_deepseek_marker_file "$lane")"
  adapter="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/providers/deepseek.sh"
  core="${WASPFLOW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/core.sh"

  # session_id is accepted for contract symmetry but cannot be honored: the
  # headless runner mints a fresh UUID per invocation.  Callers that need
  # continuation must refuse earlier (deepseek_revise does).
  patch="$(_deepseek_write_model_patch "$lane" "$model")"

  local argv=(dsh --profile headless)
  [[ -n "$patch" ]] && argv+=(--patch "$patch")
  # `--` ends launcher parsing so a task beginning with '-' reaches the app.
  argv+=(-- "$prompt")
  argv+=("${extra[@]}")
  local q a; q=""
  for a in "${argv[@]}"; do q+=" $(printf '%q' "$a")"; done

  printf 'source %q; source %q\n' "$core" "$adapter"
  cat <<'DEEPSEEK_SCRIPT'
cleanup_log=""
trap 'rm -f "$cleanup_log"' EXIT
started=$(date +%s)
DEEPSEEK_SCRIPT
  printf 'cleanup_log=%q\n' "$log"
  printf '_deepseek_receipt %q invocation started 0 "" "$started" "$started" %q\n' "$lane" "$kind"
  printf 'touch %q\n' "$marker"
  cat <<'DEEPSEEK_SCRIPT'
set +e
DEEPSEEK_SCRIPT
  printf '%s 2>&1 | tee %q\n' "${q# }" "$log"
  cat <<'DEEPSEEK_SCRIPT'
pipeline_rc=("${PIPESTATUS[@]}")
set -e
rc=${pipeline_rc[0]}
tee_rc=${pipeline_rc[1]}
DEEPSEEK_SCRIPT
  # Session discovery is filesystem-only: dsh prints no session id on stdout.
  printf 'sid=$(deepseek_discover_session %q 2>/dev/null || true)\n' "$lane"
  cat <<'DEEPSEEK_SCRIPT'
outcome=failed
if [[ "$rc" -eq 0 && "$tee_rc" -ne 0 ]]; then
  rc="$tee_rc"
elif [[ "$rc" -eq 0 && -z "$sid" ]]; then
  rc=1; outcome=no_session
elif [[ "$rc" -eq 0 ]]; then
  outcome=succeeded
fi
finished=$(date +%s)
DEEPSEEK_SCRIPT
  printf '_deepseek_receipt %q completion "$outcome" "$rc" "$sid" "$started" "$finished" %q\n' "$lane" "$kind"
  printf 'if [[ -n "$sid" ]]; then printf "%%s" "$sid" > %q; fi\n' "$(_deepseek_sid_file "$lane")"
  printf 'if [[ -n "$sid" ]]; then lane_set %q session_id "$sid"; fi\n' "$lane"
  printf 'exit "$rc"\n'
}

# dsh CAN take a reasoning effort, but only through $DSH_HOME/settings.yaml —
# global, user-owned state this adapter refuses to mutate per lane.  The
# per-lane --patch seam silently drops reasoningEffort (its schema is
# provider+model only), so honoring --effort here would be a lie.
deepseek_validate_model_effort() {
  local _model="${1:-}" effort="${2:-}"
  if [[ -n "$effort" ]]; then
    err "deepseek: --effort is unsupported; dsh v0.1 exposes reasoning effort only via the global \$DSH_HOME/settings.yaml 'agent-default-model' section, which waspflow will not rewrite per lane"
    return 1
  fi
}

deepseek_spawn() {
  local lane="$1" cwd="$2" model="$3" _provided_sid="$4" transcript="$5" prompt="$6"; shift 6
  local receipt_file i owned attempts
  receipt_file="$(_deepseek_receipt_file "$lane")"
  : >"$receipt_file"
  deepseek_validate_model_effort "$model" "$(lane_get "$lane" effort)" || return 1
  local cmd; cmd="$(_deepseek_shell "$lane" "$model" "" "$prompt" spawn "$@")"
  local target; target="$(tmux_create_owned_lane_window "$lane" "$cwd" "bash -lc $(printf '%q' "$cmd")")" || return 1
  tmux pipe-pane -t "$target" -o "cat >> $(printf '%q' "$transcript")" 2>/dev/null || true
  attempts="${WASPFLOW_SUBMIT_ATTEMPTS:-20}"
  for i in $(seq 1 "$attempts"); do
    if [[ -s "$receipt_file" ]] && jq -e 'select(.phase == "invocation" and .prompt_kind == "spawn" and .outcome == "started")' "$receipt_file" >/dev/null 2>&1; then
      return 0
    fi
    owned=false
    tmux_owned_lane_window_exists "$lane" >/dev/null 2>&1 && owned=true
    [[ "$owned" == true ]] || break
    sleep 1
  done
  err "deepseek spawn: submission receipt did not appear for lane '$lane'"
  return 1
}

# A dsh session is never resumable: the headless runner mints a fresh session
# per invocation and offers no way to attach to an existing one.  Reporting
# "resumable" for a session that exists on disk would be false — the next turn
# would start from an empty context while claiming continuity.
deepseek_session_resumable() { return 1; }

deepseek_is_idle() {
  local lane="$1" file; file="$(_deepseek_receipt_file "$lane")"
  [[ -s "$file" ]] || return 1
  [[ "$(tail -n 1 "$file" | jq -r 'select(.phase=="completion") | .outcome' 2>/dev/null)" =~ ^(succeeded|failed|no_session)$ ]]
}

deepseek_turn_mark() { local f; f="$(_deepseek_receipt_file "$1")"; jq -r 'select(.phase=="completion" and .outcome=="succeeded") | 1' "$f" 2>/dev/null | wc -l; }

# Mid-run revision needs conversational continuity, which v0.1 cannot provide:
# every `dsh --profile headless` invocation is a brand-new session with an
# empty context.  Sending the follow-up anyway would produce a confident
# answer to a question the agent has no context for — the worst failure mode.
deepseek_revise() {
  err "deepseek: revise is unsupported by DeepSeek Harness v0.1; the headless profile mints a fresh session per invocation (no --resume, no session-id flag), so a follow-up would run with no prior context. Spawn a new lane with the full task instead."
  return 1
}

# dsh cannot accept a caller-minted session ID, so it cannot participate in the
# escalation state machine's provisional ownership protocol.
deepseek_resume_with_arm() { err "deepseek: escalation hooks are unsupported by DeepSeek Harness"; return 1; }
deepseek_confirm_escalation_submission() { err "deepseek: escalation confirmation is unsupported by DeepSeek Harness"; return 1; }

# Read the model actually used from the session log's request/context event —
# dsh's own record of the route it dialed, so this is real attestation rather
# than an echo of what we asked for.  Guard large logs with timeout.
deepseek_refresh_runtime_settings() {
  local lane="$1" sid log observed_model
  sid="$(deepseek_discover_session "$lane")"
  [[ -n "$sid" ]] || return 0
  log="$(_deepseek_session_log "$sid")"
  [[ -n "$log" ]] || return 0
  observed_model="$(_deepseek_session_lines "$log" 2>/dev/null \
    | timeout 5 jq -r 'select(.type=="request/context") | .data.model // empty' 2>/dev/null | tail -1)" || return 0
  [[ -n "$observed_model" ]] || return 0
  lane_set "$lane" runtime_model "$observed_model"
}
