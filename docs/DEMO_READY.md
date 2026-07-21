# DEMO READY — Waspflow Federation (Oshin demo)

**Status: FINAL — verified 2026-07-21 late evening. The rig is live and idle, waiting for the demo.**

## Open this in your browser (Oshin's app, live from her VM)
```
http://127.0.0.1:8902/?token=6SQWJBu4P3um1HvNNfjUCcfaKBy4I3EHGNK1QTUo0fs
```
You should see: **Idle / Ready to contribute** · "You're helping: http://10.0.2.2:9099" ·
"You've completed 0 tasks this week" · a **Choose a task** card with two queued tasks.

## The demo (3 beats; full script: docs/UAT_AND_DEMO_RUNBOOK.md part 2)
1. **"This is everything you'd ever do"** — the app, the safety panel ("Everything else is
   blocked…"), the story of join-by-invite and the pending→approved auto-flip.
2. **"Pick a task, or let it pick"** — click **Contribute this**. A one-time
   **"Sign in to Docker"** button appears with a confirmation code — click it (your real browser
   has your Docker session), confirm the code, the page continues automatically. Then the
   provider sign-in button (spare sub), same pattern. Then the task runs in a real sandboxed
   microVM on "her" machine.
3. **"And you get thanked"** — the requester lifecycle (Submit panel) reaches settled; her
   ledger ticks to "You've completed 1 task this week."

Sign-in note: each Contribute click generates a fresh confirmation code — nothing goes stale.

## What you click (the ONLY human actions; identical to Oshin's real experience)
1. **Sign in to Docker** (once) — the in-UI button + code confirm. ~15 s.
2. **Provider sign-in** (once) — the in-UI button, your spare subscription. ~20 s.
That's it. I attempted both autonomously; they require your logged-in browser sessions, which only
your real browser has. Both are the product's own designed flow, not workarounds.

## PROVEN tonight (live in a real browser, not claimed)
- Full journey to the sign-in gate: idle view, personalized "You're helping", ledger, task list,
  choose-a-task, accordion persistence, pending_approval → idle auto-flip (observed 3×).
- **The "Sign in to Docker" button rendering live with its confirmation code** — the one-click
  auth chain (auto-start sbx daemon → drive device flow → button → auto-continue) end-to-end.
- Suite: **226 tests, 0 failures** on `waspflow/fedgui-e2e` @ `df8c3bd` (pushed).
- Automated browser sweep (Playwright lane): all reachable checks PASS; screenshots in
  `test-artifacts/federation-ui/`. Report: docs/design/FEDERATION_UITEST_REPORT.md.

## Bugs found & FIXED during tonight's autonomous hardening (each verified live)
1. **Socket-path 104-char limit**: the default federation sbx home broke `sbx daemon start` for
   virtually every username. Default now `~/.wfsbx` + a `socket_path_length` doctor check.
   (This would have hit the real Oshin on day one.)
2. **Docker sign-in unreachable**: the device-flow drive required `docker_login` to be the *sole*
   failing check, but the policy check always co-fails pre-auth. Fixed the gate; button now
   surfaces correctly (verified in browser).
3. **Raw CLI output in the setup card**: replaced with one-line plain-language details.

## Still true / tomorrow's work (the "real thing" promise)
- Packaging artifacts exist (`packaging/`: nfpm deb/rpm, brew formula, winget skeleton, systemd/
  autostart, bundled clawmeter+tray) — tomorrow = build + publish (apt repo plan documented) +
  the platform-floor check for Oshin's actual machine (macOS: Apple Silicon + macOS 26 · Windows:
  Win11 + installer-absorbed HypervisorPlatform · Linux: Ubuntu 24.04+/KVM).
- Windows verdict: code is port-ready; needs the signed installer + one live Win11 smoke.

## If anything looks wrong
- Coordinator: `curl -s http://127.0.0.1:9099/tasks -H "authorization: Bearer oshin-invite-7clzi-test" | head -c 80` (JSON = fine)
- UI down: re-forward: `ssh -f -i ~/.tmp/oshin-vm/id_oshin -p 2222 -o StrictHostKeyChecking=no -N -L 127.0.0.1:8902:127.0.0.1:4242 oshin@localhost`
- Daemon restart (VM): `ssh -i ~/.tmp/oshin-vm/id_oshin -p 2222 oshin@localhost 'pkill -f "federation daemon"; cd ~/waspflow && setsid nohup node bin/waspflow-federation daemon --port 4242 >~/fedd.log 2>&1 & sleep 3; cat ~/.waspflow/federation/daemon.json'` → new token → new URL.
- Full troubleshooting: docs/UAT_AND_DEMO_RUNBOOK.md part 1.
