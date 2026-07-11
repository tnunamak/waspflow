#!/usr/bin/env bash
#
# exec.sh - stateless headless provider execution.
#
# Unlike spawn/revise, this intentionally does not create a lane, worktree,
# tmux window, transcript, or reap contract. It is a blocking subprocess helper
# for one-off analysis/transform prompts.

set -euo pipefail

exec_run() {
  local provider="" model="" effort="" mcp="auto" cwd="$PWD" out_file=""
  split_after_ddash "$@"
  set -- "${FLAGS[@]:-}"
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --provider)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --provider requires a value"
        provider="$2"; shift 2
        ;;
      --model)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --model requires a value"
        model="$2"; shift 2
        ;;
      --effort)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --effort requires a value"
        effort="$2"; shift 2
        ;;
      --mcp)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --mcp requires auto, none, or inherit"
        mcp="$2"; shift 2
        ;;
      --cwd)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --cwd requires a value"
        cwd="$2"; shift 2
        ;;
      -o)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: -o requires a file"
        out_file="$2"; shift 2
        ;;
      "")         shift ;;
      *)          die "exec: unknown option '$1'" ;;
    esac
  done
  local prompt="${REST[*]:-}"

  [[ -n "$provider" ]] || die "exec: --provider is required (claude|codex|grok)"
  is_known_provider "$provider" || die "exec: unknown provider '$provider'"
  [[ -n "$prompt" ]] || die "exec: a task prompt is required after '--'"
  cwd="$(cd "$cwd" && pwd)" || die "exec: --cwd does not exist"
  guard_cwd "$cwd"   # never run a worker with cwd '/' silently (known crash class)
  if [[ -n "$effort" && ! "$effort" =~ ^(none|minimal|low|medium|high|xhigh|max)$ ]]; then
    die "exec: --effort must be one of none|minimal|low|medium|high|xhigh|max (got: $effort)"
  fi

  load_provider "$provider"
  validate_model "$provider" "$model" exec
  resolve_mcp_policy "$provider" "$mcp" "$cwd" \
    || die "$provider: cannot resolve MCP policy '$mcp'"
  "${provider}_preflight" || die "exec aborted: $provider preflight failed"
  mcp_policy_load_json "$MCP_ARGV_JSON" "$MCP_ENV_JSON" "exec $provider"
  [[ -n "$MCP_WARNING" ]] && warn "$MCP_WARNING"

  local output_path should_cat=0
  if [[ -n "$out_file" ]]; then
    output_path="$(_exec_abs_output_path "$out_file")"
  else
    output_path="$(mktemp)"
    should_cat=1
  fi

  local rc=0
  case "$provider" in
    codex)  _exec_codex "$cwd" "$model" "$effort" "$prompt" "$output_path" || rc=$? ;;
    claude) _exec_claude "$cwd" "$model" "$effort" "$prompt" "$output_path" || rc=$? ;;
    grok)   _exec_grok "$cwd" "$model" "$effort" "$prompt" "$output_path" || rc=$? ;;
    *)      die "exec: unsupported provider '$provider'" ;;
  esac

  if [[ "$rc" -ne 0 ]]; then
    [[ "$should_cat" -eq 1 ]] && rm -f "$output_path"
    return "$rc"
  fi

  # A provider can exit 0 yet write a useless report (empty, whitespace-only, or
  # a body that is just an error string). Returning success on that is a silent
  # re-run — the exact waste the product sells against. Validate BEFORE success.
  if ! _exec_output_is_useful "$output_path"; then
    err "exec: $provider exited 0 but produced no usable output (empty/placeholder); treating as failure"
    [[ "$should_cat" -eq 1 ]] && rm -f "$output_path"
    return 1
  fi

  if [[ "$should_cat" -eq 1 ]]; then
    cat "$output_path"
    rm -f "$output_path"
  fi
}

