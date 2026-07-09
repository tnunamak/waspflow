# Operating points (the `--op` doctrine)

`waspflow ops` is a **resolver, not a picker**: it expands a task-shaped operating
point into explicit `--provider/--model/--effort` flags and prints a decision card
(frontier, evidence, escalate path). Raw flags always remain canonical and win over
any `--op` expansion.

```bash
waspflow ops list --task implementation --constraint balanced
waspflow ops explain implement.standard
waspflow ops resolve review.audit --json
waspflow spawn --op implement.standard --lane fix -- "Implement …"
# explicit overrides always win:
waspflow spawn --op implement.standard --provider codex --effort xhigh --lane fix -- "…"
```

**Do not** invent a `cheap|default|max` ladder or silently auto-route models.

Doctrine:

1. Pick **task family** first (implement / review / recover / fanout / advisor / ui / docs).
2. Pick **constraint** second (balanced / quota-tight / dollar-tight / …).
3. Resolve to an explicit operating point; read the decision card (frontier, evidence, escalate path).
4. Check **quota** (clawmeter) separately from **API dollars** (tokensmash) — never merge without an explicit exchange rate.
5. Prefer non-dominated points with adequate evidence; escalate after failed verification, not by default.
6. Do **not** use providers with **missing** quality evidence for high-risk work unless the user opts into exploration (`grok.explore-only`).
7. Log/record catalog + policy versions when available; raw `--provider/--model/--effort` remains canonical.
8. Effort is pass-through: never silently demote (Codex `xhigh` is real; do not clamp to `high`).
