#!/usr/bin/env bash
#
# exec.sh - stateless headless provider execution.
#
# Unlike spawn/revise, this intentionally does not create a lane, worktree,
# tmux window, transcript, or reap contract. It is a blocking subprocess helper
# for one-off analysis/transform prompts.

set -euo pipefail

exec_run() {
  local provider="" model="" effort="" mcp="auto" cwd="$PWD" out_file="" op_id="" OP_ID="" OP_MODE=""
  local provider_explicit=false model_explicit=false auto=false ack_deprecated=false accept_provider_default=false
  local -a needs_paths=()
  split_after_ddash "$@"
  set -- "${FLAGS[@]:-}"
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --provider)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --provider requires a value"
        provider="$2"; provider_explicit=true; shift 2
        ;;
      --op)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --op requires a value"
        op_id="$2"; shift 2
        ;;
      --model)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --model requires a value"
        model="$2"; model_explicit=true; shift 2
        ;;
      --auto) auto=true; shift ;;
      --ack-deprecated) ack_deprecated=true; shift ;;
      --accept-provider-default) accept_provider_default=true; shift ;;
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
      --needs-path)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "exec: --needs-path requires a readable path"
        needs_paths+=("$2"); shift 2
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

  [[ "$auto" == false || -n "$op_id" ]] || die "exec: --auto requires --op"
  [[ "$auto" == false || "$model_explicit" == false ]] || die "exec: --auto conflicts with --model"
  [[ "$auto" == false || "$accept_provider_default" == false ]] || die "exec: --auto conflicts with --accept-provider-default"
  [[ "$model_explicit" == false || "$accept_provider_default" == false ]] || die "exec: --model conflicts with --accept-provider-default"
  [[ "$ack_deprecated" == false || "$auto" == true ]] || die "exec: --ack-deprecated applies only to --auto"
  local selection_mode
  selection_mode="$(selection_gate_mode)"
  if [[ "$selection_mode" == enforce && -z "$op_id" && "$model_explicit" == false && "$accept_provider_default" == false ]]; then
    selection_menu
    return 5
  fi
  if [[ "$selection_mode" == warn && -z "$op_id" && "$model_explicit" == false && "$accept_provider_default" == false ]]; then
    warn "selection: bare provider default; add --accept-provider-default to make this intentional"
  fi
  if [[ -n "$op_id" ]]; then
    local op_fallback_provider op_fallback_model
    op_fallback_provider="$(jq -r '.expands_to.provider // empty' <<<"$(ops_get_point "$op_id")")"
    op_fallback_model="$(jq -r '.expands_to.model // empty' <<<"$(ops_get_point "$op_id")")"
    if [[ "$provider_explicit" == true && "$model_explicit" == false && "$provider" != "$op_fallback_provider" ]]; then
      die "op $op_id resolves $op_fallback_provider/$op_fallback_model; --provider $provider contradicts it — give --model too, or drop one"
    fi
    ops_apply_to_spawn "$op_id"
    [[ "$accept_provider_default" == true ]] && model=""
  fi

  [[ -n "$provider" ]] || die "exec: --provider is required (claude|codex|grok|antigravity|qwen|deepseek; or use --op)"
  is_known_provider "$provider" || die "exec: unknown provider '$provider'"
  [[ -n "$prompt" ]] || die "exec: a task prompt is required after '--'"
  cwd="$(cd "$cwd" 2>/dev/null && pwd)" || die "exec: --cwd does not exist"
  guard_cwd "$cwd"   # never run a worker with cwd '/' silently (known crash class)
  if [[ "$provider" == qwen && -n "$effort" ]]; then
    die "exec/qwen: --effort is not supported by Qwen Code"
  elif [[ "$provider" == deepseek && -n "$effort" ]]; then
    die "exec/deepseek: --effort is not supported by DeepSeek Harness (dsh v0.1 exposes reasoning effort only via global \$DSH_HOME/settings.yaml)"
  elif [[ "$provider" == antigravity && -n "$effort" && ! "$effort" =~ ^(low|medium|high)$ ]]; then
    die "exec/antigravity: unsupported effort '$effort' (valid: low|medium|high)"
  elif [[ -n "$effort" && ! "$effort" =~ ^($WASPFLOW_EFFORT_TOKENS)$ ]]; then
    die "exec: --effort must be one of ${WASPFLOW_EFFORT_TOKENS//|/, } (got: $effort)"
  fi

  load_provider "$provider"
  if [[ "$selection_mode" == enforce && -n "$op_id" && "$model_explicit" == false && "$accept_provider_default" == false ]]; then
    local gate_billing selection_rc=0
    gate_billing="$(billing_path_v1 "$provider" default false)"
    selection_gate_op "$op_id" "$provider" "$model" default "$gate_billing" "$ack_deprecated" "$auto" || selection_rc=$?
    [[ "$selection_rc" -eq 0 ]] || return "$selection_rc"
  fi
  validate_model "$provider" "$model" exec
  if [[ -n "$op_id" ]]; then
    local exec_billing
    exec_billing="$(billing_path_v1 "$provider" default false)"
    selection_prepare_op "$op_id" "$provider" "$model" "$MODEL_VALIDATION_SCOPE" "$exec_billing" "$ack_deprecated"
    if [[ "$selection_mode" == warn || "$model_explicit" == true ]]; then selection_emit_warnings "$SELECTION_DISPOSITION"; fi
  elif [[ "$model_explicit" == true ]]; then
    local explicit_edge explicit_disposition
    explicit_edge="$(selection_edge_label "$provider" "$model")"
    explicit_disposition="$(selection_disposition "$MODEL_VALIDATION_STATE" unratified "$explicit_edge" none false false false explicit)"
    selection_emit_warnings "$explicit_disposition"
  fi
  resolve_mcp_policy "$provider" "$mcp" "$cwd" \
    || die "$provider: cannot resolve MCP policy '$mcp'"
  "${provider}_preflight" || die "exec aborted: $provider preflight failed"
  mcp_policy_load_json "$MCP_ARGV_JSON" "$MCP_ENV_JSON" "exec $provider"
  [[ -n "$MCP_WARNING" ]] && warn "$MCP_WARNING"

  local output_path provider_output_path should_cat=0 staged_output=""
  if [[ -n "$out_file" ]]; then
    output_path="$(_exec_abs_output_path "$out_file")" || return 1
    staged_output="$(mktemp "$(dirname "$output_path")/.waspflow-output.XXXXXX")" || return 1
    provider_output_path="$staged_output"
  else
    output_path="$(mktemp)" || return 1
    provider_output_path="$output_path"
    should_cat=1
  fi

  if ! _exec_access_preflight "$provider" "$cwd" "$output_path" "${needs_paths[@]}"; then
    [[ "$should_cat" -eq 0 ]] || rm -f "$output_path"
    [[ -z "$staged_output" ]] || rm -f "$staged_output"
    return 1
  fi
  local invoked_epoch exec_id rc=0 result=succeeded
  invoked_epoch="$(date +%s)"; exec_id="$(new_uuid)"
  case "$provider" in
    codex)  _exec_codex "$cwd" "$model" "$effort" "$prompt" "$provider_output_path" || rc=$? ;;
    claude) _exec_claude "$cwd" "$model" "$effort" "$prompt" "$provider_output_path" || rc=$? ;;
    grok)   _exec_grok "$cwd" "$model" "$effort" "$prompt" "$provider_output_path" || rc=$? ;;
    antigravity) _exec_antigravity "$cwd" "$model" "$effort" "$prompt" "$provider_output_path" || rc=$? ;;
    qwen)     _exec_qwen "$cwd" "$model" "$prompt" "$provider_output_path" || rc=$? ;;
    deepseek) _exec_deepseek "$cwd" "$model" "$prompt" "$provider_output_path" || rc=$? ;;
    *)      die "exec: unsupported provider '$provider'" ;;
  esac

  [[ "$rc" -ne 0 ]] && result=failed

  # A provider can exit 0 yet write no answer at all (empty or whitespace-only).
  # Returning success on that is a silent
  # re-run — the exact waste the product sells against. Validate BEFORE success.
  if [[ "$rc" -eq 0 ]] && ! _exec_output_is_useful "$provider_output_path"; then
    err "exec: $provider exited 0 but produced no usable output (empty/placeholder); treating as failure"
    rc=1; result=failed
  fi

  # Codex's successful headless output can omit its final line feed. Normalize
  # the staged output before publication so both `-o FILE` and stdout mode have
  # normal terminal/file text semantics without touching failed output.
  if [[ "$rc" -eq 0 && "$provider" == codex && "$(tail -c1 "$provider_output_path" 2>/dev/null)" != "" ]]; then
    printf '\n' >>"$provider_output_path"
  fi

  # Providers write to a unique sibling file. Only validated output is renamed
  # over the destination, so an exit-0/no-write cannot relabel old output as new.
  if [[ "$rc" -eq 0 && -n "$staged_output" ]]; then
    if _exec_move_file_exact "$staged_output" "$output_path"; then
      staged_output=""
    else
      staged_output="$EXEC_MOVE_REMAINDER"
      provider_output_path="$staged_output"
      rc=1; result=failed
    fi
  fi

  local availability billing completed_epoch
  availability="$(jq -cn --arg p "$provider" --arg m "$model" --arg state "${MODEL_VALIDATION_STATE:-not_applicable}" --arg source "${MODEL_VALIDATION_SOURCE:-none}" --arg scope "${MODEL_VALIDATION_SCOPE:-not_applicable}" --arg at "${MODEL_VALIDATION_AT:-}" '{schema_version:1,provider:$p,model:$m,state:$state,evidence_source:$source,query_scope:$scope,observed_at:(if $at == "" then null else $at end),detail:""}')"
  billing="$(billing_path_v1 "$provider" default false)"; completed_epoch="$(date +%s)"
  local output_state=missing output_bytes=0 output_metadata
  if [[ -f "$provider_output_path" ]]; then
    output_bytes="$(wc -c <"$provider_output_path")"
    output_state=invalid
    _exec_output_is_useful "$provider_output_path" && output_state=present
  elif [[ "$rc" -eq 0 && -f "$output_path" ]]; then
    output_bytes="$(wc -c <"$output_path")"
    output_state=present
  fi
  output_metadata="$(jq -cn --arg state "$output_state" --argjson bytes "$output_bytes" --argjson preflight "$EXEC_PREFLIGHT_JSON" '{state:$state,bytes:$bytes,preflight:$preflight}')"
  artifacts_emit_exec_receipt_v1 "$exec_id" "$provider" "$model" "$effort" "${OP_MODE:-standard}" "$billing" "$availability" "$invoked_epoch" "$completed_epoch" "$result" "$rc" "$output_metadata" \
    || warn "exec: could not emit receipt"
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$staged_output" ]]; then
      # Keep whatever the failed run wrote for diagnosis, beside (never at) the
      # destination so a failure cannot pass as the new result.
      if [[ -s "$staged_output" ]]; then
        if _exec_move_file_exact "$staged_output" "$output_path.partial"; then
          warn "exec: failed run's partial output kept at $output_path.partial"
        else
          staged_output="$EXEC_MOVE_REMAINDER"
          if [[ -s "$staged_output" ]]; then
            warn "exec: failed run's partial output retained at $staged_output"
          else
            rm -f "$staged_output"
          fi
        fi
      else
        rm -f "$staged_output"
      fi
    fi
    [[ "$should_cat" -eq 1 ]] && rm -f "$output_path"
    return "$rc"
  fi

  if [[ "$should_cat" -eq 1 ]]; then
    cat "$output_path"
    rm -f "$output_path"
  fi
}

