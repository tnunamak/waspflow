# Maintenance-mode pilot integration — 2026-10-06

Branch: `pilot/integration`; base: chosen steer/resume `4323b95` on `f6b7f36`.
No push or merge to main was performed.

## Applied patches and conflict resolutions

Applied each source artifact with `git apply --3way`, in the requested order.

| Commit | Source |
| --- | --- |
| `9b72a8c` | `dot-reap.patch`, assignment `pilot-wf-reap-20261006` |
| `fbf5025` | `dot-wait.patch`, assignment `pilot-wf-wait-20261006` |
| `8f17185` | `dot-start.patch`, assignment `pilot-wf-start-20261006` |

1. Reap versus chosen steer in `scripts/verify.sh`: both appended a block just before the final success line. Kept both complete regression blocks. No implementation hunk conflicted.
2. Start versus chosen steer in `lib/providers/codex.sh`, `codex_spawn`: kept the start patch's failure propagation when the pane disappears or composer readiness fails. The chosen paused-goal refusal remains in the readiness helper and continues to stop resume before submission.
3. Start versus chosen steer in `_codex_clear_trust_prompt`: kept both the chosen paused-goal detector and the start patch's startup-menu detector. Neither sends a key for those prompts.
4. Start versus chosen steer in `_codex_wait_composer_ready`: kept the chosen paused-goal return code 2, plus the start patch's menu detection and pane-existence check. Spawn's submission step checks and records startup menus before any paste or Enter.
5. Start versus prior appended regression blocks in `scripts/verify.sh`: retained the chosen steer, reap, and start blocks in sequence.

The wait patch had no textual conflict. It did have a receipt mismatch: its waiter watched `revise_submission_state`, while the chosen synchronous headless revise writes `headless_revise_state`. The integration change makes `wait` use the chosen receipt when no pane exists: running work vetoes old idle, a dead process or failed/timeout receipt returns rc 3, and a completed process is a terminal oracle. The `wait --reap` lock recheck uses the same state. Reap now refuses an active headless revise; after completion, it stops recorded owned scopes before reporting cleanup complete. Regression cases cover these paths.

## Integrated verification

Command: `WASPFLOW_TEST_TMPDIR=~/.tmp bash scripts/verify.sh`

Result: exit 0; final output `waspflow verify: ok`. The suite includes exact-first-turn Codex receipts, startup update/trust/capacity fixtures, shell hydration timeout, current-turn wait oracles, headless receipt integration, partial reap, owned scope cleanup, GC blocked/removable classification, and one-shot output fixtures.

The output fixture command was also run directly against `_exec_output_is_useful`: a two-file response printed `good=accepted`; an `Execution error`-only response printed `error-only=rejected`.

## Live environment

Commands below used `/home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run`, which executes this worktree's `bin/waspflow` with:

- `WASPFLOW_HOME=/home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/home`
- `WASPFLOW_TMUX_SESSION=pilot-LxzUNb`
- a pilot-only `tmux` wrapper that invokes `/usr/bin/tmux -L test-waspflow-pilot-LxzUNb` for every tmux command
- `BASH_ENV` pilot wrappers that remove `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` and invoke the local Claude/Codex executables; a login-shell probe reported both variables absent

No default tmux session or Waspflow home was used. Provider prompts requested no file edits. The live provider calls used only `claude-haiku-4-5` and `gpt-6-luna` at low effort for Codex.

### Claude lane

The commands are the exact argv used. Output lines below keep the decisive verbatim lines; `peek` and `status` projections are labeled as excerpts.

