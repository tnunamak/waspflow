# Tmux session-name collision corrupted resurrection identity

On 2026-08-30, a reboot restore placed many Waspflow lanes into unrelated
windows in the grouped `main` session. The restore followed a corrupt assistant
sidecar: 108 Waspflow entries had been serialized as `main:<index>`.

## Proven root cause

The local assistant-resurrect patch asked tmux for a session group with a bare
target:

```sh
tmux display-message -t "$session_name" -p '#{session_group}'
```

That target is not an exact session target. The production `main` session also
had a window named `waspflow`, so the bare target `waspflow` resolved to that
window (`session=main`, `group=main`) instead of the separate ungrouped
`waspflow` session. The saver then rewrote Waspflow pane addresses as
`main:<index>`.

The collision was reproduced directly:

- bare `waspflow` resolved to the `main` window named `waspflow`;
- exact `=waspflow:` resolved to the real `waspflow` session;
- reading `#{session_group}` from the same `list-panes` row preserved the real
  pane's session identity.

The tracked patch now takes `session_group` from the same pane enumeration row,
and an isolated-socket regression test creates both a session and an unrelated
window named `waspflow`.

## Waspflow invariant

Do not treat a tmux window index, title, or session-shaped bare target as an
identity receipt. A resumable lane receipt must bind the agent session ID to the
actual tmux session/window/pane identity captured in one observation. Restore
must fail closed when those identities conflict.

Related host incident:
`~/code/dotfiles/inbox/2026-08-30-tmux-recovery-incident.md`.
