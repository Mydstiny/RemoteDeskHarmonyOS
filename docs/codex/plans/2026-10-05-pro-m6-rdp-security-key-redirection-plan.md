# M6 第三增量：USB 安全密钥重定向到 RDP（RDPEWA）

状态：IMPLEMENTING（2026-10-05 用户确认开始）。S1 原生通道与代理 `7236c38df`；S2/S3 ArkTS 会话服务、提示界面、实验目录与主机本机开关 `118ffd0d7`；S4 首轮独立复核 FAIL（1 P0、2 P1、5 P2），修复 `726a81084` 经第二轮独立复核 PASS（见第 8 节）；S5 真机验收（PC 统一测试）待执行。手机通行密钥另行做可行性原型。
范围：Pro 目录 `pro.security.webauthnRedirect`。鸿蒙 PC/2in1 上插入的 USB FIDO2 安全密钥，经 MS-RDPEWA 供远端 Windows 会话里的网站和应用注册、登录。不包括 Windows 登录本身、智能卡/PIV、NFC/蓝牙密钥，也不包括手机通行密钥。
基线：`codex/pro-purchase-foundation` @ `0aceeeb67`；前两个增量见 [M6 计划](2026-09-07-pro-m6-fido-transport.md)。

## 0. 现状（代码事实）

| 已有 | 位置 | 说明 |
|---|---|---|
| USB 候选枚举、临时授权、配置/报告描述符校验、非强制 claim、64 字节中断传输、取消 | `services/pro/ProUsbFidoProbe.ets`、`ProFidoHidCodec.ets` | 仅 Debug、仅 PC/2in1、只做 INIT/GetInfo 探测 |
| libfido2 1.17.0 + libcbor 0.14.0 双 ABI 静态库，自定义 I/O（`hid_custom.c` 不枚举、不打开任何设备） | `libs/fido2-ohos/`、`patches/libfido2-ohos/` | 仅 Debug 链接进 `librdpnapi.so`；Release 链接与 ELF 标记由 `check_pro_release.py --fido-library` 拦截 |
| 原生 INIT/GetInfo 传输（请求/应答，ArkTS 执行每次 USB 传输） | `cpp/pro/fido_probe_transport.*`、`fido_probe_napi.cpp` | 单次事务、5 秒期限 |
| FreeRDP 上游 RDPEWA 客户端通道（约 2000 行，基于 libfido2） | `freerdp/channels/rdpewa/client` | 鸿蒙构建未启用（`build_freerdp_ohos.sh` 无 `CHANNEL_RDPEWA`）；通过 `fido_dev_info_manifest` 枚举系统 HID，鸿蒙上恒为 0 个设备 |
| 静态通道注册 | `cpp/rdp/freerdp_adapter.cpp`（`freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, …)`） | 可包装为自有 provider 追加通道 |
| PIN 回调 | 上游通道调用 `instance->AuthenticateEx(..., AUTH_FIDO_PIN)` | 适配层未实现任何交互式认证回调 |

上游通道的已知缺口：`CANCEL_CUR_OP` 是空操作；关闭通道时 `WaitForSingleObject(worker, INFINITE)` 可能永久阻塞；`WLOG_TRACE` 级别会十六进制转储请求和响应（含 challenge 与签名）。

## 1. 决策