# Reject an output file that is too small to be real, blank once stripped, or is
# only a known error placeholder. Conservative on purpose: the 2-byte floor and
# whitespace check reject nothing legitimate (even a one-line "a\n" file list is
# >2 bytes), and the denylist matches ONLY when the ENTIRE stripped body equals a
# pure-error string — not merely contains it — so a real report that mentions
# "Execution error" in passing still passes. Returns 0 if useful, 1 if not.
_exec_output_is_useful() {
  local path="$1" bytes stripped
  [[ -f "$path" ]] || return 1
  # Byte floor: < 2 bytes cannot be a meaningful answer.
  bytes="$(wc -c <"$path" 2>/dev/null || echo 0)"
  [[ "$bytes" -ge 2 ]] || return 1
  # Strip leading/trailing whitespace (incl. blank lines); empty after strip = useless.
  stripped="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$path" | sed '/^$/d')"
  [[ -n "$stripped" ]] || return 1
  # Pure-error placeholders: reject only when the ENTIRE stripped body EXACTLY
  # equals one of these (no globs — a real report that merely opens with "Error:"
  # and continues must pass). Case-insensitive on the common single-word ones.
  local low; low="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    "execution error" | "error" | "null" | "undefined" \
    | "no response" | "no output" | "(no output)" | "n/a" )
      return 1
      ;;
  esac
  return 0
}

_exec_abs_output_path() {
  local path="$1" dir base
  [[ -n "$path" ]] || die "exec: -o requires a file"
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [[ -d "$dir" ]] || die "exec: output directory does not exist: $dir"
  dir="$(cd "$dir" && pwd)"
  printf '%s/%s\n' "$dir" "$base"
}

_exec_codex() {
  local cwd="$1" model="$2" effort="$3" prompt="$4" output_path="$5"
  local -a model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")

  # Pass through exactly; never clamp xhigh→high. max is not a Codex value.
  local -a effort_args=()
  case "$effort" in
    "") ;;
    minimal|low|medium|high|xhigh)
      effort_args=(-c "model_reasoning_effort=${effort}")
      ;;
    max)
      die "exec/codex: effort 'max' is not supported by Codex (use xhigh). Never silently remapped."
      ;;
    *)
      die "exec/codex: unsupported effort '$effort' (valid: minimal|low|medium|high|xhigh)"
      ;;
  esac

  local log_file rc=0
  log_file="$(mktemp)"
  (
    cd "$cwd"
    codex exec \
      "${model_args[@]}" \
      "${effort_args[@]}" \
      "${MCP_ARGV[@]}" \
      -c sandbox_mode=workspace-write \
      -c approval_policy=never \
      --skip-git-repo-check \
      "$prompt" \
      -o "$output_path" \
      </dev/null
  ) >"$log_file" 2>&1 || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    cat "$log_file" >&2
    rm -f "$log_file"
    return "$rc"
  fi
  rm -f "$log_file"
}

_exec_claude() {
  local cwd="$1" model="$2" effort="$3" prompt="$4" output_path="$5"
  local -a model_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")
  local -a effort_args=()
  [[ -n "$effort" ]] && effort_args=(--effort "$effort")

  (
    cd "$cwd"
    env "${MCP_ENV[@]}" claude --print \
      "${model_args[@]}" \
      "${effort_args[@]}" \
      "${MCP_ARGV[@]}" \
      --dangerously-skip-permissions \
      "$prompt" \
      </dev/null
  ) >"$output_path"
}

_exec_grok() {
  local cwd="$1" model="$2" effort="$3" prompt="$4" output_path="$5"
  local -a model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")
  local -a effort_args=()
  case "$effort" in
    low|medium|high|xhigh|max) effort_args=(--effort "$effort") ;;
  esac

  local log_file rc=0
  log_file="$(mktemp)"
  (
    cd "$cwd"
    grok -p "$prompt" \
      "${model_args[@]}" \
      "${effort_args[@]}" \
      --always-approve \
      --cwd "$cwd" \
      --output-format plain \
      </dev/null
  ) >"$output_path" 2>"$log_file" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    cat "$log_file" >&2
    rm -f "$log_file"
    return "$rc"
  fi
  rm -f "$log_file"
}
