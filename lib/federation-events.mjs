/**
 * Source-of-truth schema for every structured (--json) event
 * `bin/waspflow-federation` can emit. A future GUI/tray consumer (or any
 * other programmatic caller) should import EVENT_TYPES from here rather
 * than hand-maintain its own copy of the vocabulary — this module and the
 * CLI's printResult() call sites are the only two places that need to
 * agree, and tests/federation-events-contract.test.mjs asserts they do.
 *
 * Discriminator: `type` (a `type` string, never `status`). `status` still
 * appears on most events (unchanged, existing field), but it is DOMAIN DATA,
 * not a safe discriminator: `contributed`'s spread of the underlying pull
 * bin's response overwrites `status` with the settle outcome ('settled'),
 * and `task_status`'s spread of the coordinator's task record overwrites
 * `status` with the task's own lifecycle state ('QUEUED'/'CLAIMED'/
 * 'SETTLED'/'EXPIRED'). `type` is merged in last by printResult() in
 * bin/waspflow-federation, so it can never be shadowed by spread data.
 *
 * SCHEMA_VERSION 1 is the shape documented here: every event above has
 * `schema_version` (integer) and `type` (string) in addition to its own
 * fields. Bumping the shape of any event (renaming/removing a required
 * field, changing a field's meaning) requires bumping SCHEMA_VERSION and
 * adding a new entry here — additive-only field additions do not require a
 * bump.
 */
'use strict';

export const SCHEMA_VERSION = 1;

// Each entry's `requiredFields` lists the event's OWN fields beyond the
// envelope fields every event carries (`schema_version`, `type`). Fields
// whose value is itself domain data with an open-ended shape (e.g.
// `task_status`'s spread of the coordinator's task record) are still
// listed by name — the schema asserts the field is present, not its
// internal shape.
export const EVENT_TYPES = {
  already_joined: {
    description: 'join: config already exists for this coordinator — no new keypair generated.',
    requiredFields: ['status', 'key_id', 'coordinator_url', 'config_path'],
  },
  joined: {
    description: 'join: a new keypair was generated and config persisted for the first time.',
    requiredFields: ['status', 'key_id', 'coordinator_url', 'config_path', 'peers_auto_fetched', 'roster_snippet', 'next_step'],
  },
  auth_required_manual: {
    description: 'contribute: the harness needs a one-time login this CLI cannot drive; the human must complete it out of band.',
    requiredFields: ['status', 'harness', 'flow_shape', 'instruction'],
  },
  awaiting_browser: {
    description: 'contribute: the harness auth flow produced a URL; waiting for the human to complete login in a browser.',
    requiredFields: ['status', 'harness', 'url'],
  },
  no_task_available: {
    description: 'contribute: no --task-digest given and the coordinator has nothing claimable right now.',
    requiredFields: ['status'],
  },
  contributed: {
    description: "contribute: the claimed task ran to completion and was submitted. Carries the underlying pull bin's own response spread in — including its own `status` field ('settled' on success), which is why `type` (not `status`) is the discriminator here.",
    requiredFields: ['status', 'task_digest'],
  },
  trusted: {
    description: 'trust: a peer public key was added to the local roster cache.',
    requiredFields: ['status', 'key_id'],
  },
  not_joined: {
    description: 'status (no args): no local config exists yet.',
    requiredFields: ['status'],
  },
  member_status: {
    description: 'status (no args): local config health for the already-joined member.',
    requiredFields: ['status', 'key_id', 'coordinator_url', 'config_path'],
  },
  task_status: {
    description: "status --task-digest: proxies the coordinator's task record. Carries the coordinator's own `status` field (the task's lifecycle state, e.g. 'QUEUED'/'CLAIMED'/'SETTLED') spread in — another reason `type` (not `status`) is the discriminator.",
    requiredFields: ['status', 'task_digest'],
  },
};

export function isKnownEventType(type) {
  return Object.prototype.hasOwnProperty.call(EVENT_TYPES, type);
}

// Validates a parsed --json event line against this source-of-truth schema:
// well-formed envelope (schema_version, known type) plus every required
// field for that type present (not asserting value types beyond presence,
// since some required fields are open-ended domain data spread in from
// elsewhere — see contributed/task_status above).
export function validateEvent(event) {
  const errors = [];
  if (!event || typeof event !== 'object') return ['event is not an object'];
  if (event.schema_version !== SCHEMA_VERSION) {
    errors.push(`schema_version must be ${SCHEMA_VERSION}, got ${JSON.stringify(event.schema_version)}`);
  }
  if (typeof event.type !== 'string' || !isKnownEventType(event.type)) {
    errors.push(`type must be one of ${Object.keys(EVENT_TYPES).join(', ')}, got ${JSON.stringify(event.type)}`);
    return errors; // can't check required fields against an unknown type
  }
  for (const field of EVENT_TYPES[event.type].requiredFields) {
    if (!Object.prototype.hasOwnProperty.call(event, field)) {
      errors.push(`event of type '${event.type}' is missing required field '${field}'`);
    }
  }
  return errors;
}
