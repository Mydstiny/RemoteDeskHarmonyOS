# 多个画面会话同时存在（平板分屏、PC 多窗口）

2026-10-08，用户决定：原生层改为支持多个画面会话（RDP、RustDesk、VNC）同时存在，包括 PC 上同时开多个独立窗口（含同一协议开两个，例如两台 RDP）。

## 现状（实测与代码）

- 平板工作区「RDP + RustDesk」：RDP 在独立窗口连上后，RustDesk 连接被原生层直接拒绝（`ActivateSharedSessionSinks` 失败 → `E-RUSTDESK-PREFLIGHT-2`）；RDP 断开后 RustDesk 才能连上。
- 原生层已经按会话区分的部分：
  - `SessionRegistry` 本身支持多个会话；
  - 解码、渲染、音频的接口都带 `DecoderSessionIdentity`（会话身份）；
  - RDP 的回调登记按 `rdpContext*` 区分；
  - RustDesk 内核接口按连接句柄区分，并已有 `*_for_session` 变体；
  - SSH 已经是每个会话一个独立的适配器实例（`CreateAdapterForSession`）；
  - 独立窗口协调器（`RemoteSessionWindowCoordinator`）本身支持多个窗口。
- 真正的单会话限制：
  1. `render/shared_session_context.cpp`：`SharedSessionSinkOwnerLease` 只允许一个「当前会话」；
  2. `render/hw_decoder.cpp`：`g_activeDecoderOwner / g_activeDecoderHandle / g_activeDisplay / g_activeNativeImagePresentationMode` 只有一份；
  3. `render/gl_renderer.cpp`：`SetActiveSessionOwner` 只有一份；
  4. `audio/audio_player.cpp`：`g_activeAudioPlayer / g_activeAudioOwner` 只有一份；
  5. `audio/input_handler.cpp`：`activeAdapter_` 只有一份；`extension_loader_napi.cpp` 的 `g_activeConnection` 也只有一份；
  6. `rdp/freerdp_adapter.cpp`：RDP 音频回调 `g_rdpAudioCallback / g_rdpAudioCallbackOwner` 只有一份；
  7. RDP、RustDesk、VNC 的适配器在注册表里每个协议只有一个实例（`FreeRdpAdapter` 自己只持有一个 `instance_`），同协议第二个会话无处安放；
  8. ArkTS 侧：`ActiveRemoteSessionRegistry` 只登记一个当前会话；`HostListPage` 的连接仲裁、`RemoteDesktop` 的后台恢复、独立窗口交接、画中画和实况窗都以这份「唯一当前会话」为准。

## 目标

- 同时存在多个画面会话：平板分屏两个（左右各一），PC 多个独立窗口（数量上限见下），协议任意组合，包括同协议多个。
- 每个会话的画面、输入、剪贴板、文件传输、断开和后台恢复互不干扰；一个会话断开或出错不影响其他会话。
- 单会话的行为（手机、平板全屏、PC 单窗口）与现在完全一致。

## 决定（可改）

- 声音：只播放当前获得焦点的窗口所属会话的声音，其他会话静音；焦点切换时跟着切换。
- 上限：PC 同时最多 4 个画面会话，平板 2 个，手机 1 个（手机保持现状）。超过时提示先关闭一个。
- 输入：键鼠只发给获得焦点的窗口所属会话（按会话 id 路由，不再有全局「当前适配器」）。

## 分步

### 第 1 步：媒体通道按会话分开（原生）

- `shared_session_context`：把「唯一当前会话」改为「已登记会话表」，激活和停用只影响自己那一项。
- 解码器：每个会话一套 `{decoderHandle, display, displayGeneration, presentationMode}`，所有 `*Active*` 接口按传入的会话身份查表（接口签名不变）。
- 渲染器：每个会话一套 owner → renderer 绑定；`GetActivePresentationTarget / PresentRawBgra*Active / SetActiveSourceSize` 按会话身份查表。
- 音频：每个会话一个播放器；加「声音焦点」：只有焦点会话真正出声（ArkTS 侧在窗口获得焦点时调用新接口 `setAudioFocusSession(sessionId)`）。
- RDP 音频回调：从单个全局回调改为按会话登记。
- 输入：`InputHandler` 和 `g_activeConnection` 改为按会话 id 查适配器；现有按会话 id 的发送接口不变。
- 验证：原生单元测试（`entry/src/main/cpp/test`）补「两个会话同时激活、各自解码送显、一个停用不影响另一个」；四项构建门禁。

### 第 2 步：每个会话一个适配器实例（原生）

- `CreateAdapterForSession`：RDP、RustDesk、VNC 也像 SSH 一样每次连接新建实例；注册表里的实例只用于预检（证书探测、网关深度检测等）。
- 逐个检查适配器里的进程级全局状态，按会话区分或确认可共享：RDP（关停票据、会话代号、回调登记——已按上下文区分）、RustDesk（FFI 回调上下文表、IPC 路径、帮助进程——确认可多会话）、VNC（光标代号）。
- 验证：同协议两个会话同时连接、各自断开的原生测试。

### 第 3 步：ArkTS 会话登记改为多个（应用层）

- `ActiveRemoteSessionRegistry`：从「唯一当前会话」改为按会话 id 的表；`getActive()` 保留为「本页面（或本窗口）自己的会话」，新增 `getBySession / list / count`。后台恢复、恢复认领、终止令牌都按会话 id 区分。
- `HostListPage`：连接仲裁按主机区分；超过上限时提示；`remoteVideoSessionBusyMessage` 改为只在达到上限时出现。
- `RemoteDesktop`：渲染器句柄、解码器句柄、画中画、实况窗、安全密钥、剪贴板桥都按本页会话，不再读全局「当前」。
- 声音焦点：独立窗口和分屏窗口获得焦点时设置自己的会话为声音焦点。

