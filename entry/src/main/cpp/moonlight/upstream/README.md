# Moonlight upstream source boundary

`moonlight-common-c/` is an unmodified source snapshot of the revisions in
`UPSTREAM.lock.json`. Its `enet/` and `nanors/` directories are the exact
gitlink revisions declared by the pinned common-c commit. No `.git` metadata
or generated binary is shipped in this tree.

Project-authored build adaptation lives in `../vendor-build/`; any future
source patch must live in `../patches/` as a reviewable patch file and requires
new revision, content-manifest, notice, SBOM and source-offer evidence. Never
edit the files below `moonlight-common-c/` in place.

Run `scripts/verify_moonlight_vendor.py` to verify every vendored byte and
`scripts/build_moonlight_common_vendor.sh` for the isolated API 23 dual-ABI
static build; Windows and PowerShell 7 environments use the equivalent
`scripts/build_moonlight_common_vendor.ps1`. Both build entry points compare
their outputs with the machine receipts in `UPSTREAM.lock.json`. Neither
command links common-c into `rdpnapi` or enables the Moonlight product
capability.
