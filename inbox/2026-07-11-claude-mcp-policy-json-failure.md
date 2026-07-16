# Claude MCP policy resolution emits invalid JSON

Observed on 2026-07-11 from Waspflow `main` while launching an independent
read-only checker:

```text
$ waspflow spawn --provider claude --model opus --effort high \
    --lane ri-fanin-opus-gate-0711 --report tmp/workstreams/gate.md -- "..."
jq: parse error: Invalid numeric literal at line 1, column 95
waspflow: claude: invalid MCP policy response
waspflow: claude: cannot resolve MCP policy 'auto'
```

The same failure occurs with explicit `--mcp none`; the final line changes to
`cannot resolve MCP policy 'none'`. This prevents all Claude lane launches even
when the caller explicitly requests no MCP servers. A direct
`claude -p --strict-mcp-config --no-session-persistence` invocation works, so
the defect is in Waspflow's MCP-policy response/JSON parsing path rather than
Claude authentication or model availability.

Expected behavior:

- `--mcp none` must not consult or parse an auto-policy response.
- `auto` policy output must be schema-validated before `jq` consumption and
  report the raw policy provider/error source without leaking credentials.
- Add a deterministic regression for malformed policy output and an explicit
  `none` bypass case.

No fix was attempted in the PDPP owner session; the checker used the direct
Claude fallback so this did not block the release gate.