1. **不重建 FreeRDP，不改 Release**。把上游 `channels/rdpewa/client` 源码作为 RemoteDesk 自有原生源码（保留 Apache-2.0 版权头并登记来源）放到 `cpp/rdp/rdpewa/`，只在 Debug 编译；用自有 addin provider 包装现有 `freerdp_channels_load_static_addin_entry`，只为 `rdpewa` 返回本地入口。Release 不编译、不链接 FIDO，现有 Release 裁剪门保持不变。正式开放是另一项决策，届时再改 Release 门。
2. **libfido2 不改**。设备由 App 显式提供：通道打开设备时 `fido_dev_set_io_functions` 指向 RemoteDesk 的 I/O，路径为不可猜测的会话内标识；`hid_custom.c` 仍不枚举、不打开任何系统设备。
3. **一个会话、一支密钥、一个在途操作**。设备提供者只返回用户在当前会话中授权的那一支密钥；不做多密钥触摸选择。
4. **每次操作先确认**。远端每次注册或登录请求，先在本机显示“远程电脑上的 `<rpId>` 请求使用安全密钥（注册/登录）”，用户同意后才访问 USB。拒绝、超时、会话断开都向远端返回取消。
5. **PIN 只在本机输入**，由安全输入框收集，直接交给 libfido2，不写日志、不缓存、不跨会话复用；错误次数提示来自设备。
6. **不转储**：去掉请求/响应十六进制日志，只记录命令号、长度、结果码。
7. **权益**：`pro.security.webauthnRedirect` 改为 `experimental`，`devices: ['pc']`、`protocols: ['rdp']`、能力 `SystemCapability.USB.USBManager`、API 23+。只在 Debug 的模拟或沙盒 Pro 下可执行。
8. **开关**：每台 RDP 主机的本机设置“安全密钥重定向”，默认关闭；只保存在本机偏好（按账号与主机引用隔离），不进入云同步和备份，避免改动主机行结构。

## 2. 架构

```text
远端 Windows ──MS-RDPEWA──> rdpewa 通道（cpp/rdp/rdpewa，Debug）
                               │ 设备提供者（C ABI）
                               v
                    RdpSecurityKeyBroker（cpp/rdp/rdp_security_key_broker.*）
                      请求队列：confirm / pin / touch / open / read / write / close / cancel
                               │ NAPI：attach(threadsafe 唤醒) + poll + reply
                               v
             ProRdpSecurityKey（ArkTS，会话绑定）── USB 授权与中断传输（复用 ProUsbFidoProbe 的校验）
                               │
                               v
                    会话内提示：确认 / PIN / 触摸密钥
```

- ArkTS 面向“会话”而不是某个 Broker：监听（唤醒）、释放/关闭提示/触摸通知属于会话，网络恢复重连换了 Broker 也照常送达；请求 ID 进程内单调递增，迟到的应答不会落到新连接的请求上。会话断开、窗口销毁、账号切换、Pro 失效时一次性取消在途请求并唤醒原生等待。
- 原生等待均有期限：确认 60 s、选择密钥 120 s、PIN 120 s；以上提示同时受远端请求自带的 `timeout`（毫秒，按 10 s～10 min 取值）截止。触摸等待由 libfido2 操作超时（60 s）和请求截止时间共同约束。单次 USB 写 2 s；单次读最多等密钥 5 s，另给 ArkTS 1.5 s 余量。期限到达即视为取消。
- ArkTS 端只有在收到唤醒后才轮询，不常驻轮询。

## 3. 分阶段

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| S1 | 引入 `cpp/rdp/rdpewa`（上游源码 + 设备提供者 + 真实取消 + 有界关闭 + 去转储）；Broker 与 NAPI；addin provider 包装；Debug 链接 | 双 ABI Debug 编译；Release 门不变 |
| S2 | ArkTS：USB 设备公共层（从 ProUsbFidoProbe 抽出校验与传输）、ProRdpSecurityKey 会话服务、确认/PIN/触摸提示 | 会话内能完成授权、确认、PIN 往返（无硬件时以假设备测试） |
| S3 | 目录与开关：experimental、主机本机开关、RDP 设置与会话入口、Pro 门控登记 | `test_pro_entry_gating` 等门控测试 |
| S4 | 测试：Broker 原生单测（ASan/UBSan）、ArkTS 策略测试、Release 门回归；四项 Hvigor 门禁；独立复核 | 全部通过 |
| S5 | 真机验收（放到最后的 PC 统一测试）：鸿蒙 PC + FIDO2 USB 密钥 + Windows 11/Server 2022 以上并启用 WebAuthn 重定向 | 见第 5 节 |

## 4. 安全与隐私规则

