# 手机通行密钥原型（方案 B）

状态：PROTOTYPE（2026-10-05 用户确认按方案 B 开始；同日要求继续完善，P1 与 P2 都做）。P1（任意页面接收、设备配对与请求签名、管理界面）已实现，待手机 + 平板实测；P2（RDP 接入）进行中，需鸿蒙 PC 验收。
范围：Pro 目录 `pro.security.phonePasskey`（experimental，仅 Debug）。

## 1. 为什么是方案 B

- 鸿蒙 `@hms.security.fido2`（OnlineAuthenticationKit）由系统生成 clientData（含 origin），不接受外部 clientDataHash，且 RP 必须与应用关联域名一致；应用无法用它替远程网站签名。手机浏览器能给 GitHub 用通行密钥，是因为浏览器是系统特许的调用方。
- 扫码跨设备（CTAP hybrid）需要实现蓝牙广播、隧道服务器和 Noise 握手，且依赖华为手机接受第三方发起的扫码，不确定性大。
- 方案 B：RemoteDesk 自己做一个“设备绑定的软件认证器”。PC 上的 RemoteDesk 把远端的 WebAuthn 请求经同账号设备通道发给手机上的 RemoteDesk；手机让用户确认，再用系统密钥库里、绑定生物识别的私钥签名。只在 RemoteDesk 的远程会话里有效，每个网站需在远程会话里注册一次。

## 2. 原型实现

| 模块 | 内容 |
|---|---|
| `services/pro/passkey/ProPasskeyCodec.ets` | 纯函数：base64url、WebAuthn authenticator data（rpIdHash、UP/UV/AT、signCount、attested credential data）、COSE EC2（ES256）公钥、从 HUKS 导出的 SPKI 取 P-256 坐标、设备间请求/应答的严格校验、请求时效 |
| `ProPasskeyKeys.ets` | HUKS P-256 密钥：`HUKS_TAG_USER_AUTH_TYPE` 绑定人脸/指纹（无生物识别时锁屏密码），`HUKS_AUTH_ACCESS_ALWAYS_VALID`（新录入指纹不使旧通行密钥失效），`HUKS_CHALLENGE_TYPE_NORMAL`：每次签名 initSession → 用 challenge 调系统用户认证 → 带 auth token finishSession；私钥不出 HUKS |
| `ProPasskeyStore.ets` | 通行密钥元数据（网站、用户、别名、解锁方式、计数），本机 Preferences，按账号作用域，不同步 |
| `ProPasskeyAuthenticator.ets` | 注册：排除列表 → 生成密钥 → 导出公钥 → authData（attestation `none`）→ 用新密钥签一次完成本人验证（失败删除密钥）；登录：按 allowList/网站选凭据 → 计数 +1 → 签名 authData‖clientDataHash |
| `ProPasskeyChannel.ets` | 官方分布式数据对象：会话号 = `rd_` + SHA-256("RemoteDesk:passkey:v1:" + 账号作用域) 前 32 位，同账号设备算出同一个；一问一答；晚加入的设备不回答已有请求；不回答本机发出的请求；请求带发送时间，超出“有效期 + 1 分钟”丢弃 |
| `ProPasskeyDevice.ets` | 每台设备一把 HUKS P-256「设备身份密钥」（无需生物识别，只表明是哪台设备在请求）；设备 ID = 公钥 SHA-256 前 16 字节；为请求签名；六位配对码 |
| `ProPasskeyPeers.ets` | 手机上的已配对设备（名称、公钥、配对与最近使用时间）与「接收登录请求」开关，按账号作用域本机保存，不同步 |
| `ProPasskeyReceiver.ets` | 全局接收：应用在前台且开关打开时加入通道，已配对设备的签名请求在任何页面弹出确认（系统对话框），后台时暂停；未配对或签名无效的请求直接拒绝；配对请求显示配对码由用户核对 |
| `components/pro/passkey/ProPhonePasskeyPanel.ets` | 设置 → Pro 功能 → 手机通行密钥：接收开关与确认卡片、已存通行密钥列表（删除同时删 HUKS 私钥）、测试注册/登录（请求端像网站一样校验 rpIdHash、标志位、凭据、COSE 与 SPKI 一致性和 ES256 签名） |

