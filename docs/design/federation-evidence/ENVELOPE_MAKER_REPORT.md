# Federation v0 envelope maker report

## Revision and outcome

- Base revision inspected: `718ab9e`.
- Implementation revision: recorded by the commit that includes this report.
- Outcome: a dependency-free, manually reviewable signed task-file-in/result-bundle-out envelope boundary is implemented in `lib/federation-envelope.mjs`, with the `bin/federation-envelope` CLI.

## Schema decisions

- Payload schemas are `waspflow.federation.task.v0` and `waspflow.federation.result.v0`. Their addresses are respectively `task:sha256:<payload-JCS-digest>` and `result:sha256:<payload-JCS-digest>`.
- RFC 8785 JCS UTF-8 bytes are SHA-256 hashed. Ed25519 signs `waspflow-federation/<kind>/v0\0` followed by the raw 32-byte digest. The signature is outside the payload, so identity is stable across signature transport.
- Both schemas require `oracle_ref`, `result_verdict`, and `settlement` to be present and `null`. This makes v1 a field-fill only, not a payload-shape rewrite.
- `source.base_revision` is optional signed display metadata. It is never used to validate source contents; `source.base_artifact.sha256` plus byte length is authoritative for the source artifact.
- Tasks have a simple `network: "enabled"|"disabled"` declaration, consistent with the scope steer. VM/container/devcontainer/mount/privileged/network-rule and related executor-policy fields are rejected, never ignored.
- A result binds the task address directly. It contains no evaluator callback, author credential, or oracle execution requirement. Therefore an author-side v1 re-verifier consumes the task/result/artifact identities after submission; it need not alter executor signing, submission, or result parsing. This is the concrete no-executor-to-author coupling proof requested by scope item 2.

## Changed files

- `lib/federation-envelope.mjs` — JCS, strict parser, schema/limit validation, digest identity, Ed25519 signing/verification.
- `bin/federation-envelope` — offline sign, verify, task/result handoff, and signed result-bundle commands; refuses symlink inputs and outputs.
- `tests/federation-envelope.test.mjs` — task/result golden digests, signature mutation, duplicate/noncanonical JSON, malformed UTF-8, reserved fields, prohibited executor controls, and symlink input tests.
- `docs/federation-envelope.md` — handoff contract and command examples.

## Commands and results

```text
node --test tests/federation-envelope.test.mjs
# 8 tests passed, 0 failed

node bin/federation-envelope --help
# exit 0; documents sign, verify, and handoff task/result commands

git diff --check
# exit 0
```

```text
bash scripts/verify.sh
# exit 0
```

## Compatibility seams and residuals

- Reserved slots are intentionally unused: no coordinator, escrow/ledger, oracle evaluator, or author re-verification logic was added.
- This component owns JSON and manual file handoff. It has no archive extractor or candidate patch applier, so path traversal/hardlink/archive symlink extraction tests correctly remain with the forthcoming runner/artifact inspector. It does reject symlink envelope/key inputs to prevent a review-time file indirection.
- The JCS implementation relies on Node 20's ECMAScript JSON number serialization, as RFC 8785 specifies. Schemas only admit bounded integer numeric fields, avoiding cross-runtime decimal ambiguity.
- No web research was performed: the local v0 scope, v2 B.2/B.3.4, and critique supplied the necessary contract.

## Confidence

High for the bounded file-envelope contract (focused happy-path and hostile-input coverage pass). Medium for interoperability with non-Node JCS implementations until an external cross-language vector suite is added; the v0 schema's integer-only numeric surface reduces that risk.
