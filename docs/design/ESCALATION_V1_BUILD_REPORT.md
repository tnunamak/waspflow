# Escalation v1 build report

Status: implemented and verified on 2026-07-15.

## What shipped

- `waspflow escalate <lane>` with typed `--to`, `--handoff`, isolated-lane
  `--reset-tree`, `--force`, `--ack-deprecated`, `--note`, transition recovery,
  and machine-readable results for success, refusal, selection-required, and
  attempted-launch failure.
- A phased, operation-lock-held transition journal:
  `prepared -> receipt_committed -> launch_provisioned -> confirmed`. The target
  and mode are immutable after preparation. Commit uses the new state-lock CAS
  primitive on `(arm_generation, session_id)`.
- Provisional replacement-window ownership for all providers. The lane continues
  to own its old session/window until provider-specific submission confirmation
  succeeds; abort removes the provisional window and opens a fresh same-arm
  segment.
- `*_resume_with_arm` for Claude, Codex, and Grok. They carry the target model
  and effort explicitly, including the Claude effort propagation fix and Codex's
  `model_reasoning_effort` setting.
- Effective op ladders with `fallback_ladder` precedence, structural no-op edge
  warnings, persisted cursor advancement, runtime current-arm distinctness, and
  exit 5 for bare/exhausted selection.
- Segment receipts (`receipt_kind: "lane_segment"`) that are exactly-once on
  `(lane_uuid, segment.index)`, per-segment wall attribution, rotated verify
  evidence, poison accounting, and a reap-time `receipt_kind: "lane"` receipt
  with the final `{index:<last>, closed_by:"reap"}` segment and
  `escalation_path`. Never-escalated legacy lanes retain `segment: null`.
- A deliberately bounded escalation prompt containing capped task/verify/diff
  evidence, identity, attempts, attribution warning, untrusted-data delimiters,
  and the required anti-gaming line.
- CAS-protected Codex runtime refresh writes and wait-loop provider reloads.

`SCHEMAS_V1.md`, README, CLI usage, and the skill now describe the segment receipt
compatibility rule and the revise-versus-escalate distinction.

## Crash and recovery matrix

The integration test uses a stubbed Codex adapter and a private tmux socket. It
asserts these semantic outcomes:

| Boundary | Recovery result |
|---|---|
| `prepared` | Resume emits exactly one closing segment receipt. |
| `receipt_committed` | Resume skips the already durable receipt. |
| `launch_provisioned` | Abort kills the exact provisional ownership, records `aborted`, and rotates to a same-arm segment. |
| `confirmed` | Resume adopts the journaled provisional session without launching again. |
| provider launch failure | Exit 2, `status=escalate_failed`, and the old arm/generation remain unchanged. |

The suite also pins immutable-target retry refusal, busy wait/revise/park/reap
refusals, stale CAS rejection, poisoned-context reset paths, reset-tree behavior,
receipt-kind consumer compatibility, prompt guardrails, and `--json` value
semantics.

## Stubbed end-to-end transcripts

Representative lines from the watched integration run:

```text
waspflow: escalate: arm switched to codex/target/high
waspflow: escalate: transition aborted; old arm remains live
waspflow: escalate: arm switched to codex/other/high
waspflow: reap: lane 'esc-success' reaped — result=verify_failed
waspflow verify: ok
```

The first transition asserted the segment receipt kind, arm update, and replacement
window adoption. The abort line came from a crash after provisional launch; the
confirmed-phase retry asserted no second provider launch. The final reap assertion
checked a `receipt_kind: "lane"` row whose closing segment matches the persisted
final segment index and whose escalation path is populated. A separate legacy-row
assertion pins `segment: null` for a lane that never escalated.

## Verification

```text
$ scripts/verify.sh
...
waspflow verify: ok
exit code: 0
```

Also run successfully: `bash -n` over every touched shell file and `git diff --check`.

## Corrective follow-up

