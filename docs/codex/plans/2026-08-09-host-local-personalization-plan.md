# Host Local Personalization Plan

## Objective

Separate device-dependent host personalization from synchronized host identity without changing the Huawei Cloud Space distributed-table contract or breaking 1.0.7/1.0.8 upgrades.

## Data Ownership

- Cloud base: host ID, protocol, label, endpoint, ports, account and credential references, group/order, relay/proxy/gateway topology and persisted trust material.
- Local override: display geometry/scaling, quality/FPS/codec preferences, input/touch/mouse behavior, device presentation choices and local health/recency state.
- Session-only: transient negotiated state, live latency, runtime errors and one-session overrides.

## Compatibility Strategy

1. Keep all existing cloud columns and decoders unchanged.
2. Use legacy cloud personalization as the read fallback when no override exists; create the override on the first local save, never during startup.
3. Persist later device-specific edits in a versioned device-local record keyed by host and protocol.
4. Merge local overrides after reading cloud/RDB rows.
5. When updating cloud base fields, preserve the legacy personalization already stored in the raw cloud-backed row instead of uploading another device's effective override.
6. For a new host, write a complete legacy-compatible cloud row once and seed the same values locally.
7. Treat missing/corrupt/unknown local records as optional and fall back safely; never gate login or cloud-table initialization on them.

## Implementation Steps

1. Audit RDP/RustDesk/SSH `RemoteHost` fields and the VNC host payload.
2. Select or add a device-local store that is excluded from distributed table registration.
3. Add pure ownership/merge/split policies and focused tests.
4. Integrate the policy at centralized host load/add/update boundaries.
5. Extend legacy upgrade fixtures for 1.0.7, early 1.0.8, missing overrides, malformed overrides and mixed old/new writers.
6. Run static checks, mandatory Hvigor gates and device upgrade/isolation acceptance.

## Acceptance

- Upgrading an old local database opens normally and retains all hosts.
- Login and cloud initialization do not depend on local override migration.
- A second device receives host identity but not the first device's later display/input tuning.
- Existing legacy clients continue to decode cloud rows and retain the last compatible legacy values.
- A malformed local override cannot make a host disappear or block application startup.
