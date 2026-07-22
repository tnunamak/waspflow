# Federation coordinator deployment

The local contributor daemon listens only on `127.0.0.1`; remote members must
be able to reach the collective coordinator instead. Most operators should use
`waspflow federation host`, which creates its private state, starts the
coordinator as a systemd user service on packaged Linux, and prints an invite.
Its guided choices are a ngrok tunnel, an operator-managed HTTPS reverse
proxy, or a local-network address.

ngrok needs only the operator’s free account/authtoken; members do not need
accounts or domains. The current free plan provides one automatically assigned
development domain, not a custom reserved name. For a reverse proxy, give host
the final HTTPS origin with `--tunnel url:https://collective.example`; it keeps
the coordinator loopback-only. For a private tailnet, use the same option with
the tailnet HTTPS origin, or use `--tunnel lan` for an ordinary LAN.

Give members the printed `waspflow://join?...` invite, not a separately copied
URL and token. Do not publish an unauthenticated coordinator directly to the
public internet: its bearer token and roster remain part of the collective's
trust boundary.
