# Federation v0 scope decisions (owner steer, 2026-07-18)

Supersedes conflicting scope in `FEDERATION_DESIGN_V2.md` for the FIRST CUT.
Governing principle (Tim): **build only what the final system keeps; defer anything
that can be added later WITHOUT undoing earlier work.** Prefer paying a known future
cost now (so we never migrate) over building a throwaway.

## KEEP in v0 (final-system components, built now)
- **Firecracker microVM runner.** We know the final system uses it; never start on
  something we'd have to migrate off. Build-order #1, with its adversarial fixtures.
- **Owner-gateway credential substrate** — scoped/revocable keys, host-side injector,
  key never in the VM. This is permanent.
- **Signed content-addressed task/result envelope.** Permanent identity/format. It
  MUST already carry the (v0-unused) hooks for later verification — an optional
  oracle reference and a result-verdict slot — so adding verification later fills
  fields, not reshapes the format. This is the one place "defer" must not mean "omit
  from the schema."
- **Open-harness scope EXPANDED.** In scope: any harness the gateway can back —
  including Claude Code / Codex CLI pointed at OTHER models via the gateway (tools
  exist for this). They just never touch their native provider APIs. Substrate is
  "harness + gateway," not "harness + its own provider." Pi is still the first adapter.

## DEFER in v0 (cleanly additive later — build nothing now)
- **Escrow / credit / settlement ledger.** Purely additive; building it now is
  premature. The envelope may reserve an optional settlement block, but no ledger,
  no escrow state machine, no attempt-compensation in v0.
- **Author-side re-verification / adversarial result trust.** None in the first cut.
  The author REVIEWS returned work manually, like a PR; trust is social
  (friends-and-family on the owner's gateway). Safe to defer ONLY because the
  envelope keeps the verification hooks (above) — confirm before building that
  adding re-verify later touches no other component.
- **Redundant execution, stranger tier, mesh, macOS executors, private repos.**
  All later, each behind its own threat-model delta.

## CORRECTED from v2 (owner steer changes these)
- **Network: tasks NEED internet; the boundary is host/LAN, not the internet.**
  v2's "no direct network" was too strict — most tasks are useless without egress.
  v0 rule: a task declares network on/off; most will be on. If per-task control is
  impractical, network is ALLOWED by default and that is DOCUMENTED, not silently
  assumed. The sandbox still blocks HOST and LAN access (that's the real isolation
  the microVM provides). **Exfiltration is explicitly OUT of the v0 threat model** —
  an internet-connected task can POST the (non-sensitive) repo anywhere; accepted
  for the friends-and-family tier, revisited when strangers enter scope.
- **Re-verification is not a v0 requirement** (see Defer). v2's one-runner-two-
  directions still holds as the FINAL shape; v0 simply doesn't run the author
  direction.

## The v0 one-liner
A Firecracker microVM runs a friends-and-family task (any gateway-backed harness,
internet on, host/LAN off) against the author's gateway key; the author reviews the
returned branch manually. Signed content-addressed envelopes carry it, with unused
slots reserved for the verification and settlement layers that come later without a
rewrite.

## Must-confirm before building
1. The envelope schema reserves oracle-ref + verdict + settlement slots so
   verification/escrow are later field-fills, not format changes. (If any of these
   would require reshaping the envelope, it must be designed in NOW even if unused.)
2. Deferring re-verification touches no other v0 component — verify by tracing the
   one-runner-two-directions dependency; if the executor-side flow assumes an
   author-side counterpart anywhere, that coupling is the thing to keep minimal now.
