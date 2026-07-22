# Federation coordinator deployment

The local contributor daemon listens only on `127.0.0.1`; remote members must
be able to reach the collective coordinator instead. The collective owner
chooses and operates that exposure. Common options are an internet-facing
reverse proxy with TLS in front of the coordinator, or a private tailnet where
only members can resolve and reach its address. Give members the resulting
HTTPS or tailnet coordinator URL in their invite. Do not publish an unauthenticated
coordinator directly to the public internet; its token and roster remain part
of the collective's trust boundary.
