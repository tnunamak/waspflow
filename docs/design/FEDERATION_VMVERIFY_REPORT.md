# Federation VM verification report

Test date: 2026-07-21

Scope: Live verification of the integrated `bin/`, `lib/`, `public/`, and
`package.json` in the Oshin VM. This report does not change product code.

## Result matrix

| Check | Result | Evidence |
| --- | --- | --- |
| Deploy | PASS | `scp` copied the four requested paths. The VM ran Node `v20.20.2` and found `bin/waspflow-federation`. |
| Daemon up | PASS | I stopped the old daemon. A new daemon wrote `daemon.json` with PID `8684` and port `40209`. |
| Join | PASS | The reset VM joined with the supplied command. `/status` moved from `not_joined` to `idle`. |
| Tasks list | FAIL | `GET /tasks` returned HTTP 404 and `{"error":"not found"}`. |
| Choose contribute | PASS | `POST /contribute/start` accepted the selected raw digest and returned HTTP 202 with `started: true`. The flow then stopped at preflight. |
| Auth event shape | FAIL | No auth event occurred. The sandbox preflight returned `setup_required` before authentication. |
| Doctor | FAIL | Three of six checks failed: `sbx_daemon`, `network_policy`, and `docker_login`. |

## Journey evidence

The host port `9099` already had a Federation coordinator listener. The supplied
coordinator script uses the expected token and roster paths. I used that live
listener because a second coordinator cannot bind the same port.

The VM initially had a joined configuration. Its status payload was:

```json
{"schema_version":1,"type":"daemon_status","state":"idle","detail":"Ready to contribute.","coordinator_url":"http://10.0.2.2:9099"}
```

I removed `~/.waspflow/federation/config.json`. The next status payload was:

```json
{"schema_version":1,"type":"daemon_status","state":"not_joined","detail":"Not joined. Paste an invite to get started."}
```

I posted this invite to `/join`:

```text
waspflow federation join http://10.0.2.2:9099 oshin-invite-7clzi-test
```

The immediate response retained `state: "not_joined"` and added
`"started":true`. The second poll returned `idle` and the coordinator URL.
The saved configuration used key ID `oshin` and contained the roster entries
`oshin` and `tim-author`.

I submitted a task from the host with `bin/waspflow-federation-submit` and the
supplied `tim-author.pem`. Its digest was
`f2fafe4bc283aa3588bb8be6aa3d601a5ec0923687c67a6165742c85387ed007`.
Publishing succeeded. The command then timed out as intended after one second.
The task remained `QUEUED`.

The daemon task-list request failed:

```text
GET /tasks -> 404
{"error":"not found"}
```

The daemon validates `task_digest` as a raw 64-character value. It rejected
the `sha256:` form with this response:

```json
{"error":"task_digest must be a 64-character sha256 digest"}
```

The raw digest succeeded. The immediate contribution response was:

```json
{"schema_version":1,"type":"daemon_status","state":"contributing","detail":"Contribution is running.","coordinator_url":"http://10.0.2.2:9099","contribution":{"selection":"chosen","task_digest":"f2fafe4bc283aa3588bb8be6aa3d601a5ec0923687c67a6165742c85387ed007"},"started":true}
```

The first two polls remained `contributing`. The third poll returned
`setup_required`, not `action_needed` or `awaiting_browser`:

```json
{"schema_version":1,"type":"daemon_status","state":"setup_required","detail":"Your sandbox is not ready yet. Fix the failed checks before contributing again.","coordinator_url":"http://10.0.2.2:9099","action":{"kind":"sandbox_preflight","checks":[{"name":"sbx_daemon","ok":false},{"name":"network_policy","ok":false},{"name":"docker_login","ok":false}]},"contribution":{"selection":"chosen","task_digest":"f2fafe4bc283aa3588bb8be6aa3d601a5ec0923687c67a6165742c85387ed007"}}
```

The live API requires `X-Waspflow-Session-Token` or a `token` query parameter.
It rejected an `Authorization: Bearer` header with HTTP 401 and
`{"error":"missing or invalid daemon session token"}`.

## Doctor evidence

`node bin/waspflow-federation doctor --json` exited with this result state:

```json
{"status":"setup_required","backend_id":"docker-sbx","schema_version":1,"type":"sandbox_preflight"}
```

| Check | Result | Live detail |
| --- | --- | --- |
| `sbx_install` | PASS | `sbx version: v0.35.0`. |
| `docker_runtime` | PASS | Docker CE `29.6.2`. Containerd was `v2.2.6`. |
| `sbx_daemon` | FAIL | `sbx diagnose` reported that the daemon was not reachable. The expected socket did not exist. Suggested fix: `sbx daemon stop && sbx daemon start --detach && sbx diagnose`. |
| `network_policy` | FAIL | `sbx policy ls` returned `ERROR: Not authenticated to Docker`. Suggested fix: `sbx policy init balanced`. |
| `kvm_access` | PASS | `/dev/kvm` was readable and writable by `oshin`. |
| `docker_login` | FAIL | Doctor could not confirm Docker login because `sbx diagnose` failed. Suggested fix: `sbx login`. |

## Assessment

The deployment, daemon restart, reset-and-join path, and chosen-task start
worked. I cannot verify browser authentication because preflight blocks it.

The task-list failure is a direct API result. Confidence is high for that
observation. I cannot isolate the root cause in this lane. The host coordinator
came from the separate E2E checkout. The VM ran the integrated daemon.

The VM did not meet the stated sandbox-health expectation at test time. No
product fixes were made. The live daemon remains in `setup_required` after the
test.
