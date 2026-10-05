# M6 第三增量：USB 安全密钥重定向到 RDP（RDPEWA）

状态：IMPLEMENTING（2026-10-05 用户确认开始；先做 USB 安全密钥，手机通行密钥另行做可行性原型）
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

- Broker 以“会话代次 + 请求 ID”隔离；会话断开、窗口销毁、账号切换、Pro 失效时一次性取消所有在途请求并唤醒原生等待。
- 原生等待均有期限：确认 60 s、PIN 120 s、触摸由设备超时（最长 30 s）、单次 USB 传输 1.5 s。期限到达即视为取消。
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
- 不启用凭据管理、重置、生物识别注册等管理命令；`GET_CREDENTIALS` 仅在用户确认后执行。
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
