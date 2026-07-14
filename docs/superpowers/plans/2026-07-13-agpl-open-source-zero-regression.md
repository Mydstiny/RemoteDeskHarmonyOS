# AGPL 开源化与零功能回归实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 将 RemoteDesktop 的未来发行版转为可合规包含 RustDesk AGPL-3.0 组件的开源发行版，同时用可重现构建、协议契约、设备冒烟和发布门禁证明不改变任何既有产品功能。

**Architecture:** 改造分为版权与来源事实、可重现构建输入、许可证/通知/源码提供、持续发布验证四层。运行时功能、协议实现、数据库、权限和 Native ABI 先冻结；唯一允许的产品界面变化是既有关于页中准确的许可证/源码链接，且必须复用已有 openUrl 路径并完成视觉确认。

**Tech Stack:** HarmonyOS NEXT API 23、ArkTS、C++/CMake、Rust/Cargo、DevEco hvigor、PowerShell、Git、SPDX/REUSE、AGPL-3.0-or-later、Apache-2.0。

## Global Constraints

- 只在独立、干净的 Git worktree 中实施；不得暂存、覆盖或提交当前工作区已有的 RemoteDesktop.ets、RemoteImeSessionPolicy.ets 及相关测试改动。
- 不改变 RDP、RustDesk、SSH、VNC 的 wire protocol、NAPI 导出、线程生命周期、渲染、音频、输入、认证、云数据结构、Preferences 键、权限、包名、版本号或 UI 布局。任何例外必须由用户单独批准。
- 许可证文件、第三方通知、构建脚本、CI、依赖路径迁移和 SPDX 注释必须分任务提交；每个提交后均执行相应功能回归门。
- 不能以构建成功替代功能等价。任何 RustDesk 构建输入改动都必须重建两个 OHOS ABI、检查 NAPI 动态符号并执行设备协议矩阵。
- 不在源码、计划、SBOM 或发布文件中写入证书口令、AGC client secret、令牌、私钥、真实主机地址或个人账号。
- 当前 Rust host test 与部分 ArkTS test 有既知环境阻断；在它们可重复前，不得声称零回归已经证明，只能报告构建和设备矩阵证据。
- AGPL 的适用范围、版权归属、第三方例外和应用商店条款必须由版权负责人/法务书面确认；本计划不替代法律意见。

## Non-Regression Contract

| 契约 | 必须保持不变的证据 |
|---|---|
| RDP、RustDesk、SSH、VNC 入口、保存主机和路由 | ArkTS 主机 CRUD 冒烟与协议设备矩阵 |
| Native ABI、NAPI 导出和 Rust FFI 接口 | nm 导出清单、rustdesk_version、Native session smoke |
| 主机、凭据、同步与 KeyVault 数据格式 | 不执行 schema/Preferences/migration 改动；同一测试数据可读 |
| 权限、后台模式、包名、版本号与 build profile | AppScope/app.json5、module.json5、build-profile.json5 diff allowlist |
| UI | 只有经过确认的 About 许可/源码行变化；其他截图与关键操作路径不变 |

---

### Task 1: 冻结版权、贡献与发行决策

**Files:**
- Create: docs/compliance/OWNERSHIP_AND_RELICENSING.md
- Create: docs/compliance/LICENSE_DECISION_RECORD.md
- Create: docs/compliance/THIRD_PARTY_SCOPE.md
- Test: git shortlog -sne --all; git log --format='%H%x09%aN%x09%aE' --all

**Produces:** 版权负责人签署的组合发行决定，以及所有源码、二进制和生成代码的来源边界。

- [ ] 在用户确认可用的提交基线创建独立 worktree；候选基线为 8deac017383531c902898aa3337673e7febd49b9。实施 worktree 的 git status --short 必须为空。
- [ ] 把所有贡献者、历史 Apache 声明、第三方引入记录和书面授权写入 OWNERSHIP_AND_RELICENSING.md。没有书面依据的文件标记 UNRESOLVED，不得改许可或发布。
- [ ] 在 LICENSE_DECISION_RECORD.md 固定模型：已获授权的项目自有组合发行版采用 AGPL-3.0-or-later；Apache、BSD、MIT、OpenSSL、FreeRDP 等第三方仍保留自身许可证和 notice。
- [ ] 在 THIRD_PARTY_SCOPE.md 记录每个静态库是否有可获取源、许可证、版本、SHA-256 和例外批准。遇到 GPLv2-only、禁止再分发、未知版权或无法取得构建源，停止公开 release。
- [ ] Commit: git add docs/compliance/OWNERSHIP_AND_RELICENSING.md docs/compliance/LICENSE_DECISION_RECORD.md docs/compliance/THIRD_PARTY_SCOPE.md; git commit -m "docs(license): record agpl release decision"

