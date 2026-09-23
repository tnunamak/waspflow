# Codex lanes sat idle on Codex's "Update available" menu because the lane PATH found a stale duplicate binary

Observed 2026-09-23 by an orchestrator session.

- Three `waspflow spawn --provider codex` lanes never received their task. Two showed Codex's startup menu ("Update available! 0.154.0 -> 0.156.1 … 1. Update now / 2. Skip"). The third sat at an empty prompt. waspflow correctly refused to type into the startup menu (commit 23f3eca), and `revise` then failed with "no session_id … has it run a turn yet?". Nothing surfaced the stuck state until a manual `peek`.
- Root cause: this host had four Codex installs (mise 0.156.1, bun 0.154.0, nvm 0.142.4, plus a shell function that wraps tokensmash). The lane windows' environment resolved `codex` to the older bun copy, while the orchestrator's shell resolved the mise copy. Updating the bun copy (`bun install -g @openai/codex@0.156.1`) fixed it.
- Side effect worth knowing: an earlier data lane recorded "gpt-6-sol/luna not listed by `codex debug models`" because it ran 0.154.0, which predates those models. The orchestrator's 0.156.0 listed them. A version skew between the spawner's and the lane's binary produced a false catalog fact.

Suggested fixes:
1. At spawn, resolve the provider binary in the lane's environment and record its path and version in the lane record. Warn when it differs from the spawner's binary.
2. Detect provider startup menus (update prompts, trust gates) as a distinct lane state, e.g. `blocked:startup-menu`. Make `wait` and `list` report it, instead of the lane looking live and idle.
3. The spawn-time "task NOT confirmed submitted" warning also fired as a false negative on two of the three respawns, which were working. Same pattern as inbox/pdpp-spawn-confirmation-0918.md.
