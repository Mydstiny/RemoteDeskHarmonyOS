# RDP TLS Handshake Fix Plan

Status: P0 implemented in `d48c12471`; real endpoint validation pending.

## Scope

This checkpoint fixes the RDP certificate preflight classification path. It
does not add RD Gateway or vendor bastion support, and it does not enable
Standard RDP Security or legacy TLS as an implicit fallback.

## P0 implementation

- Read the 4-byte TPKT header first, validate version/reserved/length, then
  read the declared PDU with a bounded deadline.
- Parse X.224 Connection Confirm and RDP negotiation data through the pure
  C++ `RdpTpktAccumulator` helper.
- Continue to TLS only for `SSL`, `HYBRID`, and `RDSTLS` selections.
- Return explicit errors for Standard RDP Security, `RDP_NEG_FAILURE`, unknown
  protocols, invalid PDU lengths, and non-RDP responses.
- Return stable probe code `-22` for TLS handshake failure. Include the SSL
  error name/value and OpenSSL reason stack; include socket errno only for
  `SSL_ERROR_SYSCALL`.
- Fail closed when `SSL_set_fd` or SNI setup fails, and release SSL/fd state
  on every preflight failure path.

## Tests and gates

- `rdp_native_tests`: the six RDP negotiation tests pass, including TLS
  selections, one-byte/multi-part fragmentation, Standard RDP, negotiation
  failure, malformed frames, and unknown protocols.
- Full native run: 242 passed; 16 pre-existing VNC TLS fixture startup
  failures in the current host environment.
- `default@OhosTestCompileArkTS`: passed.
- `assembleHap`: passed and signed.
- Read-only review found no high-severity issue; setup/error-queue findings
  were fixed before the final build.

## Blockers and next steps

- No real bastion/RDP endpoint, HDC device, or hilog evidence is available.
- Confirm whether the reported service is direct RDP, RD Gateway, a vendor
  proxy, or a legacy security-layer endpoint.
- P1 should unify certificate preflight with FreeRDP negotiation/TLS.
- P2 should implement separate Gateway TLS and target RDP endpoint handling.
- P3 may add an explicit, audited compatibility mode only if required.