### Task 2: 建立不可变功能与构建基线

**Files:**
- Create: docs/compliance/baselines/<release-tag>/SOURCE_REVISION.md
- Create: docs/compliance/baselines/<release-tag>/FUNCTIONAL_CONTRACT.md
- Create: docs/compliance/baselines/<release-tag>/INPUT_SHA256.json
- Create: docs/compliance/baselines/<release-tag>/DEVICE_MATRIX.md
- Create: scripts/create_open_source_baseline.ps1
- Test: CODEWALK §8 assembleHap；设备协议冒烟

**Produces:** 每个公开 release 可复核的输入哈希、功能契约、构建记录和设备证据。

- [ ] 在 FUNCTIONAL_CONTRACT.md 固定四协议行为、Native ABI、主机/凭据数据、CloudStore schema、权限、包名、版本和除 About 外的 UI；列出每项测试入口和期望，不记录真实地址或秘密。
- [ ] create_open_source_baseline.ps1 仅使用 git rev-parse HEAD、git submodule status --recursive 与 Get-FileHash -Algorithm SHA256 哈希源码、锁文件、协议文件和二进制依赖。排除 build-profile.json5、agconnect-services.json、p12、p7b、pem、key、jks 及本地 profile。
- [ ] 在 Git Bash 执行 scripts/build_rustdesk_ffi_ohos.sh all，然后按 CODEWALK §8 执行 hvigorw.js --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon。期望两个 librustdesk_ffi.a 均存在且输出 BUILD SUCCESSFUL。
- [ ] 在同一 HAP 记录 RDP 连接/键鼠/音频/返回，RustDesk 视频/音频/键鼠/剪贴板当前行为，SSH 终端/SFTP，VNC 当前行为，CloudSync、主机锁、主题和后台恢复。基线不支持的能力不在本计划修复。
- [ ] Commit: git add docs/compliance/baselines scripts/create_open_source_baseline.ps1; git commit -m "test(compliance): freeze functional release baseline"

### Task 3: 使 RustDesk 协议输入可追溯且可重建

**Files:**
- Create: third_party/rustdesk-protocol/message.proto
- Create: third_party/rustdesk-protocol/rendezvous.proto
- Create: third_party/rustdesk-protocol/UPSTREAM.yml
- Create: third_party/rustdesk-protocol/NOTICE
- Modify: rustdesk_ffi/build.rs
- Modify: entry/src/main/cpp/CMakeLists.txt
- Modify: .gitignore
- Create: scripts/verify_rustdesk_protocol_provenance.ps1
- Test: Cargo codegen hash、双 ABI FFI、HAP 和 RustDesk device smoke

**Produces:** 不再依赖被忽略 rustdesk_vendor checkout 的、锁定上游提交与 SHA-256 的协议定义。

- [ ] 将当前构建所用的两份 proto 原样复制到 third_party/rustdesk-protocol。UPSTREAM.yml 固定上游 URL、commit 93d064a9b0eb58ab94db88ff727a877ef773c0d8、原路径、许可证引用、下载日期和逐文件 SHA-256。
- [ ] 用 Get-FileHash 比较旧路径与新路径的两份 proto，四项两两哈希必须一致。删除 rustdesk_ffi/target 后分别按旧路径、新路径运行 cargo build --release --target aarch64-unknown-linux-ohos，并比较生成 message.rs/rendezvous.rs 哈希；不一致即回滚。
- [ ] 同时修改 build.rs 的 proto_dir 与 CMakeLists.txt 的 RUSTDESK_PROTO_DIR 指向新路径。不得修改 proto 内容、connector.rs、session.rs、wire.rs、NAPI 或 ArkTS；删除 .gitignore 中旧 vendor proto 例外。
- [ ] 运行 Task 2 双 ABI/HAP。以 nm -g --defined-only 比较迁移前后 librustdesk_ffi.a 的 RustDesk 导出集合和 librdpnapi.so 的 NAPI 导出集合；再运行 RustDesk 视频、音频、键鼠设备回归。任何差异都回滚本任务。
- [ ] Commit: git add third_party/rustdesk-protocol rustdesk_ffi/build.rs entry/src/main/cpp/CMakeLists.txt .gitignore scripts/verify_rustdesk_protocol_provenance.ps1; git commit -m "build(rustdesk): lock protocol source provenance"

### Task 4: 添加许可证、NOTICE、SBOM 与文件级标识