```text
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run spawn --provider claude --model claude-haiku-4-5 --mcp none --no-parent --lane pilot-claude --cwd /home/tnunamak/.t3/worktrees/waspflow/pilot-integration -- 'Run the shell command sleep 6 once. Then reply with exactly CLAUDE_PILOT_DONE. Do not edit files or spawn other agents.'
waspflow: selection: availability_unknown
waspflow: spawned claude lane 'pilot-claude' (tmux: pilot-LxzUNb:pilot-claude) — next: wait/peek/revise/reap pilot-claude
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-claude --timeout 120 --interval 1
waspflow: wait: lane 'pilot-claude' is IDLE
elapsed=0.46 sec rc=0
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run revise pilot-claude -- 'Run the shell command sleep 15 once, then reply exactly CLAUDE_SECOND_TURN_DONE. Do not edit files.'
waspflow: revise: steering live pane for lane 'pilot-claude'
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-claude --timeout 120 --interval 1
waspflow: wait: lane 'pilot-claude' is IDLE
elapsed=11.53 sec rc=0
peek excerpt: 'Ran 1 shell command'; 'CLAUDE_SECOND_TURN_DONE'; 'Churned for 16s'
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run park pilot-claude --reason 'pilot parked resume verification'
waspflow: park: lane 'pilot-claude' parked — transcript, state, session, worktree, and artifacts preserved
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run revise pilot-claude --out /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/claude-headless.txt -- 'Run the shell command sleep 8 once, then reply exactly CLAUDE_HEADLESS_DONE. Do not edit files.'
waspflow: revise: lane 'pilot-claude' window exited; resuming session headlessly
status during revise: record_status=parked, headless_revise_state=running, headless_revise_active=true
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-claude --timeout 120 --interval 1
waspflow: wait: lane 'pilot-claude' is IDLE
elapsed=4.66 sec rc=0
output file: CLAUDE_HEADLESS_DONE
status after revise: headless_revise_state=completed, headless_revise_rc=0
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run reap pilot-claude --no-archive
waspflow: reap: lane 'pilot-claude' cleanup complete; remaining=[] (explicitly retained)
waspflow: reap: lane 'pilot-claude' reaped — result=succeeded
reap-cleanup.json: {"state":"complete","errors":[],"remaining_resources":[],"inventory":"recorded-only"}
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run revise pilot-claude --out /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/claude-reaped.txt -- 'Reply exactly CLAUDE_REAPED_REVISE_DONE. Do not edit files or use tools.'
waspflow: revise: lane 'pilot-claude' window exited; resuming session headlessly
output file: CLAUDE_REAPED_REVISE_DONE
status: record_status=reaped, headless_revise_state=completed, headless_revise_rc=0
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run reap pilot-claude --no-archive
waspflow: reap: lane 'pilot-claude' cleanup complete; remaining=[] (explicitly retained)
waspflow: reap: lane 'pilot-claude' reaped — result=succeeded
```

The first spawn turn had already finished by the first `wait` call; its pane showed `CLAUDE_PILOT_DONE` and a 10-second turn. The second live turn and parked headless turn were observed while active, so their waits test the false-idle boundary. The Claude session log reported runtime model `claude-haiku-4-5-20251001` for requested `claude-haiku-4-5`.

### Codex lane and GC

```text
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run spawn --provider codex --model gpt-6-luna --effort low --mcp none --no-parent --lane pilot-codex --isolate --cwd /home/tnunamak/.t3/worktrees/waspflow/pilot-integration -- 'Run the shell command sleep 10 once. Then reply exactly CODEX_PILOT_DONE. Do not edit files or spawn other agents.'
waspflow: isolated worktree: /home/tnunamak/.t3/worktrees/waspflow/pilot-integration-waspflow-pilot-codex
waspflow: spawned codex lane 'pilot-codex' (tmux: pilot-LxzUNb:pilot-codex) — next: wait/peek/revise/reap pilot-codex
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-codex --timeout 120 --interval 1
waspflow: wait: lane 'pilot-codex' is IDLE
elapsed=0.21 sec rc=0
peek excerpt: 'Ran sleep 10'; 'CODEX_PILOT_DONE'; 'Worked for 13s'
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run revise pilot-codex -- 'Run the shell command sleep 15 once, then reply exactly CODEX_SECOND_TURN_DONE. Do not edit files.'
waspflow: revise: steering live pane for lane 'pilot-codex'
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-codex --timeout 120 --interval 1
waspflow: wait: lane 'pilot-codex' is IDLE
elapsed=14.26 sec rc=0
peek excerpt: 'Ran sleep 15'; 'CODEX_SECOND_TURN_DONE'; 'Worked for 19s'
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run gc --worktrees --repo /home/tnunamak/code/waspflow --json > /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/gc.json
gc.json excerpt: "disposition": "blocked"; "reasons": ["process cwd/open files inside: pid 3997496,3997542,3997643,3998387,3998410", "tmux pane cwd inside", "live lane record: pilot-codex"]
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run reap pilot-codex
waspflow: reap: branch 'waspflow/pilot-codex' is fully merged (8f1718550); no bundle needed
waspflow: reap: lane 'pilot-codex' cleanup complete; remaining=[] (explicitly retained)
waspflow: reap: lane 'pilot-codex' reaped — result=succeeded
reap-cleanup.json: {"state":"complete","errors":[],"remaining_resources":[],"inventory":"recorded-only"}
worktree=removed
```

