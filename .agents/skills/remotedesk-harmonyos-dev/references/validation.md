# 验证与交付

执行要求以当前 [AGENTS.md](../../../../AGENTS.md) 为准。本文件将构建/设备/审查证据区分，并指向可复用脚本。旧 `BUILD_BASELINE.md` 和 README 的 daemon 示例不替代现行双门禁。

## 强制 Hvigor 门禁

macOS 从项目根目录：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

每条独立判断退出码，两项都成功才称通过。Windows 用本机 DevEco Node/Hvigor launcher，传同样的 module、product、任务与 `--no-daemon` 参数。记录实际命令、退出值、BUILD SUCCESSFUL/失败原因和所验证的范围。

即使文档/skill/流程变更，当前项目也要求上述两项、`git diff --check` 和 Light。不能引用上次运行结果代替本次验证。

## 增量验证

| 范围 | 追加验证 |
|---|---|
| ArkTS 策略/UI | 同名 policy 定向测试/编译，相关设备视觉/交互证据 |
| 测试模块 | 按 AGENTS 加 `ohosTest@OhosTestCompileArkTS`；如任务图不存在，准确报告该失败，不用它取代必需双门禁 |
| native | `entry/src/main/cpp/CMakeLists.txt` 的 `RDP_BUILD_TESTS`/`RDP_TESTS_ONLY` 与 `rdp_native_tests`，选择受影响 ABI |
| Rust | `rustdesk_ffi` 下 `cargo test --lib --no-default-features`，按变化使用 filter/格式检查；OHOS 构建与 host tests 分开 |
| 依赖/proto/gitlink | ABI、provenance、SBOM、NOTICE、hashes；Release 规则按变更范围执行 |
| 发布/tag | clean clone、双 ABI、设备/服务端矩阵、Release gate 与必要签名配置 |
| Skill 内容 | 格式、引用/证据核验和有必要时独立使用测试；运行 [audit_skill.py](../scripts/audit_skill.py) |

Native host 示例可由当前 CMake 支持的 tests-only 选项构建到项目内独立目录；先查脚本/现有任务，不默认触发所有 ABI 重编译。不得将 `.so` 文件存在当成功能链接和加载证明。

## 合规与发布

```sh
pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light
```

PowerShell 定位使用 [resolve_powershell.sh](../../../../scripts/resolve_powershell.sh)；hook 与 index/HEAD 校验范围需从其实际输出确认。[verify_clean_clone_build.ps1](../../../../scripts/verify_clean_clone_build.ps1)、[verify_open_source_release.ps1](../../../../scripts/verify_open_source_release.ps1) 的 Release 模式按正式发布请求使用。

新增项目原创文件遵循 [REUSE.toml](../../../../REUSE.toml) 的授权覆盖；有上游变化才按 [DEPENDENCY_UPDATE_POLICY.md](../../../../docs/compliance/DEPENDENCY_UPDATE_POLICY.md) 更新对应依赖证据，不为纯 skill 写作伪造依赖升级或改 hashes。

## 状态、审查与当前活动分支

- [codex_state.mjs](../../../../scripts/codex_state.mjs) 的 `status`/`snapshot` 和 [REVIEW_RECEIPTS.jsonl](../../../../docs/codex/REVIEW_RECEIPTS.jsonl) 判断 receipt 复用。PASS 的 base/plan/scope 必须匹配；不借用 Pro 代码 receipt 宣称 skill 已独立复核。
- 文档、skill 的独立使用测试明确记录自身范围及结果，可在共享 archive 保存报告，不扩大应用代码的 PASS 声明。
- 分支、commit、CURRENT/STATE、QUEUE 按任务更新；已有并行编辑不能随手暂存。仅提交本次明确文件或本次差量。
- 全分支所有任务完成且授权范围满足后，才按 AGENTS 走 push → PR → required check → merge → 同步 main。分支仍有原活动任务 blocker 时保留该分支，不为交付附属资料擅自发布未完成业务。

## 常见失败的含义

EPERM/工具链缺失是环境失败；按正常权限机制重试或记录 blocker，不能绕过审批/合规 hook。ArkTS warning 与 error 分开；任务名不存在不算成功。HDC 无设备不等于连接工具坏了。development signed HAP 能生成，不表示商店签名/生产权益/全部协议验收通过。

报告采用“本次运行通过/未运行/受阻/历史记录”四类表达。不得把未运行检查写进 PASS。
