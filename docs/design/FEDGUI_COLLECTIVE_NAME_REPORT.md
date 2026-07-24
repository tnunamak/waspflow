# Federation collective names

## Result

`waspflow federation host` now stores one collective name. It asks only when the host configuration has no name.
It uses `<user>'s collective` when input is unavailable or empty. A re-host keeps the stored name.

The coordinator writes the name to its local status file. Its existing authenticated `GET /roster` response also includes the name.
The join flow already reads that response. It now saves the name into the active member configuration and membership record.

The change does not add an endpoint or change authorization, envelopes, sandboxing, or the contribution loop.

The UI uses the name in the collective list, pending approval, and the contribution `Collective:` line. Without a name, it shows only the hostname.
For example, `http://192.168.1.7:37257` displays as `192.168.1.7`. It never shows the scheme or port.

The members list now omits an unavailable join date. The style removes the collective-row action margin.

## LOC accounting

Authored source and test delta: **+72 / -21 lines**. The Vite rebuild changed `public/app.mjs` by **+175 / -162 lines**.

| Addition | Lines | Why it exists |
| --- | ---: | --- |
| Host name persistence and one prompt | +14 / -1 | Stores the only new product state. Preserves an existing name on re-host. |
| Coordinator status and roster field | +6 / -5 | Reuses the existing authenticated response that join already reads. |
| Join capture | +2 / -1 | Copies a nonempty coordinator name into the active membership. |
| UI display helper and usage | +11 / -5 | One helper prevents four inconsistent raw-URL fallbacks. |
| Focused tests and browser fixture | +38 / -8 | Proves host persistence, host-to-member propagation, safe fallback, and rendered UI. |
| Style adjustment | +1 / -1 | Removes the active-row spacing artifact. |

## Validation

Passed:

```text
cd ui && npm run build
cd ui && npm test
node --test --test-timeout=60000 tests/*.test.mjs
```

The Node suite reported 293 passing tests and zero failures.

An independent diff and oracle review passed. It checked the host, coordinator status, roster response, join persistence, and all three UI surfaces.

The Playwright journey also passed. It ran against a disposable loopback coordinator and member, not the approved LAN collective.
The browser test checked a named row and contribution line, a name-less hostname fallback, and the absence of `http://192.168.1.7:37257` in both screens.

Screenshot: [named collective UI](../../test-artifacts/federation-ui/named-collective.png)

The test stopped the disposable coordinator and daemon. The live `http://192.168.1.7:37257` collective and its membership were not changed.

## Confidence and remaining gap

Confidence is high for new joins. The focused integration test proves host name to authenticated roster response to member configuration.

An existing name-less membership displays its safe hostname immediately. It receives the stored coordinator name on its next normal roster refresh, such as join, rejoin, contribute, or submit.
The daemon passive approval poll does not write the coordinator name to configuration. This avoids a new background state-write behavior.
