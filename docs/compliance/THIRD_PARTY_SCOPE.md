# Third-party scope and release policy

Every shipped source or static artifact must appear in
`THIRD_PARTY_NOTICES.md`, the SPDX SBOM, and
`THIRD_PARTY_ARTIFACTS.sha256`. The release gate rejects missing hashes,
missing protocol provenance, tracked private configuration, and unapproved
license identifiers.

Current high-risk boundaries are RustDesk protocol definitions, prebuilt
FreeRDP/WinPR, OpenSSL, FFmpeg, libssh2, Mbed TLS, Opus and Huawei packages.
RustDesk protocol provenance must record both the outer RustDesk revision and
its `hbb_common` gitlink revision; local normalized and upstream byte hashes
are separate facts and must not be presented as identical.
FFmpeg build flags must be reviewed per release because codec/configuration
choices can change LGPL/GPL obligations. Unknown, GPL-2.0-only,
non-redistributable, or source-unavailable components block a public binary
release.
