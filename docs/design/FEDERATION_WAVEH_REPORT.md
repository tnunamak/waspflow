# Federation Wave H report

Date: 2026-07-22

## Delivered

- Claude’s harness now uses the locally probed `claude --print --verbose --output-format stream-json` mode. The sandbox execution edge forwards stdout/stderr while it runs; the pull and guided CLI preserve provider events separately from Federation progress.
- The daemon writes the raw provider stream incrementally to owner-only `logs/<digest>.transcript.jsonl`, capped at 2 MiB. The prior bounded wrapper log remains available. `GET /tasks/:digest/log?since=<offset>` is token-gated and returns incremental bytes plus `next_offset`.
- Task detail renders a readable Transcript with assistant/event badges and collapsed tool entries. A Raw JSON toggle remains available. Running selected tasks tail the transcript, and the Contribute card links to **Watch live**.
- Receipt parsing accepts Claude’s final stream `result` event while retaining compatibility with the old single JSON result. Codex already emits JSONL; Gemini retains its native structured stdout where available.
- Requests now accept browser file or folder selection (base64 JSON transport, 20 MiB decoded cap), materialize attachments into a temporary task source, and retain the advanced local-folder path. The form includes the requested attachment, public-GitHub, network, and human-name copy. Network maps to `--network enabled|disabled`.
- Coordinator `GET /activity` exposes only shared task lifecycle/attribution. Activity has a Collective feed; private local receipts and transcripts remain local.
- Settings is split into **This machine** and **Your collective**, with the owner, connection, roster, and explicit operator-only-management limitation.

## Verification

- `node --test --test-reporter=dot tests/*.test.mjs` passed (236 Node tests). Together with the repository’s 21 shell checks, this is the requested 257-test base.
- `bash scripts/verify.sh` completed successfully.
- Focused additions cover coordinator activity, Claude stream receipt parsing, stream persistence with offset tails, harness flags, submission network argument, and UI copy/controls.
- The live browser journey passed all 12 checks against the restarted local daemon on port 4243 with no console errors. Screenshots: [settings](../../test-artifacts/federation-ui/activity-settings.png) and [transcript](../../test-artifacts/federation-ui/transcript.png).
- `git diff --check` passed.

## Operational state and confidence

`wf-fed-daemon.service` was restarted from this worktree. Its graceful stop was blocked by a stale `sbx exec` probe, so only that service cgroup was SIGKILLed before starting the same unit again. The live coordinator was also refreshed from this worktree because its prior process lacked the new `/activity` endpoint; `GET /activity` then returned the expected task-level records.

Confidence is high for the tested persistence, offset, API, form, and rendering contracts. Claude’s exact stream flag combination was verified from the installed CLI help and covered by parser/UI fixtures; this Wave H pass did not start a fresh billable provider task solely to manufacture a production transcript.
