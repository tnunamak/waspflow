# Federation sandbox socket-path fix

## Problem

Docker Sandboxes builds its containerd socket below the configured `HOME`.
The former Federation default, `~/.waspflow/sbx-home`, can make that Unix
socket path longer than the 104-character system limit. The daemon then fails
before a contributor can complete first-time setup.

## Change

Federation now defaults to `~/.wfsbx`. Docker Sandboxes appends 75 characters
to this home path, so the complete socket path is checked against the
104-character limit during `waspflow federation doctor` and contribution
preflight.

`WASPFLOW_FEDERATION_SBX_HOME` still overrides the default. If the former home
exists while the new one does not, Federation keeps using it only when its
complete socket path fits. If it does not fit, Federation prints one concise
note and uses the new home instead.

No data is moved automatically. The old directory contains re-creatable sbx
authentication and state, and silent relocation could make that state appear
lost or change an existing user's active profile unexpectedly.

## Verification

Focused tests cover the short default and override, legacy-home selection,
and socket-path pass/fail boundaries. `node --test tests/*.test.mjs` passed:
225 tests passed, with one intentional live-integration skip.
