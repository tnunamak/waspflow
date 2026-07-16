# grok `--cwd /` crash — cwd preflight gap

**Date:** 2026-07-09
**Severity:** reliability (multi-GB crash debris; wasted spend on a doomed turn)
**Status:** incident observed; fix in flight (reliability workstream, BUG 3)

## What happened
Three core dumps (~2.5GB total) were found in the repo root:

```
core.4036701: from 'grok --session-id <uuid> --always-approve --cwd /'
core.4044476: from 'grok --session-id <uuid> --always-approve --cwd /'
core.4050686: from 'grok --session-id <uuid> --always-approve --cwd /'
```

Every crashed process was a **grok worker launched with `--cwd /`** — the root filesystem.
Grok crashing there is partly grok's own bug, but the real defect is that **waspflow handed a
worker `/` as its working directory in the first place.** A worker at `/` will try to index the
entire filesystem, is near-guaranteed to fail or hang, and burns quota on a turn that can never
produce a useful result.

## Root cause (likely)
`exec`/`spawn` default `cwd="$PWD"`. When waspflow (or its demo) is invoked from `/`, that `/`
flows straight through to `grok --cwd "$cwd"` with no sanity check. `lib/exec.sh` and the grok
adapter both interpolate `--cwd "$cwd"` unguarded.

## Fix
- Refuse to launch any worker when the resolved cwd is `/` unless `WASPFLOW_ALLOW_ROOT_CWD=1`.
  Clear error, fail-closed. (Being implemented as BUG 3 in the reliability workstream.)
- Consider a broader "access preflight" (cwd exists, is a dir, is not `/` or `$HOME` root)
  per the 2026-07-09-exec-output-validation note.

## Cleanup done
The three gitignored core dumps were removed (freed ~2.5GB). `core.*` is already in `.gitignore`,
so they never risked being committed — but they should not accumulate. Worth adding a
`waspflow doctor` note if stale cores are found in the repo root.