_exec_antigravity() {
  local cwd="$1" model="$2" effort="$3" prompt="$4" output_path="$5"
  local -a model_args=() effort_args=()
  antigravity_validate_model_effort "$model" "$effort" || return 1
  [[ -n "$model" ]] && model_args=(--model "$model")
  [[ -n "$effort" ]] && effort_args=(--effort "$effort")
  (cd "$cwd" && agy --print "$prompt" "${model_args[@]}" "${effort_args[@]}" --mode accept-edits --dangerously-skip-permissions) >"$output_path"
}

_exec_qwen() {
  local cwd="$1" model="$2" prompt="$3" output_path="$4"
  local -a model_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")
  (cd "$cwd" && qwen -p "$prompt" "${model_args[@]}" --yolo --output-format text </dev/null) >"$output_path"
}

# dsh's headless profile takes ONLY a task positional (plus -h) and prints the
# final assistant text on stdout. Model selection is configuration, not argv:
# a temporary --patch overlay retargets the `agent-default-model` entry.
_exec_deepseek() {
  local cwd="$1" model="$2" prompt="$3" output_path="$4"
  local -a patch_args=()
  local patch=""
  if [[ -n "$model" ]]; then
    patch="$(mktemp "${TMPDIR:-/tmp}/waspflow-dsh-patch.XXXXXX.yml")" || return 1
    {
      printf -- '- id: agent-default-model\n'
      printf -- '  config:\n'
      printf -- '    provider: %s\n' "${DEEPSEEK_PROVIDER_ROUTE:-deepseek-official}"
      printf -- '    model: %s\n' "$model"
    } >"$patch"
    patch_args=(--patch "$patch")
  fi
  local rc=0
  (cd "$cwd" && dsh --profile headless "${patch_args[@]}" -- "$prompt" </dev/null) >"$output_path" || rc=$?
  [[ -n "$patch" ]] && rm -f "$patch"
  return "$rc"
}

