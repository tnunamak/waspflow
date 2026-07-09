#!/usr/bin/env bash
#
# exec.sh - stateless headless provider execution.
#
# Unlike spawn/revise, this intentionally does not create a lane, worktree,
# tmux window, transcript, or reap contract. It is a blocking subprocess helper
# for one-off analysis/transform prompts.

set -euo pipefail

exec_run() {
  local provider="" model="" effort="" cwd="$PWD" out_file=""
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
  if [[ -n "$effort" && ! "$effort" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    die "exec: --effort must be one of low|medium|high|xhigh|max (got: $effort)"
  fi

  load_provider "$provider"
  "${provider}_preflight" || die "exec aborted: $provider preflight failed"

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

  if [[ "$should_cat" -eq 1 ]]; then
    cat "$output_path"
    rm -f "$output_path"
  fi
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

  local -a effort_args=()
  case "$effort" in
    low)             effort_args=(-c model_reasoning_effort=low) ;;
    medium)          effort_args=(-c model_reasoning_effort=medium) ;;
    high|xhigh|max)  effort_args=(-c model_reasoning_effort=high) ;;
  esac

  local log_file rc=0
  log_file="$(mktemp)"
  (
    cd "$cwd"
    codex exec \
      "${model_args[@]}" \
      "${effort_args[@]}" \
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
    claude --print \
      "${model_args[@]}" \
      "${effort_args[@]}" \
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