**Files:**
- Create: LICENSE
- Create: NOTICE
- Create: LICENSES/AGPL-3.0-or-later.txt
- Create: LICENSES/Apache-2.0.txt
- Create: THIRD_PARTY_NOTICES.md
- Create: REUSE.toml
- Create: docs/compliance/SBOM.spdx.json
- Create: scripts/verify_license_metadata.ps1
- Modify: 项目自有的 ets、ts、cpp、c、h、rs、ps1、sh、json5、md 文件，仅添加非语义 SPDX 头
- Modify: entry/oh-package.json5
- Test: SPDX/notice scan、HAP build、scoped source diff review

**Produces:** 可由用户、下游贡献者和自动化工具理解的多许可证发行结构。

- [ ] 根 LICENSE 放置完整、未改写 AGPL-3.0 文本；LICENSES 目录保存 AGPL 和 Apache 正文。NOTICE 与 THIRD_PARTY_NOTICES.md 保留每个第三方的版权、许可证、NOTICE、上游版本和本地修改说明。
- [ ] REUSE.toml 仅为 Task 1 确认由项目拥有的路径声明 AGPL-3.0-or-later；freerdp、libs、third_party、生成代码和外部配置按实际来源声明，不能用项目 AGPL 头覆盖。
- [ ] 为已确认所有权的文件添加相应语言的 SPDX 头。每批 diff 只能有注释、许可证、notice、SBOM 或 entry/oh-package.json5 的 license 元数据；不准修改 imports、函数、常量、资源、JSON 业务配置和 CMake 参数。
- [ ] SBOM.spdx.json 覆盖 HAP 内 ArkTS、Native、Rust、FreeRDP、OpenSSL、FFmpeg、libssh2、Opus、AGConnect 和 Cargo crates，记录版本、SHA-256、许可证、来源、构建方式和系统库状态。verify_license_metadata.ps1 必须拒绝没有来源/许可证/SHA 的静态库。
- [ ] 执行 git diff --check、Task 2 HAP 构建和设备矩阵。Commit: git add LICENSE NOTICE LICENSES THIRD_PARTY_NOTICES.md REUSE.toml docs/compliance/SBOM.spdx.json scripts/verify_license_metadata.ps1 entry/oh-package.json5 entry/src/main rustdesk_ffi; git commit -m "chore(license): publish agpl and third-party notices"

### Task 5: 建立对应源码提供与可复现发布门

**Files:**
- Create: README.md
- Create: docs/compliance/SOURCE_OFFER.md
- Create: docs/compliance/RELEASE_MANIFEST.schema.json
- Create: docs/compliance/RELEASE_MANIFEST.example.json
- Create: scripts/verify_open_source_release.ps1
- Create: scripts/verify_clean_clone_build.ps1
- Test: clean clone build、manifest verification、source archive verification

**Produces:** 每个 HAP 与一个不含秘密、可构建、可定位的源代码 tag 一一对应。

- [ ] RELEASE_MANIFEST.schema.json 固定 releaseTag、sourceCommit、hapSha256、sbomSha256、rustdeskProtocolCommit、rustdeskProtocolSha256、freerdpSubmoduleCommit、buildCommand、toolchainVersions、sourceOfferUrl、generatedAtUtc。禁止秘密字段。
- [ ] SOURCE_OFFER.md 与 README 说明 source tag、下载地址、SBOM、双 ABI FFI/DevEco 构建命令和第三方源。README 不能在 Task 8 gate 通过前宣称完整可重现。
- [ ] verify_clean_clone_build.ps1 在空目录 clone 指定 tag，验证 submodule、协议源、Cargo.lock、预编译依赖来源和非秘密 build profile 模板，随后执行双 ABI 与 assembleHap。Release Profile 只能通过环境变量路径传入，不能复制到仓库。
- [ ] verify_open_source_release.ps1 在 tag/manifest/SBOM/协议 SHA/子模块 SHA/许可证/source URL/秘密扫描/clean clone/设备矩阵任一缺失时失败。
- [ ] Commit: git add README.md docs/compliance/SOURCE_OFFER.md docs/compliance/RELEASE_MANIFEST.schema.json docs/compliance/RELEASE_MANIFEST.example.json scripts/verify_open_source_release.ps1 scripts/verify_clean_clone_build.ps1; git commit -m "build(release): add open source release manifest gates"

### Task 6: 更新应用内许可与源码入口

**Files:**
- Modify: entry/src/main/ets/components/AboutSettingsSheet.ets:184-225
- Modify: entry/src/main/resources/base/element/string.json
- Create: entry/src/test/AboutLicensePolicy.test.ets
- Create: docs/superpowers/specs/2026-07-13-about-license-source-offer-design.md
- Test: visual approval、ArkTS test、production HAP build

