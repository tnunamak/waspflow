# R8: findings from the round-4 outsider journey on v1.9.3.
(
  r8="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r8-XXXXXX")"
  trap 'rm -rf "$r8"' EXIT
  export WASPFLOW_HOME="$r8/home" WASPFLOW_LIB="$root/lib" CODEX_SESSIONS_DIR="$r8/sessions"
  source "$root/lib/core.sh"
  source "$root/lib/providers/codex.sh"
  source "$root/lib/worktree.sh"
  mkdir -p "$r8/cwd" "$CODEX_SESSIONS_DIR"

  # HIGH-1: every Codex from 0.155 to 0.161 writes turn_context AFTER
  # task_started, inside the same turn. It must not discard the turn, or
  # task_complete is ignored and the lane never reaches idle. Older Codex wrote
  # turn_context first; that order must keep working.
  sid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  rollout="$CODEX_SESSIONS_DIR/rollout-r8-$sid.jsonl"
  lane_set r8-codex provider codex status live cwd "$r8/cwd" session_id "$sid" rollout "$rollout"
  row() { jq -cn --arg t "$1" --arg p "$2" --arg id "${3:-}" 'if $t == "turn_context" then {type:$t,payload:({model:"m"} + (if $id == "" then {} else {turn_id:$id} end))} else {type:"event_msg",payload:({type:$p} + (if $id == "" then {} else {turn_id:$id} end))} end'; }
  { row event_msg task_started T1; row response_item x; row turn_context "" T1; row turn_context "" T1; } >"$rollout"
  if codex_is_idle r8-codex; then echo 'r8 HIGH-1: running turn read as idle' >&2; exit 1; fi
  row event_msg task_complete T1 >>"$rollout"
  codex_is_idle r8-codex || { echo 'r8 HIGH-1: task_started->turn_context order never reached idle' >&2; exit 1; }
  [[ "$(codex_turn_mark r8-codex)" == 1 ]] || { echo 'r8 HIGH-1: turn mark lost in current order' >&2; exit 1; }
  # A second turn in the current order is busy until its own completion.
  { row event_msg task_started T2; row turn_context "" T2; } >>"$rollout"
  if codex_is_idle r8-codex; then echo 'r8 HIGH-1: second turn read as idle' >&2; exit 1; fi
  [[ "$(codex_turn_mark r8-codex)" == 1 ]] || { echo 'r8 HIGH-1: second turn advanced the mark early' >&2; exit 1; }
  row event_msg task_complete T1 >>"$rollout"
  if codex_is_idle r8-codex; then echo 'r8 HIGH-1: stale completion idled the second turn' >&2; exit 1; fi
  row event_msg task_complete T2 >>"$rollout"
  codex_is_idle r8-codex && [[ "$(codex_turn_mark r8-codex)" == 2 ]] \
    || { echo 'r8 HIGH-1: second turn did not complete' >&2; exit 1; }
  # Legacy order: turn_context before task_started.
  { row turn_context "" T1; row event_msg task_started T1; } >"$rollout"
  if codex_is_idle r8-codex; then echo 'r8 HIGH-1: legacy running turn read as idle' >&2; exit 1; fi
  row event_msg task_complete T1 >>"$rollout"
  codex_is_idle r8-codex || { echo 'r8 HIGH-1: legacy order never reached idle' >&2; exit 1; }
  # A turn_context naming another turn is a boundary: the old start is dropped.
  { row event_msg task_started T1; row turn_context "" T9; row event_msg task_complete T1; } >"$rollout"
  if codex_is_idle r8-codex; then echo 'r8 HIGH-1: foreign turn_context kept the old turn' >&2; exit 1; fi

  # MEDIUM: a login-shell function resolves to the file on that shell's PATH,
  # and both binaries are recorded and compared.
  mkdir -p "$r8/bin"
  printf '#!/bin/sh\necho "fixture-cli 1.0"\n' >"$r8/bin/lane-cli"
  printf '#!/bin/sh\necho "fixture-cli 2.0"\n' >"$r8/bin/spawner-cli"
  chmod +x "$r8/bin/lane-cli" "$r8/bin/spawner-cli"
  lane_set r8-id provider codex status live cwd "$r8/cwd"
  tmux_lane_provider_identity r8-id codex function "$r8/bin/spawner-cli" "$r8/bin/lane-cli" "fixture-cli 2.0"
  [[ "$(lane_get r8-id provider_binary_path)" == "$r8/bin/lane-cli" \
     && "$(lane_get r8-id provider_binary_version)" == "fixture-cli 1.0" \
     && "$(lane_get r8-id provider_binary_kind)" == function \
     && "$(lane_get r8-id spawner_binary_version)" == "fixture-cli 2.0" ]] \
    || { echo 'r8 MEDIUM: function-kind provider identity was not resolved to its file' >&2; exit 1; }
  mismatch="$(tmux_warn_provider_mismatch r8-id 2>&1)"
  [[ "$mismatch" == *"runs '$r8/bin/lane-cli' (fixture-cli 1.0)"*"spawner's '$r8/bin/spawner-cli' (fixture-cli 2.0)"* ]] \
    || { echo "r8 MEDIUM: no mismatch warning: $mismatch" >&2; exit 1; }
  tmux_lane_provider_identity r8-id "$r8/bin/lane-cli" file "$r8/bin/lane-cli" "" "fixture-cli 1.0"
  [[ -z "$(tmux_warn_provider_mismatch r8-id 2>&1)" ]] || { echo 'r8 MEDIUM: warned for identical binaries' >&2; exit 1; }

  # LOW: reaped lanes do not read as open work, in the batch and slow paths.
  lane_set r8-reaped provider codex status reaped cwd "$r8/cwd"
  lane_set r8-live provider codex status live cwd "$r8/cwd"
  for filter_status in "" reaped; do
    out="$("$root/bin/waspflow" list --json ${filter_status:+--status "$filter_status"} 2>/dev/null)"
    [[ "$(jq -r '.[] | select(.lane == "r8-reaped") | .outcome' <<<"$out")" == reaped ]] \
      || { echo "r8 LOW: reaped lane outcome wrong for status filter '$filter_status'" >&2; exit 1; }
  done
  [[ "$("$root/bin/waspflow" list 2>/dev/null | awk '$1 == "r8-reaped" { print $4 }')" == reaped ]] \
    || { echo 'r8 LOW: table OUTCOME for a reaped lane is not reaped' >&2; exit 1; }
  [[ "$("$root/bin/waspflow" list --json 2>/dev/null | jq -r '.[] | select(.lane == "r8-live") | .outcome')" == open ]] \
    || { echo 'r8 LOW: a non-reaped lane lost its open outcome' >&2; exit 1; }

  # LOW: clearer alias for the unknown-model acknowledgement; old flag kept.
  for flag in --ack-unknown-model --ack-deprecated; do
    out="$("$root/bin/waspflow" escalate r8-missing "$flag" --json 2>&1 || true)"
    [[ "$out" != *"unknown option"* && "$out" == *"no such lane"* ]] \
      || { echo "r8 LOW: escalate rejected $flag: $out" >&2; exit 1; }
  done

  # LOW: reap deletes a lane branch with no unique commits, keeps one that has some.
  repo="$r8/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.name Fixture; git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" branch waspflow/r8-clean
  git -C "$repo" branch waspflow/r8-merged
  git -C "$repo" worktree add -q -b waspflow/r8-unique "$r8/wt-unique" main
  git -C "$r8/wt-unique" commit -q --allow-empty -m unique
  git -C "$repo" worktree remove "$r8/wt-unique"
  git -C "$repo" commit -q --allow-empty -m advance
  git -C "$repo" merge -q --no-edit waspflow/r8-merged
  worktree_prune_lane_branch r8-clean "$repo" >/dev/null 2>&1
  worktree_prune_lane_branch r8-merged "$repo" >/dev/null 2>&1
  keep_msg="$(worktree_prune_lane_branch r8-unique "$repo" 2>&1)"
  # A detached repo HEAD must not count as "reachable": the commits would live only in the reflog.
  git -C "$repo" branch waspflow/r8-det main
  git -C "$repo" worktree add -q "$r8/wt-det" waspflow/r8-det
  git -C "$r8/wt-det" commit -q --allow-empty -m det
  git -C "$repo" worktree remove "$r8/wt-det"
  git -C "$repo" checkout -q --detach waspflow/r8-det
  det_msg="$(worktree_prune_lane_branch r8-det "$repo" 2>&1)"
  git -C "$repo" show-ref --verify --quiet refs/heads/waspflow/r8-det && [[ "$det_msg" == *"HEAD is detached"* ]] \
    || { echo "r8 LOW: branch was deleted while the repo HEAD is detached: $det_msg" >&2; exit 1; }
  git -C "$repo" checkout -q main
  worktree_prune_lane_branch r8-none "$repo" >/dev/null 2>&1
  if git -C "$repo" show-ref --verify --quiet refs/heads/waspflow/r8-clean \
     || git -C "$repo" show-ref --verify --quiet refs/heads/waspflow/r8-merged; then
    echo 'r8 LOW: branch with no unique commits survived reap' >&2; exit 1
  fi
  git -C "$repo" show-ref --verify --quiet refs/heads/waspflow/r8-unique \
    && [[ "$keep_msg" == *"kept branch 'waspflow/r8-unique'"* ]] \
    || { echo "r8 LOW: branch with unique commits was deleted or unannounced: $keep_msg" >&2; exit 1; }
)
