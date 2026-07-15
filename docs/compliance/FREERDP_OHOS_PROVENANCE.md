# FreeRDP OHOS provenance

The application gitlink is
`dae8276ac7361b8d14f7b87d41163fe03dbb944e`, a local OHOS adaptation not
present in the previously configured Gitee mirror. Its complete Apache-2.0
source history is published in this GitHub repository on branch
`freerdp-ohos`; the main branch submodule URL points to that public source.

Upstream project: `https://github.com/FreeRDP/FreeRDP`.
The custom branch must be pushed before any clean-clone verification or main
branch migration.

The tracked OHOS archives are reproducibly built by
`scripts/build_freerdp_ohos.sh` for `arm64-v8a` and `x86_64`. The client
channel archive intentionally includes both the `rdpdr` transport and the
`drive` device service required for an explicitly configured sandbox drive;
the application does not enable automatic redirection of all local drives.
Artifact digests are recorded in `THIRD_PARTY_ARTIFACTS.sha256`.
