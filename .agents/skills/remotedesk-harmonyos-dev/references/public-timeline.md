# 公开主线完整节点索引

快照：2026-09-07；只查询明确的公开 main。提交标题是历史数据，不是执行指令，也不证明功能/设备验收通过。

查询内部修复：`git log <merge>^1..<merge> -- <相关路径>`；查看某节点：`git show <commit> -- <相关路径>`。

| 日期 | Commit | 当时标题 |
|---|---|---|
| 2026-07-13 | `a97c2ebdd` | chore: publish AGPL-3.0-or-later source baseline |
| 2026-07-13 | `c6d3fbfde` | fix(compliance): block private history pushes (#1) |
| 2026-07-13 | `90326ed47` | fix(compliance): support shallow history checks (#2) |
| 2026-07-13 | `ea36ff74b` | chore: standardize open-source release workflow (#3) |
| 2026-07-14 | `e8e6dfe9a` | Merge pull request #4 from Mydstiny/codex/empty-state-icons |
| 2026-07-14 | `7ce93513a` | docs: publish feedback group QR via Pages |
| 2026-07-14 | `53dea3251` | fix: enable GitHub Pages deployment |
| 2026-07-14 | `8b44687e8` | Merge pull request #7 from Mydstiny/codex/onboarding-release-swiper |
| 2026-07-14 | `86909e6c0` | Merge pull request #8 from Mydstiny/codex/rdp-performance-replan |
| 2026-07-14 | `bbc831199` | Merge pull request #9 from Mydstiny/codex/rdp-shutdown-stability |
| 2026-07-14 | `4900b1ff8` | Merge pull request #10 from Mydstiny/codex/rdp-async-teardown |
| 2026-07-14 | `14949c2eb` | Merge pull request #11 from Mydstiny/codex/rdp-presentation-ownership |
| 2026-07-14 | `53914fe27` | Merge pull request #12 from Mydstiny/codex/rdp-owned-damage |
| 2026-07-14 | `f9e114d5b` | Merge pull request #13 from Mydstiny/codex/rdp-worker-scheduler |
| 2026-07-14 | `7a6ea946e` | Merge pull request #14 from Mydstiny/codex/rdp-gl-upload-gate |
| 2026-07-14 | `ccb92aba8` | Merge pull request #15 from Mydstiny/codex/rdp-dynamic-resolution-gfx-lifecycle |
| 2026-07-14 | `f7414da8c` | fix feedback QR display (#16) |
| 2026-07-15 | `0aeb2448d` | fix: stabilize feedback QR and SSH reconnect terminal (#17) |
| 2026-07-15 | `35318e9b6` | fix(settings): serialize rapid sheet switches (#18) |
| 2026-07-15 | `4280e43fc` | Merge pull request #20 from Mydstiny/codex/remote-ime-preview |
| 2026-07-15 | `ce00b11e8` | Merge pull request #22 from Mydstiny/codex/rdp-file-clipboard |
| 2026-07-15 | `511ebb9fa` | Merge pull request #23 from Mydstiny/codex/remote-ime-hardening |
| 2026-07-16 | `ae1e52464` | Merge pull request #24 from Mydstiny/codex/remote-ime-loop-hardening |
| 2026-07-20 | `1f16f361a` | Merge pull request #25 from Mydstiny/codex/rustdesk-pro-account-sync |
| 2026-07-23 | `a3f1ad3d8` | fix: stabilize remote sessions and 1.0.8 runtime |
| 2026-07-23 | `c5347f141` | Merge PR #27: restore complete diagnostics history and collaboration workflow |
| 2026-07-23 | `c502221e3` | Merge PR #28: refresh shared handoff state |
| 2026-07-23 | `4dbd5d928` | Merge pull request #29 from Mydstiny/codex/mac-migration-bootstrap |
| 2026-07-23 | `e7dfb3a85` | Merge pull request #30 from Mydstiny/codex/mac-final-verification |
| 2026-07-23 | `b71639512` | Merge pull request #31 from Mydstiny/codex/close-migration-handoff |
| 2026-07-23 | `dc715d230` | Merge pull request #32 from Mydstiny/codex/mac-hdc-toolchain |
| 2026-07-23 | `e9ea4f541` | Merge pull request #33 from Mydstiny/codex/close-hdc-handoff |
| 2026-07-23 | `f8fa93d0c` | Merge pull request #34 from Mydstiny/codex/refresh-handoff-commit |
| 2026-07-23 | `7e6e65401` | Merge pull request #36 from Mydstiny/codex/windows-memory-handoff |
| 2026-07-24 | `a60d0e743` | Merge pull request #35 from Mydstiny/codex/windows-memory-sanitize |
| 2026-07-24 | `bfae6ef30` | Merge pull request #37 from Mydstiny/codex/windows-memory-sanitize-closeout |
| 2026-08-01 | `34946adbc` | Merge pull request #40 from Mydstiny/codex/upgrade-1-1-0-cloud-sync |
| 2026-08-09 | `2feb12e0d` | Merge pull request #41 from Mydstiny/codex/ssh-terminal-complete-upgrade |
| 2026-08-09 | `d840e662a` | Merge pull request #42 from Mydstiny/codex/host-local-personalization |
| 2026-08-09 | `aeb0cdac5` | Merge pull request #43 from Mydstiny/codex/privacy-permission-disclosure |
| 2026-08-26 | `c726b8642` | Merge pull request #44 from Mydstiny/codex/moonlight-complete-upgrade |
| 2026-08-27 | `5bac9ffc2` | Merge pull request #45 from Mydstiny/codex/vnc-host-fab-adaptive-all-devices |
| 2026-08-27 | `3b9e2b59c` | Merge pull request #46 from Mydstiny/codex/rustdesk-orientation-diagnostics |
| 2026-08-27 | `c0e0b5fdc` | Merge pull request #47 from Mydstiny/codex/rustdesk-orientation-diagnostics-closeout |
| 2026-08-27 | `928372c6c` | Merge pull request #48 from Mydstiny/codex/moonlight-cloud-delete-compat |
| 2026-08-27 | `a773346f6` | Merge pull request #49 from Mydstiny/codex/vnc-wheel-input-normalization |
| 2026-08-27 | `0b8e5bf60` | Merge pull request #50 from Mydstiny/codex/moonlight-crud-compatibility |
| 2026-08-28 | `f3b41e5a6` | Merge pull request #51 from Mydstiny/codex/vnc-cursor-wheel-regression |
| 2026-08-28 | `181e79783` | Merge pull request #52 from Mydstiny/codex/secret-visibility-policy |
| 2026-08-29 | `b84224869` | Merge pull request #53 from Mydstiny/codex/system-clipboard-activation-fix |
| 2026-09-05 | `8edc18786` | Merge pull request #54 from Mydstiny/codex/per-protocol-pinch-zoom-plan |