### 第 4 步：平板分屏与 PC 多窗口

- 平板工作区：两个画面会话左右分屏都能连上并操作。
- PC：同时打开多个独立会话窗口（不同主机、同一协议多个），各自缩放、全屏、关闭；工作区一次打开多个画面会话。

### 第 5 步：测试与实机验收

- node 源码约定测试：多会话登记、仲裁上限、声音焦点。
- 原生测试：多会话媒体通道、多适配器实例。
- 实机验收（新增 O 节）：平板 RDP + RustDesk、RDP + VNC 分屏；PC 两台 RDP + 一台 RustDesk 同时打开；逐个断开、切后台恢复、声音焦点、剪贴板和文件传输互不干扰；单会话场景与现在一致。
- 每步提交前四项门禁；全部完成后子代理复审。

## 风险

- 媒体通道是所有协议的公共路径，改错会让单会话也出问题：每一步都保持接口签名不变，先让单会话路径完全走新表，再放开多会话。
- 内存与解码器数量：硬件解码器实例有上限，PC 上 4 个会话可能触发软件解码回退，需要实测。
- RustDesk 内核多会话：接口支持，但需实测两个连接同时进行的稳定性。

## 实施记录（2026-10-08）

第 1–4 步一次完成，四项门禁通过，未实机验收（用户稍后按待验收清单 O 节验收）。

**原生层**
- 会话登记（`SessionSinkOwnerLease`）：从「唯一当前会话」改为最多 8 项的会话表，激活、停用只动自己那一项；同一会话的新一代在旧一代停用前仍被拒绝（与以前一致）。不点名的旧接口只在恰好一个会话时生效，几个会话时解析为「无」，绝不落到别的会话。
- 只有 RDP、VNC、RustDesk 之间可以并存；Moonlight 和前台 SSH 页面仍按原来的规则独占（有别的会话时进不来，它在时别的也进不来），与改造前一致。
- 解码器、渲染器、音频播放器：每个会话一个槽位；渲染器的呈现代号对独立画面按渲染器自己计。
- 音频焦点：新增 `setAudioFocusSession`，几个会话同时有声音时只放焦点会话的；焦点会话不在了就都放。
- RDP 声音：预编译的 FreeRDP fake 声音后端不带连接信息，现在在通道加载钩子里包一层，播放时记下所属连接（`freerdp_rdpsnd_get_context`），按连接分发到各自的播放器；已注销的连接不再出声。
- 适配器：RDP、VNC、RustDesk 每次连接都新建实例（注册表里的实例只做证书探测等预检）。
- 断开、全部断开、SSH 分离：按会话 id 找自己的会话身份，不再用「唯一当前会话」。
- 渲染器：用独立 SurfaceId、且创建时不是页面绑定的进程画面的渲染器，只看自己画面的状态（新增 `markRendererSurfaceDestroyed`），并使用自己的呈现代号——它的创建、重新启用、断开都不再推进进程级代号，否则会把另一个会话的画面判为失效而冻住；单会话（含前台恢复、画中画）的渲染器行为不变。
- 解码器的软件后备与硬件解码一样按点名的会话登记，不再落到「唯一当前会话」。
- 新增 `getLivePictureSessionCount`；`requestFrameRefresh`、`rebindActiveVideoPipeline`、`initRenderer`、`initDecoder`、`initAudioPlayer`、`setActiveAudioMute`、`isAudioPlaybackActive` 都可带会话 id；负的会话 id 表示「本页会话还没建立」，渲染器挂起、解码器和播放器直接失败。

**应用层**
- `ExtensionLoader`：每个窗口本来就有自己的实例，现在所有媒体调用都带本实例的会话 id；`connect()` 在发起原生连接前检查上限（PC 4、平板 2、手机 1，返回 -91）。
- `RemoteDesktop`：第一个画面页面照旧用进程级画面；之后、它还在时打开的页面只画到自己的 SurfaceId 上，从不绑定或标记进程级画面（`RemotePictureSurfacePolicy`）。PC 上主窗口页面把会话交给独立窗口时先交出进程级画面，所以单会话的独立窗口仍和以前一样用进程级画面。连接成功后把本页渲染器显式绑定到本会话，被别的会话误领时为本会话重建。窗口获得焦点、连接成功、恢复会话时设置声音焦点。
- `ActiveRemoteSessionRegistry` 没有改成多项：主窗口同一时间只有一个会话页面，每个独立窗口本来就有自己的登记表。

**已知限制（留待实测后处理）**
- 画中画、实况窗服务仍按「一个会话」设计：两个会话同时切后台时只对应其中一个。
- 硬件解码器实例数量的上限需要在 PC 上开满 4 个会话实测。
- Moonlight 页面（改造前就有）：在自己的独占激活之前用不点名的方式创建渲染器，若此时恰好有一个画面会话在别的窗口运行，会被绑到那个会话上；Moonlight 随后被拒绝并清理时，那个会话画面会黑到它恢复为止。以后把 Moonlight 的渲染器改为「本页会话未建立」（-1）即可，需同时核对 Moonlight 的前台恢复路径。
- 复审过程：第一轮 7 条（另一会话推进全局画面代号导致冻屏、软件解码后备不认会话、Moonlight/前台 SSH 的独占、PC 独立窗口交接的画面归属、负会话 id、残留渲染槽位、待认领渲染器被误领）全部修复；第二轮 PASS，顺带加固了连接后重建渲染器和未占用进程画面时的标记。
