# Codex resurrection must preserve paused goal state

Observed during the 2026-08-30 reboot recovery. Resuming Codex session
`019ff145-437b-7360-8693-8adb853b5410` presented:

```text
Resume paused goal?
Goal: finish moksha and mainnet as discussed, excluding migrating mainnet validators

1. Resume goal
2. Leave paused
```

This is lifecycle state, not an incidental TUI prompt. Selecting `1` changes the session
from paused to active and can restart autonomous work. A resurrection that intends to
reconstruct the stopped session should preserve the prior state and select/equivalently
request `Leave paused` by default.

`Resume goal` is appropriate only when Waspflow has a separate, unexpired continuation
lease or explicit owner instruction authorizing unattended work after recovery. The fact
that an agent process was running at shutdown is insufficient: the goal can still be
paused, and process liveness is not goal liveness.

Required product behavior:

1. Capture goal state with the session/lane receipt when possible.
2. On resurrection, preserve `paused`, `active`, and terminal states exactly.
3. If the provider exposes only an interactive choice, surface a deterministic
   `needs-owner` recovery state instead of guessing.
4. Never count a process sitting at this prompt as a successfully resumed lane.
5. Add a regression fixture for a paused Codex goal and prove no work begins until a
   continuation lease or owner action resumes it.

As checked on 2026-08-30, current official Codex CLI documentation does not describe a
resume-time goal-state switch, and `codex resume --help` exposes no option to choose
`Leave paused` noninteractively. Do not screen-scrape and inject `2` as if it were a
stable API. Until Codex exposes goal state through a supported interface, the correct
adapter behavior is to stop at `needs-owner`; the interactive prompt is the safety
boundary.

Related incident: the same recovery also restored wrong tmux identities and then wrote
those post-restore assignments into later snapshots. Goal-state preservation should be
part of the same end-to-end resurrection acceptance test, not a provider-only unit test.
