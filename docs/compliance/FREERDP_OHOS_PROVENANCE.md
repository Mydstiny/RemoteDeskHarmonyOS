# FreeRDP OHOS provenance

The application gitlink is
`dae8276ac7361b8d14f7b87d41163fe03dbb944e`, a local OHOS adaptation not
present in the previously configured Gitee mirror. Its complete Apache-2.0
source history is published in this GitHub repository on branch
`freerdp-ohos`; the main branch submodule URL points to that public source.

Upstream project: `https://github.com/FreeRDP/FreeRDP`.
The custom branch must be pushed before any clean-clone verification or main
branch migration.

The checked-in OHOS static libraries are built by
`scripts/build_freerdp_ohos.sh all` for `arm64-v8a` and `x86_64`. The release
configuration enables the `drdynvc`, `disp` (`CHANNEL_DISP_CLIENT`) and
`drive` (`CHANNEL_DRIVE_CLIENT`) clients. Display Control carries
single-monitor layout, orientation and DPI scale updates; post-connect drive
registration uses FreeRDP's published `RdpdrClientContext` interface rather
than an untracked source patch. The build fails if the packaged channel
archive omits the display, drive or RDPDR entry symbols. Exact archive hashes are maintained in
`docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`; changing the source revision,
channel set, toolchain or archive contents requires refreshing that inventory
and passing the provenance test.