An independent live Codex escalation found that the final lane row had
`segment: null`, losing final-arm attribution despite a correct escalation
segment receipt. The final receipt builder now derives the reap-closing segment
only when durable state shows an escalation boundary (`segment_index > 0` or a
non-empty `arm_history`); it leaves legacy lanes unchanged. The full verifier
was rerun after this correction before the amended commit.

## Final review disposition

| Finding | Disposition | Evidence added |
|---|---|---|
| P0-1: `launch_provisioned` recovery | Fixed. Provisional window, session placeholder, and transition-tagged process-scope receipts are journaled before submission. Resume first confirms that journaled session; an unconfirmed attempted launch is killed and re-provisioned before retry. | Resume from `launch_provisioned` asserts no provider run before journaling, exactly one subsequent launch, then commit. |
| P0-2: reap across committed transition | Fixed. Reap refuses every pending phase from `receipt_committed` onward and prints the exact resume/abort escapes. | `escalate_failed` plus `receipt_committed` reap refusal test. |
| P1-3: immutable retry and abort durability | Fixed. Explicit resume compares any supplied target/mode with the immutable target; bare retry refuses. Abort is one CAS state update after cleanup. | Different `--to`, bare retry, and crash-after-abort-cleanup retry tests. |
| P1-4: provisional descendant cleanup | Fixed. Scope receipts carry `execution: escalation:<transition-id>` and abort/relaunch kills the exact owned window and each bound scope. | Abort test asserts both window absence and that the recorded scope invocation is no longer live. |
| P1-5: Claude confirmation identity | Fixed. Claude verifies the provisional/new SID and the per-transition nonce rather than an old lane SID or prompt prefix. | Unstubbed stale-nonce rejection plus fresh-SID acceptance test; all provider argv tests retain model and effort assertions. |
| P1-6: duplicate segment repair | Fixed. Duplicate append recovery reads the existing durable row and uses its receipt id for the local receipt and state marker. | Durable receipt id repair assertion. |
| P1-7: legacy receipt compatibility | Fixed. Legacy segment-zero lane timestamps omit `segment_started_epoch` entirely. | Exact legacy timestamp-key-set assertion. |
| P1-8: prompt evidence | Fixed. Verify output is read separately for head and tail, and prompt paths name the `.txt` logs and JSON result actually written. | Cap, head/tail, identity/nonce, untrusted delimiter, and pointer assertions. |
| P1-9: acceptance coverage and proposal | Fixed. The suite covers matrix rows, post-append recovery, launch resume, refresh interleave, provider identity, ladder/no-op/collision behavior, and JSON/plain proposal output. Verify now emits `next: <op> -> <arm> [quota ...]; alternatives: ...`. | Semantic integration assertions in `scripts/verify.sh`. |

During reproduction, the new tests also exposed and corrected three implementation
defects before this final run: jq's `false // true` would relaunch a merely
journaled provisional session; the launch-boundary crash code was being converted
to an attempt failure; and default ladder selection evaluated target availability
before loading the target provider. The final watched suite covers all three.

## Deviations and confidence

There are no intentional functional deviations from the Round 2 outcome. The
`WASPFLOW_ESCALATION_TEST_CRASH_AFTER` hook exists solely to make phase-boundary
crash recovery deterministic in the hermetic verifier; ordinary users never set it.

The automated coverage is intentionally strongest at durability and transition
boundaries; it does not exercise paid, live-provider account state. In particular,
the provider tests pin composed argv and confirmation seams rather than executing a
real Claude/Codex/Grok TUI. That remains the only material validation gap.

Confidence is high for the state machine, receipt durability, and CLI contract under
the stubbed provider evidence. Confidence is moderate for provider-specific live TUI
behavior: the exact argv and submission-oracle seams are tested, but this build did
not consume real Claude/Codex/Grok accounts during verification. Operators should
still validate a real interactive resume on each locally installed CLI version before
depending on it for a production incident.
