# MCP adapter (planned)

waspflow's engine (`lib/`) is interface-agnostic. The CLI (`bin/waspflow`) is one
face; an MCP server is a future second face exposing the same verbs as native
tools so an orchestrating agent can call them without shelling out.

Planned tool surface (thin wrappers over the existing scripts — no new logic):

| MCP tool | Wraps |
|---|---|
| `orchestrate_spawn` `{provider, lane, task, model?, cwd?, isolate?}` | `waspflow spawn` |
| `orchestrate_list` | `waspflow list` (structured) |
| `orchestrate_status` `{lane}` | `waspflow status` (JSON passthrough) |
| `orchestrate_peek` `{lane, lines?}` | `waspflow peek` |
| `orchestrate_wait` `{lane, timeout?}` | `waspflow wait` |
| `orchestrate_revise` `{lane, message}` | `waspflow revise` (returns reply) |
| `orchestrate_reap` `{lane, force?}` | `waspflow reap` |

Design rule: the MCP server SHALL contain no orchestration logic of its own — it
parses arguments, invokes the engine, and serializes results. Anything the MCP
face can do, the CLI can already do, and vice versa (parity).

Prior art to evaluate before building: Maniple
(github.com/Martian-Engineering/maniple) — an MCP tmux orchestrator supporting
Claude + Codex. Adopt only if it preserves waspflow's lane-state + worktree
contract; otherwise keep the in-house engine and add a slim MCP shim.

Not yet implemented.
