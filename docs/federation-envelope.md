# Federation v0 envelope handoff

`bin/federation-envelope` is a deliberately small, offline task-file-in/result-bundle-out boundary. It does not start a runner, schedule work, retrieve artifacts, evaluate an oracle, or settle anything.

Payloads are RFC 8785 JCS JSON. Their SHA-256 digest is the only identity:
`task:sha256:<digest>` or `result:sha256:<digest>`. `base_revision` is optional display metadata and never participates as a source identity. An Ed25519 signature covers `waspflow-federation/<kind>/v0\0` followed by the raw 32-byte payload digest, preventing task/result signature substitution.

Task and result payloads must include these future seams exactly as `null`: `oracle_ref`, `result_verdict`, and `settlement`. v1 can populate those slots without changing the signed payload shape. A result binds only the task digest and executor candidate; no author evaluator appears in the executor handoff, so adding author-side re-verification later adds a consumer of the same immutable references rather than a dependency from executor submission to author evaluation.

```sh
# generate an Ed25519 key with your normal key-management tooling
bin/federation-envelope sign task --payload task.payload.json --private-key author-private.pem \
  --key-id author-2026 --out task.envelope.json
bin/federation-envelope handoff task --task task.envelope.json --author-key author-public.pem

bin/federation-envelope sign result --payload result.payload.json --private-key executor-private.pem \
  --key-id executor-2026 --out result.envelope.json
bin/federation-envelope bundle result --result result.envelope.json --candidate candidate.patch \
  --executor-key executor-public.pem --out returned-result
bin/federation-envelope handoff result --task task.envelope.json --author-key author-public.pem \
  --result result.envelope.json --executor-key executor-public.pem
```

`bundle result` writes `result.envelope.json` and `artifacts/<candidate-sha256>` after checking the candidate's signed SHA-256 and byte length. It refuses symlink inputs and destination symlinks; candidate archive extraction remains a Firecracker runner responsibility.

The parser rejects duplicate/non-canonical JSON, unknown fields, expiry, invalid UTF-8, oversized values, invalid signatures, and task-provided VM/container/devcontainer/mount/privileged/network-rule controls. It also refuses symlink inputs, so manual reviewers can validate only ordinary files. Artifact retrieval and archive extraction remain runner responsibilities; every referenced artifact carries SHA-256, byte length, and media type.
