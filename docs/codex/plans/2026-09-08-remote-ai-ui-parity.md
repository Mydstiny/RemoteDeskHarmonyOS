# AI UI 与既有主机流程统一收尾

用户于 2026-09-08 明确要求继续收尾。基于 AI4 `7bdf00f6`，只处理 AI 表单、设置和工作区 UI；沿用现有 Pro 活动分支、账号和业务权限规则，不修改传输/native。

## 范围

1. 经典模式显示完整表单；全新模式实际执行“主机信息 → 配对与保存”。第 2 步可回到第 1 步；FAB 新增可回协议选择；设置/编辑入口不跳入不存在的选择器。所有入口遵守保存的 hostAddMode。
2. Editor、设置和工作区复用 Theme/AppConfig、AppUiMetrics、AppSheetHeader、AppSettingsActionRow/SwitchRow/ChoiceButton；AI 动作按钮采用同一字体、最小触点和强调色对比度策略。
3. 添加表单自然布局，统一 FIT_CONTENT、底部/居中及键盘避让；设置与会话弹窗有完整滚动范围和安全区。窄屏动作/详情标签换行，工作区自然高度和持续外层滚动覆盖小高度、错误文字和大字体；同一内容树避免切树失焦。
4. 保存时冻结表单与邀请，await 后检查编辑代次/账号/前后台。账号失效、撤权和后台时清理邀请及会话页面草稿；撤权使等待中的旧邀请提交失效，之后恢复权限也不复用。工作区独立监听账号，关闭流连接后的后台仍能清理旧主机标题。
5. 保留配对、受限停止、审批完整请求、单选问答、会话选择及 Sheet 消失后连接的业务边界。

## 验证与收尾

- 定向执行实际 Editor/Workspace/Settings 方法与入口回调，覆盖模式回退、保存中变更、旧邀请、退出/后台/账号/Pro 变化及缩小布局策略。
- 当前 default@OhosTestCompileArkTS + 签名 assembleHap，Light、diff 和独立 UI 增量复核；只提交本轮文件及 HostList 两条 AI 回调接线。
- 实机视觉、输入法、大字体和 Phone/Pad/PC 仍需实际设备证据；测试方法和编译不冒充 ArkUI 渲染验收。

当前：本轮代码收尾完成，提交 `066493a7`；独立 `/root/review_native_dsh` exact-commit PASS，无剩余发现。复核提出的撤权恢复旧邀请、固定高度阻塞滚动两项已修复。

- `scripts/tests/test_ai_ui_parity.cjs` 对该提交执行 15/15 PASS；已有页面生命周期 6/6、入口 3 组 PASS。可设置 `AI_TYPESCRIPT_PATH`；`AI_REVIEW_REF` 可固定源码版本。测试使用实际生产方法/回调和受控依赖；布局部分只检查声明，不模拟 ArkUI 渲染。
- 当前修正后 testCompile `BUILD SUCCESSFUL in 7 s 171 ms`；签名 assembleHap `BUILD SUCCESSFUL in 8 s 418 ms`（SignHap 819 ms），均 exit 0；Light/diff PASS。首次受限运行无法写现有 Hvigor 缓存，获准后重跑成功。
- 本轮仅 AI UI 和回归；原 AI4 传输/业务复核继续有效。Phone/Pad/PC 的真实视觉、大字体、输入法、配对与 LAN 验收仍未运行；Pro 共用活动分支未完成，保留该分支而不合并整体任务。