- 只与用户在当前会话授权的密钥通信；报告描述符必须是 FIDO（Usage Page 0xF1D0），不触碰键盘/鼠标接口。
- 远端提供的 rpId、用户名等只用于本机确认显示，做长度与控制字符清洗；不写入诊断日志。
- PIN、challenge、凭据 ID、签名、公钥不进入日志、诊断包和 AI 证据。
- 不启用凭据管理、重置、生物识别注册等管理命令；`GET_CREDENTIALS` 一律回答“没有可发现凭据”，不碰密钥（登录时仍按允许列表找到凭据）。
- 任何异常都向远端返回取消/错误，不留下半完成的设备操作。

## 5. 验收清单（PC 统一测试时执行）

- SK1 RDP 主机开启“安全密钥重定向”，连接 Windows 11，在远端浏览器打开 webauthn.io 注册：本机出现确认 → 触摸 → 成功。
- SK2 同站登录：确认 → 触摸 → 成功；拒绝确认时远端显示已取消。
- SK3 设置了 PIN 的密钥：PIN 提示、错误 PIN 次数、正确 PIN 成功。
- SK4 在远端点“取消”、拔出密钥、断开 RDP，均能及时结束且应用不卡死。
- SK5 GitHub（或其他真实网站）在远端用安全密钥注册并登录。
- SK6 关闭开关或非 Pro：远端看不到可用的安全密钥；Release 包不含 FIDO 库（`check_pro_release.py --fido-library`）。
- SK7 诊断日志与 AI 证据中不出现 PIN、challenge、签名或 rpId 明细。

## 6. 风险

| 风险 | 对策 |
|---|---|
| 上游通道与 Windows 版本兼容差异 | 记录 Windows 版本矩阵；未通过的版本在说明中列出 |
| ArkTS 主线程繁忙导致 USB 往返延迟 | 只在唤醒后轮询；单次传输期限 1.5 s；触摸等待由设备侧计时 |
| 通道线程与会话销毁竞争 | Broker 代次隔离，关闭时先取消再有界等待 |
| 用户误以为可用于 Windows 登录 | 设置说明明确“仅远程会话里的网站和应用” |
| 授权后的密钥在整个会话内保持占用，本机其他应用不能同时使用 | 有意为之（避免每次操作都弹系统授权）；断开、关闭页面、Pro 失效或拔出后释放；S5 验收时确认对本机浏览器的影响 |

## 7. 实现记录

| 阶段 | 实现 |
|---|---|
| S1 | `cpp/rdp/rdpewa/`（上游通道 + 设备提供者）、`rdp_security_key_broker.*`（纯 C++ 代理，主机 ASan/UBSan 测试 `test_rdp_security_key_broker.py`）、`rdp_security_key_provider.*`（libfido2 自定义 I/O、WinPR 取消事件）、`rdp_security_key_napi.cpp`（Release 为空实现）、适配器 addin provider 包装与生命周期；Release 构建 + `check_pro_release.py --usb-probe --fido-library` 通过，两 ABI Release 无 rdpewa/代理符号 |
| S2 | `ProUsbFidoKey.ets`（候选、授权、描述符复核、非强制 claim、64 字节中断传输、释放取消在途传输）；`ProRdpSecurityKey.ets`（按会话 watch/poll/respond；确认、选密钥、PIN、触摸、读写、释放；Pro 失效即取消并释放）；`RdpSecurityKeyPrompt.ets`（四种提示，PIN 提交与关闭即清空） |
| S3 | 目录 `pro.security.webauthnRedirect` → experimental（PC、RDP、USBManager 能力、API 23）；`ProRdpSecurityKeyPreference`（按账号作用域与主机本机保存，不同步）；RDP 控制中心“安全密钥重定向”行（`securityKeyVisible` 由 `ProEntries.visible` 决定，登记到 `test_pro_entry_gating`）；会话连接时按开关与权益请求通道，连上后启动服务，`disconnectAndCleanup` 停止 |

## 8. 首轮复核修复（2026-10-05）