# Reject blank output and unmistakable provider-error shapes. Output semantics
# belong to the caller: `null`, a classification word, and a one-byte answer can
# all be valid results. Returns 0 if useful, 1 if not.
_exec_output_is_useful() {
  local path="$1" bytes stripped
  [[ -f "$path" ]] || return 1
  # An empty file cannot be an answer; a one-byte file can.
  bytes="$(wc -c <"$path" 2>/dev/null || echo 0)"
  [[ "$bytes" -ge 1 ]] || return 1
  # Strip leading/trailing whitespace (incl. blank lines); empty after strip = useless.
  stripped="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$path" | sed '/^$/d')"
  [[ -n "$stripped" ]] || return 1
  # This generic adapter has no structured provider-error channel. Do not
  # reserve answer text: classifications such as `N/A`, `no response`,
  # `permission denied`, and `Error: ...` are valid when the provider exits 0.
  return 0
}

# Move a staged regular file to one exact regular-file destination. `mv` treats
# a directory target as a container, so re-check the target after moving and
# retain the stage's actual path if a concurrent directory creation absorbed it.
# On failure, EXEC_MOVE_REMAINDER names the provider output that remains.
_exec_move_file_exact() {
  local source="$1" target="$2" relocated
  EXEC_MOVE_REMAINDER="$source"
  [[ -f "$source" && ! -L "$source" && ! -d "$target" ]] || return 1
  if mv -f "$source" "$target" && [[ -f "$target" && ! -L "$target" ]]; then
    EXEC_MOVE_REMAINDER=""
    return 0
  fi
  relocated="$target/$(basename "$source")"
  if [[ -f "$relocated" && ! -L "$relocated" ]]; then
    EXEC_MOVE_REMAINDER="$relocated"
  fi
  return 1
}

