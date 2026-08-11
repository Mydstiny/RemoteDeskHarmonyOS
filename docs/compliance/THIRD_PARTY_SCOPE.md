# Third-party scope and release policy

Every shipped source or static artifact must appear in
`THIRD_PARTY_NOTICES.md`, the SPDX SBOM, and
`THIRD_PARTY_ARTIFACTS.sha256`. The release gate rejects missing hashes,
missing protocol provenance, tracked private configuration, and unapproved
license identifiers.

Current high-risk boundaries are RustDesk protocol definitions, prebuilt
FreeRDP/WinPR, OpenSSL, FFmpeg, libssh2, Mbed TLS, Opus and Huawei packages.
The Moonlight boundary additionally includes the exact GPL-3.0-only
moonlight-common-c source and its pinned MIT ENet/nanors gitlinks. Those three
trees must remain byte-verified, separately identified in the SPDX SBOM and
available in every corresponding source archive; project adaptations must not
be hidden inside the upstream snapshot.
The packaged Moonlight protocol icon is a deterministic tintable transform of
the official Moonlight Qt SVG at a pinned revision. Its original and packaged
hashes, transformation, fallback and trademark boundary are recorded in
`MOONLIGHT_ICON_PROVENANCE.md`; it remains a separate SPDX package/file from
the common-c protocol implementation.
RustDesk protocol provenance must record both the outer RustDesk revision and
its `hbb_common` gitlink revision; local normalized and upstream byte hashes
are separate facts and must not be presented as identical.
FFmpeg build flags must be reviewed per release because codec/configuration
choices can change LGPL/GPL obligations. Unknown, GPL-2.0-only,
non-redistributable, or source-unavailable components block a public binary
release.
