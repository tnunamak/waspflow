# S4: secondary-adapter receipts and neutral handoff stay fail-closed offline.
(
  s4="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-s4-XXXXXX")"
  s4_socket="wf-test-$$"
  trap 'tmux -L "$s4_socket" kill-session -t s4-fixture 2>/dev/null || true; rm -rf "$s4"' EXIT
  tmux -L "$s4_socket" new-session -d -s s4-fixture 'exec sleep 30'

  export WASPFLOW_HOME="$s4/state" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/providers/grok.sh"
  source "$root/lib/providers/antigravity.sh"
  source "$root/lib/neutral-handoff.sh"

  # Prior turns and unrelated growth cannot confirm a current Grok submission.
  grok_events="$s4/grok-events.jsonl"
  printf '%s\n' '{"type":"turn_started","prompt":"old prompt"}' '{"type":"turn_ended"}' '{"type":"phase_changed"}' >"$grok_events"
  ! _grok_submission_receipt_present "$grok_events" 'current prompt' 0 \
    || { echo "s4: Grok accepted a prior/noise event" >&2; exit 1; }
  printf '%s\n' '{"type":"user","content":"current prompt"}' '{"type":"turn_started","prompt":"current prompt"}' >>"$grok_events"
  _grok_submission_receipt_present "$grok_events" 'current prompt' 3 \
    || { echo "s4: Grok rejected exact current receipt" >&2; exit 1; }

  # Fake agy records argv. Supported configuration reaches it unchanged; unsafe
  # raw flags fail before a provider process starts.
  mkdir -p "$s4/bin"
  cat >"$s4/bin/agy" <<'AGY'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${AGY_ARGV_FILE:?}"
for ((i=1; i<=$#; i++)); do [[ "${!i}" == --log-file ]] && { ((++i)); log="${!i}"; break; }; done
printf 'Created conversation 11111111-2222-3333-4444-555555555555\n' >"$log"
printf '%s\n' '{"type":"result","text":"delivered"}' >>"$log"
AGY
  cat >"$s4/bin/bash" <<'BASH'
#!/usr/bin/bash
exec /usr/bin/bash --noprofile --norc "$@"
BASH
  chmod +x "$s4/bin/agy" "$s4/bin/bash"
  export PATH="$s4/bin:$PATH" AGY_ARGV_FILE="$s4/agy-argv"
  lane_set agy-ok provider antigravity cwd "$s4" effort low report ""
  agy_cmd="$(_antigravity_shell agy-ok agy-model low '' task spawn --project "$s4/project name" --disable-slash-commands)"
  bash -lc "$agy_cmd"
  grep -Fx -- --project "$AGY_ARGV_FILE" >/dev/null
  grep -Fx -- "$s4/project name" "$AGY_ARGV_FILE" >/dev/null
  grep -Fx -- --disable-slash-commands "$AGY_ARGV_FILE" >/dev/null
  if _antigravity_extra_args --model other; then
    echo "s4: Antigravity accepted an unsafe raw argument" >&2; exit 1
  fi

  # Exit zero plus tool-only serialized output is a failed terminal result.
  cat >"$s4/bin/agy" <<'AGY'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do [[ "${!i}" == --log-file ]] && { ((++i)); log="${!i}"; break; }; done
printf 'Created conversation 11111111-2222-3333-4444-555555555555\n' >"$log"
printf '%s\n' '{"type":"tool","name":"write_file"}' >>"$log"
AGY
  chmod +x "$s4/bin/agy"
  lane_set agy-tool provider antigravity cwd "$s4" effort low report ""
  tool_cmd="$(_antigravity_shell agy-tool agy-model low '' task spawn)"
  if bash -lc "$tool_cmd"; then
    echo "s4: Antigravity accepted tool-only output" >&2; exit 1
  fi
  jq -e 'select(.phase == "completion" and .outcome == "failed")' "$WASPFLOW_HOME/lanes/agy-tool/antigravity-receipts.jsonl" >/dev/null
  [[ "$(lane_get agy-tool provider_terminal_outcome)" == failed ]] || { echo "s4: provider failure did not persist" >&2; exit 1; }

  # Neutral export has no launch side effect, treats the old transcript as
  # historical, redacts credential-shaped text, and refuses shared worktrees.
  lane_set shared provider grok worktree "" prompt 'keep the latest steering' report "$s4/report.md"
  if neutral_handoff_export shared "$s4/shared.json"; then
    echo "s4: neutral export transferred a shared worktree" >&2; exit 1
  fi
  lane_set isolated provider grok worktree "$s4/worktree" prompt 'keep the latest steering' report "$s4/report.md"
  mkdir -p "$s4/worktree" "$(lane_dir isolated)"
  printf 'api_key=not-for-export\n' >"$(lane_transcript isolated)"
  neutral_handoff_export isolated "$s4/neutral.json"
  jq -e '.transcript.state == "historical" and .ownership_transfer == "not_transferred"' "$s4/neutral.json" >/dev/null
  ! grep -q 'not-for-export' "$(lane_dir isolated)/transcript-historical.log" \
    || { echo "s4: neutral export leaked a credential" >&2; exit 1; }
)
