# RustDesk 多屏切换快速加固计划

日期：2026-07-30
任务分支：`codex/rustdesk-multimonitor-switch-hardening`
基线：本地 `main@1615aff58`

## 目标

在保留当前“单画布、一次控制一个远端显示器”产品边界的前提下，把现有
`SwitchDisplay -> CaptureDisplays(set=[target]) -> RefreshVideoDisplay(target)`
链路升级为可确认、可连续切换、不会把旧屏输入或旧 ACK 回写到新屏的状态机。

本计划不实现多画布并排显示，不改变 RustDesk wire/protobuf，不修改 RDP、VNC、
SSH/SFTP 数据或输入所有权，也不启用未经验证的远端 Android 系统旋转能力。

## 已确认缺口

1. ArkTS 在切屏前只结束画布 pinch/touchpad anchor，没有完整释放实体键、虚拟修饰键、
   鼠标按键、拖拽和远端 TouchPan/TouchScale，也没有清除 ArkTS 与 Rust
   `ControlInbox` 中尚未发送的旧屏鼠标移动。
2. UI 在 Peer ACK/目标关键帧前乐观更新 `currentDisplay` 和几何；输入仍可进入旧/新坐标
   混合窗口。
3. 连续点击多个显示器会把完整切屏三元组按 FIFO 排队；旧目标 ACK、关键帧或本地轮询
   结果可能覆盖最新目标。
4. `PeerInfo.current_display` 无效或指向 offline 条目时，目录回退到首条记录，而不是首个
   online 显示器。

## 设计

### 1. 切屏输入屏障

- ArkTS 在建立屏障前，按旧几何发送所有必要的 key-up、mouse-up、TouchPan/TouchScale
  结束消息；随后清理触摸状态、ArkTS 鼠标合并槽和定时器。
- 屏障建立后，`canForwardInput()` 阻止 RustDesk 的键盘、鼠标、触控、滚轮和文本输入；
  显示菜单仍允许选择新的目标。
- UI 不再乐观修改已确认 `currentDisplay` 或远端几何。
- 只有最新目标同时得到显示 ACK 和该显示器关键帧后，才提交新几何并恢复输入。

### 2. latest-wins 与 generation

- Rust `ControlInbox` 新增一个有序、可替换的显示切换槽；一个槽在发送时原子执行官方
  单画布三元组。尚未发送的旧目标被新目标替换。
- 开始切屏时清除 Rust 端低优先级旧屏 `MouseMove` 和未发送的 TouchScale/TouchPan
  位移更新，但保留先前排队的释放消息，并确保释放消息排在切屏三元组之前。
- native 维护单调 switch generation。ACK 和关键帧必须同时匹配最新 generation 的目标；
  旧显示 ACK、旧关键帧和旧轮询结果不能推进或回写新状态。
- ArkTS 保存本次 generation，只接受 native 报告的同代 ready；连续切屏只保留最后目标。

### 3. online 回退

- `PeerInfo.current_display` 仅在索引存在且 online 时采用。
- 无效或 offline 时优先选择首个 online 显示器；没有 online 条目时才回退首条有效目录项。
- 本地显式选择仍优先于陈旧 PeerInfo；目标确认后才发布几何。

## 实施与提交顺序

1. `docs(rustdesk): plan multimonitor switch hardening`
   - 落盘本计划。
2. `fix(rustdesk): fence display switches behind input release`
   - ArkTS 输入释放、屏障与鼠标合并槽清理。
   - Rust `ControlInbox` 原子切屏槽和旧移动清理。
3. `fix(rustdesk): make display switching latest-wins`
   - native ACK + 目标关键帧 gate、generation、NAPI 快照。
   - ArkTS 只在最新 generation ready 后提交几何。
4. `fix(rustdesk): prefer online display fallback`
   - Rust `PeerInfo` online 回退和陈旧状态防回写。
5. 如独立复核发现问题，使用单独修复提交，不改写已审查历史。

## 测试矩阵

- Rust：
  - 切屏槽 latest-wins；
  - release 在切屏前；
  - 旧鼠标/触摸位移被清理；
  - 新请求不受旧 generation 影响；
  - 无效/offline `current_display` 优先首个 online；
  - 旧 display ACK 不回写最新目标。
- native/NAPI：
  - ACK 与关键帧任意先后均需两者齐备；
  - 快速 B -> C 后 B 的 ACK/关键帧无效；
  - NAPI 返回 accepted、generation、pendingDisplay、readyGeneration。
- ArkTS：
  - pending 时阻止输入；
  - 不乐观提交几何；
  - 只接受最新 generation ready；
  - 连续选择 latest-wins；
  - timeout 只提示等待，不绕过目标关键帧屏障。

## 强制门禁

1. 定向 Rust 单元测试与 host native 测试。
2. `git diff --check`。
3. `source scripts/macos_env.sh` 后运行：

   ```sh
   hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
   hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
   ```

4. 独立子 agent 只读复核 Rust/C++/NAPI/ArkTS 状态机和跨协议隔离。
5. 修复复核发现并重跑受影响测试和两项 Hvigor 门禁。
6. 合并回本地 `main`，检查历史与工作树，删除已合并任务分支。

## 外部验收边界

代码闭环后仍需在 API 23 真机连接至少一个具有两个 online 显示器的 RustDesk
被控端，验证 B -> C -> B 快速切换、切换时按住键/鼠标/拖拽/触控、横竖分辨率差异、
Surface 重建、断网恢复和 RDP/VNC/SSH 回归。没有该证据时，不宣称真实设备发布验收通过。