**Consumes:** Task 4 许可文本和 Task 5 source offer URL 规则.

**Produces:** 准确的 AGPL/第三方许可文案，且继续使用既有 GitHub 打开行为。

- [ ] 先提交视觉设计：只替换 About 页现有 Apache 2.0 卡片为 AGPL-3.0-or-later 说明，保留位置、圆角、色彩、字体和 openUrl 交互；增加对应源码与第三方声明行。渲染手机、Pad、PC 三态并获得用户确认。
- [ ] AboutLicensePolicy.test.ets 固定版本到 https://github.com/Mydstiny/RemoteDeskHarmonyOS/tree/<releaseTag> 的映射；URL 为空则隐藏入口，绝不打开未知地址。策略不得读取账户、主机、凭据或网络状态。
- [ ] 复用 AboutSettingsSheet.openUrl，把文案移入 string.json。不得更改 sheet mode、HostListPage、路由、布局尺寸、设置保存或 URL 启动机制。
- [ ] 验证 About 可打开、旧 GitHub/官网链接仍可打开、关闭 sheet 正常、无新增权限/网络请求。若 ArkTS target 被历史 sourcemap 阻断，保存失败证据，以 production assembleHap 与设备截图作为受限验证，不得报告自动化已通过。
- [ ] Commit: git add entry/src/main/ets/components/AboutSettingsSheet.ets entry/src/main/resources/base/element/string.json entry/src/test/AboutLicensePolicy.test.ets docs/superpowers/specs/2026-07-13-about-license-source-offer-design.md; git commit -m "feat(about): disclose agpl source offer"

### Task 7: 处理公开源码前的秘密、供应链与贡献治理

**Files:**
- Create: SECURITY.md
- Create: CONTRIBUTING.md
- Create: docs/compliance/SECRET_ROTATION_AND_HISTORY_RUNBOOK.md
- Create: docs/compliance/DEPENDENCY_UPDATE_POLICY.md
- Modify: .gitignore
- Modify: docs/app-store/RELEASE_PRIVACY_CHECKLIST.md
- Test: secret scan、tracked-file audit、release gate

**Produces:** 不公开秘密的开源仓库和持续的依赖/贡献规则。

- [ ] 先在 SECRET_ROTATION_AND_HISTORY_RUNBOOK.md 固定顺序：轮换可能已泄露的签名口令、AGC client secret、API key、OAuth token 和测试密钥；验证新凭据私有构建；再由用户显式授权选择 history rewrite 或公开前新仓库迁移。未轮换前不得删除当前文件制造已安全假象。
- [ ] .gitignore 只排除真实私密 profile/证书/AGC 覆盖文件；提交不含秘密的 example 配置和字段说明。Release build 从本机安全路径或 CI secret 注入。
- [ ] CONTRIBUTING.md 要求贡献者确认版权、接受 AGPL-3.0-or-later 贡献条款、保留第三方 notice、更新 SBOM。SECURITY.md 提供私密漏洞报告路径，不要求 issue 包含凭据或远程日志原文。
- [ ] 对秘密扫描命中分类为真秘密、公开标识或误报；真秘密必须完成轮换、移除和历史处置决定后才能公开 release。
- [ ] Commit: git add SECURITY.md CONTRIBUTING.md docs/compliance/SECRET_ROTATION_AND_HISTORY_RUNBOOK.md docs/compliance/DEPENDENCY_UPDATE_POLICY.md .gitignore docs/app-store/RELEASE_PRIVACY_CHECKLIST.md; git commit -m "chore(security): prepare public source release hygiene"

### Task 8: 将许可证与功能等价检查纳入持续发布门

**Files:**
- Create: .github/workflows/open-source-release.yml（仓库使用 GitHub Actions 时）
- Create: docs/compliance/CI_PORTABILITY.md
- Modify: scripts/verify_open_source_release.ps1
- Modify: docs/DEVICE_VERIFICATION_CHECKLIST.md
- Test: 本地 gate、CI dry run、完整四协议设备矩阵

**Produces:** 没有完整许可证、可重现构建或功能证据的提交不能被标记为公开 release。

