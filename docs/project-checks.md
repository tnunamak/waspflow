# Project checks

`waspflow check` is the repo/process integrity gate that complements live agent
control. It is intentionally generic: waspflow owns the implementation, while
each project owns its local policy in `.waspflow/config.json` or `.waspflow.json`.

Use it before launching worker lanes, reporting current state, merging worker
output, or closing out a multi-agent pass.

```bash
waspflow check
waspflow check --explain
waspflow check --no-fail
```

`--no-fail` prints the same inventory but exits successfully even when risks are
found. Use it for a readable checkpoint; do not use it to ignore real risks.

Use `waspflow init` to create config from reusable profiles:

```bash
waspflow init --profile serious-repo
waspflow init --profile serious-repo --profile openspec
waspflow init --profile live-stack-mutex --print
```

Profiles are just config generators. They do not change waspflow's global
behavior.

## Built-in checks

With no project config, `waspflow check` reports:

- current git branch, dirty state, and upstream ahead/behind state;
- all git worktrees in the repo and whether they are dirty;
- waspflow lanes whose `cwd` or `origin_cwd` belongs to the project;
- unreaped exited lanes;
- lanes with failed or missing deliverable contracts.

These are universal orchestration facts. They are not tied to any one repo.

## Project config

Add `.waspflow/config.json` when a project has local rules that should be
checked by the same gate. Prefer generating it with `waspflow init`, then edit
the project-specific facts:

```json
{
  "lanes": { "stale_seconds": 14400 },
  "mutexes": [
    {
      "name": "live-stack",
      "file": "tmp/workstreams/current-state.md",
      "open_pattern": "^- Status: OPEN"
    }
  ],
  "blockers": { "globs": [".git/workstreams/blockers/*"] },
  "reports": { "globs": ["tmp/workstreams/*.md"], "limit": 10 },
  "commands": [
    {
      "name": "OpenSpec status",
      "command": "node scripts/openspec-status.mjs",
      "severity": "warn"
    }
  ]
}
```

### `lanes.stale_seconds`

Marks live lanes as stale after the configured age. Stale is a warning, not a
failure: long-running lanes can be valid, but the owner should notice them.

### `mutexes`

Checks a project-owned file for an open mutex marker. A matching mutex is a
risk and causes a non-zero exit unless `--no-fail` is set.

This covers live-stack, database-maintenance, release, or other single-operator
windows without teaching waspflow what those windows mean.

### `blockers.globs`

Any matching file is a risk. Use this for local blocker-card directories or
review-gate sentinels.

### `reports.globs`

Shows recent report/handoff files. Reports are inventory, not failure.

### `commands`

Runs project-specific commands from the project root. A non-zero exit is a risk
by default. Set `"severity": "warn"` when the command is informational.

Keep commands short and summary-oriented. If a command emits thousands of lines,
fix the command; the status gate should be readable.

## Migration rule

Move local orchestration scripts into waspflow only when they enforce a general
invariant. Keep project facts as config.

Good waspflow features:

- git/worktree/lane inventory;
- deliverable-contract enforcement;
- mutex-file checks;
- blocker/report discovery;
- running configured health commands.

Project-specific config:

- the exact live-stack mutex file and open marker;
- the exact blocker/report globs;
- the exact validation commands for that repo;
- product-specific status vocabulary.