| 编号 | 问题 | 修复 |
|---|---|---|
| P0-1 | PC 实体键盘下，PIN 会被隐藏的键盘代理转发到远端并写入日志 | 提示打开期间独占输入：键盘代理与按键回调直接吞掉按键且不记录键码；`canForwardInput` 丢弃键鼠输入；不重新抢远端焦点、不捕获系统快捷键；输入法文本不入队。PIN 输入框出现时主动获得焦点；提示关闭后把键盘交还远端 |
| P1-1 | PC 独立窗口接管会话后，服务留在已销毁的源页面 | 源页面在移交完成、被新页面取代、移交后消失时停止服务；接管页面在恢复完成后按会话重新启动。监听带编号，旧页面停止时若监听已被新页面接管，不取消、不改授权 |
| P1-2 | 网络恢复重连后新 Broker 没有唤醒，旧 Broker 的释放通知丢失 | 唤醒与通知改为按会话登记；新 Broker 继承监听；关闭已授权 Broker 时经会话送达“释放” |
| P2-1 | 请求 ID 每个 Broker 从 1 开始 | 进程内单调递增 |
| P2-2 | `GET_CREDENTIALS` 在通道线程上未经确认访问密钥 | 不做设备 I/O，回答空列表 |
| P2-3 | 新请求无限期等待旧请求结束 | 先取消再等待；请求在派发时开始（此后 `CANCEL_CUR_OP` 一定生效），提示受请求 `timeout` 截止 |
| P2-4 | 过期提示不消失；系统授权框期间请求超时后仍占用 USB | 新增 Dismiss 通知；应答返回是否被接受，不被接受即释放密钥；选择密钥前先释放旧占用；Poll 先送释放、关闭提示，再送请求，最后送触摸 |
| P2-5 | 服务器或密钥给出的越界值触发断言崩溃 | flags/command/timeout 超 32 位拒绝请求；算法号超出 int 拒绝；maxMsgSize 等超 16 位截断 |
| P3 | 其他 | 失败的请求也一定回复；标签按 UTF-8 字符截断并去除无效编码；PIN 本地校验（至少 4 个字符、至多 63 字节、无空字符）；PIN 已锁定时只显示说明和关闭；ArkTS 自行释放密钥时通知 Broker 忘记授权；已授权密钥打开失败（拔插）时重新选择一次；开关保存失败时回到实际状态；Release 检查增加 RDPEWA 原生标记与 `ProRdpSecurityKey#available`；修改过的上游文件头注明修改 |

验证：`test_rdp_security_key_broker.py`（ASan/UBSan；另用 TSan 各跑 20 次无报告），新增 `test_pro_rdp_security_key.cjs`（ArkTS 服务：提示、关闭提示、PIN 规则、密钥占用、页面移交），Pro 节点测试全部通过；四项 Hvigor 门禁与 Release 检查结果见提交记录。仍未覆盖：provider/NAPI/通道 C 代码只有编译与真机验收（S5）覆盖。

第二轮独立复核（Opus 5.5，`b0dc68ac7..726a81084`）：PASS，无 P0/P1/P2；复核者另做了 Close/Detach/Attach 约 2200 次的并发压力探针，TSan 与 ASan/UBSan 均无报告。三项 P3 处理如下：

- P3-1：页面在后台被销毁、会话保活时，旧页面的服务没有停止（仍占用 USB 密钥）。已在两处后台保活分支停止服务，接管页面恢复后重新启动。
- P3-2：首轮修复把 NAPI 回复文本上限连同 PIN 一起收紧到 64 字节，较长的密钥名（中文约 22 字以上）被拒，导致无法选中。回复文本上限恢复为 255 字节，由 Broker 按 UTF-8 字符截到 63 字节；PIN 仍由 `ValidPin` 限制在 63 字节。
- P3-3（推测性时序，未改代码）：接管页面恰好在原生网络恢复的断开与重连之间启动服务时，因当时没有打开的 Broker 而监听失败，重连后的请求会超时。S5 验收时增加“独立窗口接管与网络切换同时发生”一项；若复现，再在会话重新连上时补启动服务。同类的轻微问题：失去监听权但尚未停止的旧页面，理论上可能取走一条排队中的通知。
