# Moonlight Cloud Delete Compatibility Plan

## Goal

Allow every user to delete local Moonlight hosts and profiles without depending on Huawei Cloud Space availability, while preserving durable cross-device deletion and compatibility with device-local data and pre-Moonlight releases.

## Invariants

1. Local CRUD never depends on account login, Cloud Space activation, network, bootstrap or optional-table registration.
2. A cloud-selected local delete writes durable payload-free tombstones and a mutation journal before UI success.
3. Cloud recovery promotes pending tombstones only after the existing cloud-first barrier, so stale cloud rows cannot resurrect deleted data.
4. Explicit whole-cloud deletion remains strict and checkpointed.
5. Account leases, owner isolation, secure identities and device-local pairing material retain their current safety boundaries.
6. Legacy selections and databases are upgraded additively; no missing cloud capability causes local rows to be cleared.

## Steps

1. Add tests for durable-selected/runtime-unavailable ordinary deletion, strict cloud-wide deletion, checkpoint recovery and mixed deletion behavior.
2. Separate ordinary local-first delete admission from cloud-wide deletion admission in the command service.
3. Reuse durable tombstone/journal storage and schedule later promotion without weakening conflict epochs.
4. Make UI completion and batch behavior report local success with pending cloud work instead of exposing internal errors.
5. Run targeted tests, exact Hvigor gates, compliance checks and independent review.