请求端只在测试里由另一台设备扮演；正式路径中请求端是 PC 上的 RDP 会话（第 4 节）。

## 3. 安全边界（原型）

- 通道信任依赖华为账号的可信设备网络（分布式数据对象只在同账号已组网设备间同步并由系统加密）。在此之上（协议 v2）：
  - 每个请求由发起设备的设备身份密钥签名（覆盖除签名外的全部字段），手机只接受「已配对设备」的有效签名，显示的是配对时确认的设备名，而不是请求自报的名称。
  - 配对：发起设备发送带公钥的配对请求；两台设备用同一算法（`RemoteDesk:pair:v1:` + 公钥 + 请求 ID 的 SHA-256）算出六位配对码，用户在手机上核对一致后确认。这样同账号下其他设备无法冒充已配对设备。
  - 未覆盖：发起设备对手机身份的认证。注册结果按首次使用信任，登录结果按注册时的公钥校验签名，冒充手机的设备无法通过登录校验。
- 每个请求都需要用户在手机上点“允许”，随后系统验证人脸/指纹/锁屏密码；不缓存认证。
- 一次只处理一个请求，新的请求直接回拒绝，不让请求方空等。
- 不打印 challenge、签名、凭据 ID；手机只显示请求设备名和网站。
- 手机需开启“接收登录请求”且应用在前台（任何页面均可）；应用在后台时暂停接收，第三方应用不能跨设备拉起，正式版需评估推送（Push Kit）唤起。

## 4. 下一步：RDP 接入（需要鸿蒙 PC）

1. 在 RDPEWA 的“选择安全密钥”提示里增加“使用手机通行密钥”。
2. 选中后，原生通道把解析好的 makeCredential/getAssertion（rpId、clientDataHash、user、排除/允许列表）经代理交给 ArkTS，ArkTS 经本通道发给手机；手机返回 authData、签名、凭据 ID，原生用 libcbor 编码 CTAP 应答（fmt `none`）回给远端 Windows。
3. 验收：鸿蒙 PC 远程 Windows，在 webauthn.io 与 GitHub 注册并登录；手机拒绝、超时、断开均能及时取消。

## 5. 原型测试步骤（手机 + 平板，同一华为账号，均为本 Debug 包）

1. 两台设备：设置 → Pro 功能 → 手机通行密钥。首次会请求“多设备协同”权限。
2. 手机：打开“接收登录请求”（开关会保存，下次打开应用自动接收），然后可以离开该页面，停在任何页面即可。
3. 平板：点「与手机配对」→ 平板显示六位配对码；手机弹出“配对新设备”对话框，核对配对码一致后点「一致，配对」→ 平板显示“配对成功”；手机“已配对的设备”出现平板。
4. 平板：点“测试注册” → 手机（任何页面）弹出“「平板名」请求为「remotedesk.test」注册新的通行密钥” → 允许 → 验证人脸/指纹/密码 → 平板显示“注册成功 … 均校验通过”。
5. 平板：点“测试登录” → 手机允许并验证 → 平板显示“登录成功 … 签名校验通过（计数 1）”。再登录一次计数应为 2。
6. 手机：拒绝一次请求，平板应显示“对方拒绝了请求”；在手机上「解除」平板的配对后再测试登录，平板应显示“手机还没有与这台设备配对”。
7. 手机切到后台（或锁屏）时平板发起请求：手机不弹窗，平板 90 秒后显示无应答；手机回到前台后恢复接收。

## 6. 验证记录

- 2026-10-05 P1：协议 v2（签名请求、配对请求、六位配对码、配对成功的空应答）；`test_pro_passkey_codec.cjs` 增加签名内容覆盖、改动任一字段签名内容即变化、Node 设备密钥签名验签、配对码两端一致与格式、v1 请求被拒等用例，全部通过。

- `test_pro_passkey_codec.cjs`：base64url、COSE/SPKI（与 Node 生成的 P-256 公钥比对）、authData 布局、Node 签名按 WebAuthn 规则验签、请求/应答合法与非法样例、时效窗口，全部通过。
- 四项 Hvigor 门禁与测试登记检查通过；Pro 入口门控、权益、功能状态、USB 测试通过。
- 设备测试待执行（第 5 节）。