- [ ] 先确保 PowerShell gate 本地可运行；CI_PORTABILITY.md 规定 GitHub Actions、华为内部 CI 或本地 release 机只调用相同 verify_open_source_release.ps1，CI 不复制许可证判断逻辑。
- [ ] 轻量门检查格式、许可证/NOTICE/SBOM、protocol SHA、禁止跟踪秘密、SPDX 范围。release 重门执行 clean clone、双 ABI RustDesk FFI、assembleHap、NAPI 导出 diff、HAP manifest、四协议设备矩阵、CloudSync/主机锁/后台恢复冒烟。
- [ ] 当前 ArkTS sourcemap、Rust host Opus 链接和 host CMake OpenSSL 缺失问题必须作为阻断或受限证据；不能用 continue-on-error 后报告绿色。修复测试工具链属于独立非产品功能任务，修复后要重新建立 Task 2 基线。
- [ ] Commit: git add .github/workflows/open-source-release.yml docs/compliance/CI_PORTABILITY.md scripts/verify_open_source_release.ps1 docs/DEVICE_VERIFICATION_CHECKLIST.md; git commit -m "ci(compliance): gate open source releases"

### Task 9: 发布候选验收、回滚与未来被控端前置条件

**Files:**
- Create: docs/compliance/AGPL_RELEASE_ACCEPTANCE.md
- Create: docs/compliance/AGPL_NETWORK_SOURCE_OFFER_POLICY.md
- Create: docs/compliance/ROLLBACK_POLICY.md
- Test: release rehearsal、clean clone、source URL、device matrix、rollback drill

**Produces:** 可发布 AGPL source release，以及未来 RustDesk 被控端的合规前置条件。

- [ ] 从干净 tag 生成 source archive、SBOM、release manifest 和 HAP；让第二台干净构建机仅用 source archive 与私有 Release Profile 重建，验证 manifest commit、协议 SHA、子模块 SHA、SBOM SHA 与产物匹配。
- [ ] 逐项复跑 Task 2 矩阵，比对许可证改造前后连接成功/失败文案、视频首帧、音频、键鼠、文件/剪贴板当前行为、后台返回、加密数据可读性、同步行为和主机锁。任何差异、性能回退、权限变化或数据库变化都使 release candidate 失败。
- [ ] 验证 About、README 和 release manifest 的 source offer 均指向同一 source tag。演练撤回：停止新 tag 下载入口、保留旧 tag/manifest、发布修正说明，绝不删除已提供的许可证或对应源码。
- [ ] AGPL_NETWORK_SOURCE_OFFER_POLICY.md 规定未来 RustDesk 被控端上线前，远程控制者可见的会话接受界面必须提供当前版本对应源码入口；离线/URL 不可用必须明确提示。Host 功能本身不包含在本计划中。
- [ ] Commit: git add docs/compliance/AGPL_RELEASE_ACCEPTANCE.md docs/compliance/AGPL_NETWORK_SOURCE_OFFER_POLICY.md docs/compliance/ROLLBACK_POLICY.md; git commit -m "docs(release): define agpl acceptance and rollback"; 仅在全部 gate 通过后创建带注释 release tag。

## Verification Matrix

| Gate | Required evidence | Failure action |
|---|---|---|
| 版权/许可 | 每个文件来源、许可、notice、版权所有者可追溯 | 停止公开发行，隔离未知文件 |
| 供应链 | SBOM、协议/子模块/二进制 SHA 与 clean clone 一致 | 回滚到上一可重建输入 |
| 静态 ABI | RustDesk FFI 与 librdpnapi.so 导出无非预期变化 | 回滚构建输入迁移 |
| 生产构建 | 双 ABI FFI 和 assembleHap 成功 | 修复工具链，不修改产品绕过 |
| 协议功能 | RDP/RustDesk/SSH/VNC 基线表现一致 | 定位并回滚单一改造提交 |
| 数据安全 | 测试数据可读，schema/Preferences/权限无变化 | 停止 release，恢复兼容性 |
| UI | 只有确认的 About 许可/源码行变化 | 回滚 UI 或重新确认 |
| 网络源码提供 | tag、manifest、About/source offer 一致 | 停止 Host/公开 release |

## Self-Review

- 任务 1 覆盖版权授权；任务 2/3 覆盖可重建 RustDesk 输入；任务 4 覆盖许可证、NOTICE 和 SBOM；任务 5/8 覆盖源码发行与持续门禁；任务 6 覆盖准确披露；任务 7 覆盖秘密与贡献；任务 9 覆盖发布、回滚和未来 Host 的网络源码入口。
- 所有可能触及构建、源码或界面的任务均有双 ABI、HAP、ABI、设备或 UI 证据。既知自动化阻断会阻止零回归结论。
- 许可证迁移、vendor 路径迁移、秘密治理和 About UI 均分离提交；发生功能差异必须回滚当前任务，不能借开源化名义修改远程桌面功能。

## Execution Handoff

实施时按任务逐个执行、逐个构建、逐个提交。任何产品功能差异先回滚当前任务，再以独立需求处理；不要在本开源化计划中实现 RustDesk 被控端功能。