_exec_abs_output_path() {
  local path="$1" dir base
  [[ -n "$path" ]] || die "exec: -o requires a file"
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [[ -d "$dir" ]] || die "exec: output directory does not exist: $dir"
  dir="$(cd "$dir" && pwd -P)" || return 1
  path="$dir/$base"
  [[ ! -L "$path" ]] || die "exec: output must not be a symlink: $path"
  [[ ! -e "$path" || ( -f "$path" && -w "$path" ) ]] || die "exec: output is not a writable regular file: $path"
  [[ -w "$dir" && -x "$dir" ]] || die "exec: output directory is not writable/searchable: $dir"
  local probe
  probe="$(mktemp "$dir/.waspflow-output-preflight.XXXXXX")" || die "exec: cannot create output in: $dir"
  rm -f "$probe" || return 1
  printf '%s\n' "$path"
}

# Host access is a prerequisite, never proof of provider sandbox access.
_exec_access_preflight() {
  local provider="$1" cwd="$2" output_path="$3" path sandbox=unknown required='[]'
  shift 3
  [[ "$provider" != codex ]] || sandbox=workspace-write
  for path in "$@"; do
    [[ "$path" == /* ]] || path="$cwd/$path"
    [[ -e "$path" && -r "$path" && ( ! -d "$path" || -x "$path" ) ]] \
      || { err "exec: required path is not readable/searchable: $path"; return 1; }
    required="$(jq -c --arg path "$path" '. + [{path:$path,host_access:"readable",provider_access:"unknown"}]' <<<"$required")"
  done
  EXEC_PREFLIGHT_JSON="$(jq -cn --arg provider "$provider" --arg cwd "$cwd" --arg sandbox "$sandbox" --arg output "$output_path" --argjson required "$required" '{provider:$provider,cwd:$cwd,sandbox_requested:$sandbox,sandbox_effective:"unknown",output_path:$output,required_paths:$required}')"
  printf 'exec preflight: %s\n' "$EXEC_PREFLIGHT_JSON" >&2
}

_exec_codex() {
  local cwd="$1" model="$2" effort="$3" prompt="$4" output_path="$5"
  local -a model_args=()
  [[ -n "$model" ]] && model_args=(-m "$model")

  # Pass through exactly; never clamp xhigh/max to a lower effort.
  local -a effort_args=()
  case "$effort" in
    "") ;;
    minimal|low|medium|high|xhigh|max|ultra)
      effort_args=(-c "model_reasoning_effort=${effort}")
      ;;
    *)
      die "exec/codex: unsupported effort '$effort' (valid: minimal|low|medium|high|xhigh|max|ultra)"
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

  local rc=0 stderr_dir stderr_file stderr_fifo tee_pid last_stdout_line
  stderr_dir="$(mktemp -d)"
  stderr_file="$stderr_dir/stderr.log"
  stderr_fifo="$stderr_dir/stderr.fifo"
  mkfifo "$stderr_fifo"
  # Keep stderr live for callers while retaining it for the ceiling check.
  tee "$stderr_file" <"$stderr_fifo" >&2 &
  tee_pid=$!
  (
    cd "$cwd"
    env "${MCP_ENV[@]}" claude --print \
      "${model_args[@]}" \
      "${effort_args[@]}" \
      "${MCP_ARGV[@]}" \
      --dangerously-skip-permissions \
      -- \
      "$prompt" \
      </dev/null
  ) >"$output_path" 2>"$stderr_fifo" || rc=$?
  # tee must finish draining the FIFO before the captured stderr is inspected.
  wait "$tee_pid"

  # Claude can exit 0 after terminating a print turn at its background-task
  # wait ceiling. Keep the produced output for callers, but report interruption
  # as failure so exec does not treat partial work as success.
  last_stdout_line="$(awk 'NF { line = $0 } END { print line }' "$output_path")"
  if grep -Eq 'Background tasks still running after [^[:cntrl:]]*terminating' "$stderr_file" \
    || grep -Eq 'Background tasks still running after [^[:cntrl:]]*terminating' <<<"$last_stdout_line"; then
    rm -rf "$stderr_dir"
    err "exec/claude: print stopped at the background-task wait ceiling; set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely"
    return 1
  fi
  rm -rf "$stderr_dir"
  return "$rc"
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