The initial Codex turn completed before the first `wait` call. The second turn was observed in progress. Its final runtime receipt recorded requested and observed `gpt-6-luna` / `low`, `runtime_refresh_state=observed`, and `runtime_settings_match_requested=true`. The GC command was a dry run; its full JSON output is in the isolated local pilot directory.

### Direct spawn-to-wait checks

The first two lanes' initial turns ended before `wait` started. These additional lanes called `wait` immediately after spawn returned, with no analysis step between commands. Both waits stayed active until the current turn's final response.

```text
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run spawn --provider claude --model claude-haiku-4-5 --mcp none --no-parent --lane pilot-claude-wait --cwd /home/tnunamak/.t3/worktrees/waspflow/pilot-integration -- 'Run the shell command sleep 25 once. After it finishes, reply exactly CLAUDE_SPAWN_WAIT_DONE. Do not edit files.'
waspflow: selection: availability_unknown
waspflow: spawned claude lane 'pilot-claude-wait' (tmux: pilot-LxzUNb:pilot-claude-wait) — next: wait/peek/revise/reap pilot-claude-wait
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-claude-wait --timeout 120 --interval 1
waspflow: wait: lane 'pilot-claude-wait' is IDLE
elapsed=27.38 sec rc=0
peek excerpt: 'Ran 1 shell command'; 'CLAUDE_SPAWN_WAIT_DONE'; 'Crunched for 28s'
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run reap pilot-claude-wait --no-archive
waspflow: reap: lane 'pilot-claude-wait' cleanup complete; remaining=[] (explicitly retained)
waspflow: reap: lane 'pilot-claude-wait' reaped — result=succeeded

$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run spawn --provider codex --model gpt-6-luna --effort low --mcp none --no-parent --lane pilot-codex-wait --cwd /home/tnunamak/.t3/worktrees/waspflow/pilot-integration -- 'Run the shell command sleep 30 once. After it finishes, reply exactly CODEX_SPAWN_WAIT_DONE. Do not edit files or spawn other agents.'
waspflow: spawned codex lane 'pilot-codex-wait' (tmux: pilot-LxzUNb:pilot-codex-wait) — next: wait/peek/revise/reap pilot-codex-wait
$ /usr/bin/time -f 'elapsed=%e sec rc=%x' /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run wait pilot-codex-wait --timeout 120 --interval 1
waspflow: wait: lane 'pilot-codex-wait' is IDLE
elapsed=23.50 sec rc=0
peek excerpt: 'Ran sleep 30'; 'CODEX_SPAWN_WAIT_DONE'; 'Worked for 36s'
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run reap pilot-codex-wait --no-archive
waspflow: reap: lane 'pilot-codex-wait' cleanup complete; remaining=[] (explicitly retained)
waspflow: reap: lane 'pilot-codex-wait' reaped — result=succeeded
```

### One-shot execution

```text
$ /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/run exec --provider claude --model claude-haiku-4-5 --mcp none --cwd /home/tnunamak/.t3/worktrees/waspflow/pilot-integration -o /home/tnunamak/.tmp/waspflow-pilot-live-LxzUNb/exec-live.txt -- 'Reply with exactly PILOT_EXEC_OK and no other text.'
waspflow: selection: availability_unknown
rc=0; output file='PILOT_EXEC_OK' (14 bytes)
```

## Open items and limits

- The live host showed no Codex update, trust, or capacity menu, so the safe blocked state was verified by deterministic fixtures rather than a live interstitial. A real interstitial has not been witnessed on this branch.
- Reap inventory covers recorded resources. An arbitrary lane-created resource outside its recorded scopes/worktree is not attributed by this patch. The GC scanner remains read-only and any future removal action needs a fresh liveness check.
- The start receipt labels the login-shell provider as a function and leaves its executable version `unknown`; the runtime model/effort receipt supplies the Codex attestation. This is honest but less diagnostic than a resolved file path.
- Reap removed the Codex worktree but retained the fully merged local `waspflow/pilot-codex` branch, matching `worktree_remove`'s existing behavior. The branch was not pushed or merged by this pilot.
