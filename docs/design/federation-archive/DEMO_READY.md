# DEMO READY — Waspflow Federation (FULL LOOP PROVEN)

**Status: FINAL. The complete federated loop has RUN FOR REAL tonight** — claim → signed
verification → sandboxed microVM → Claude executed the task → signed result → settled →
requester fetched the artifact → ledger ticked. Verified by inspecting the actual result:
the README contains the exact line the task requested ("Contributed via Waspflow Federation.").

## The demo URL (verified end-to-end through this exact URL)
```
http://192.168.1.180:8904/?token=K_21o5zSNX4Z_WInTGgz1FgBS_2qlfoff38Q0yD4NXM
```
Current screen: **Idle / Ready to contribute** · "You've completed 1 task this week"
(`the-real-one` — tonight's proven run) · one clean claimable task: **fix-the-login-page**.

## The 1-tap demo (everything is pre-authed now — zero interruptions)
Tap **Contribute this** on `fix-the-login-page` → ~30 seconds of "Contributing" →
**"Contribution finished"** → ledger ticks to 2. A real Claude agent in a real sandboxed
microVM does the work. Tell the sign-in story verbally (you did both one-click flows tonight —
Docker device-confirm + they're one-time).
To re-run the demo: submit another task (Submit panel or the CLI line in the runbook) and tap again.

## What tonight's autonomous loop found & fixed (each verified live, all pushed @ 9841257, suite 226/226)
1. **Socket-path 104-char limit** — default sbx home broke `sbx daemon` for ~every username → `~/.wfsbx` + doctor check.
2. **Docker sign-in button unreachable** — drive gated on docker_login being the sole failure; policy always co-fails pre-auth → gate fixed.
3. **Raw CLI dumps in the setup card** → plain one-line copy.
4. **Sandbox-readiness race** — `sbx run --detached` returns before the microVM is exec-able → readiness wait.
5. **kvm_access false negative** — ACL-granted hosts blocked by a lying `test -r` probe → judge by sbx's own diagnostic.
6. **THE loop-killer: split-brain sbx identity** — the auth flow resolved a different sbx HOME than the backend, so login execs targeted the personal daemon ("no sandbox named…") → one resolver, one identity.
Also: test data was leaking into the real ledger (cleaned; test-isolation fix queued), and the daemon
swallows the contribute child's stderr on failure (fix queued — detail should carry the last error line).

## Known open items (post-demo)
- Which subscription the sandboxed Claude billed (auth passed via sbx's account-level secret
  provisioning — confirm the account path before promising Oshin whose quota is used).
- VM/nested-virt: sbx exec output-streaming is unstable under nested KVM (sandbox VMs die on first
  real exec) — fine for real machines, breaks VM-based contributors; documented, not our bug.
- Daemon stderr surfacing, test-ledger isolation, packaging publication (artifacts exist in
  `packaging/`), platform floors before any real-Oshin promise (Apple Silicon+macOS 26 / Win11 /
  Ubuntu 24.04+KVM).

## Rig components (all running)
coordinator :9099 (fresh queue, data2) · host daemon systemd `wf-fed-daemon` :4243 · LAN proxy :8904 ·
sbx identity `~/.wfsbx` (Docker: timodl, authed; policy: balanced). VM rig retired for execution
(nested-virt limit) — it proved join/UI/auth flows.
Health: `curl -s http://127.0.0.1:9099/tasks -H "authorization: Bearer oshin-invite-7clzi-test"` +
reload the demo URL. Daemon restart rotates the token — re-read `~/.waspflow/federation/daemon.json`.
