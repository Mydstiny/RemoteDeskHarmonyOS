# Current Handoff

This is the short handoff for resuming the active task. Completed task
handoffs and historical evidence are preserved in
`docs/codex/archive/2026-08/HANDOFF-legacy.md`.

## Resume Card

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`.
- Base: 1.1.4 checkpoint `5a0e055159402fcdf50aeea91760d99e3c017f39` on `main@b84224869`.
- Reviewed checkpoints: blocker-remediation code `a1991db21cb657ec97338b7bdd02ae7aeb18235d`; SBOM `f59f31d95c4b2791b4c2ca35c981314bbc0df365`.
- Working tree: expected clean after the coordination-document commit; one worktree and no branch switch, stash or reset was used.
- Current phase: local IPv6 implementation, 1.1.5 release increment and full 1.1.4-baseline false-blocker remediation complete; real-device and fixed-server topology acceptance remains pending.
- Review: PASS from `/root/ipv6_blocker_review_retry` for `5a0e05515..a1991db21`, followed by a metadata-only review of `f59f31d9`; findings P0=0, P1=0, P2=0 and P3=0.
- Fixed regressions: active-route-only optional-port validation, endpoint-I/O reachability instead of a global default-network veto, and active-protocol-only NAPI field parsing.
- Preserved boundaries: certificate/trust, account scope, plaintext consent, Moonlight runtime/release gates and RustDesk unreleased transport/capability gates.
- Device blocker: both available `hdc list targets` commands returned no target, so no current real-device IPv6/AAAA-only/NAT64/VPN or fixed hbbs/hbbr evidence exists.

## Source Of Truth

- Machine state: `docs/codex/STATE.json`
- Review receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`
- Action queue: `docs/codex/QUEUE.md`
- Durable decisions: `docs/codex/DECISIONS.md`
- Historical records: `docs/codex/archive/2026-08/`
