# RDP / RustDesk 局域网发现主机地址策略计划

> 任务分支：`codex/moonlight-complete-upgrade`
> 记录日期：2026-08-22
> 用户边界：只有从局域网搜索结果进入添加流程的 RDP / RustDesk 直连主机需要选择静态或动态地址；手动填写地址保持既有静态配置和云同步行为。

## 1. 产品合同

| 添加来源 | 用户选择 | 持久化与同步 | 地址更新 |
| --- | --- | --- | --- |
| 手动填写 RDP / RustDesk 直连 | 不显示新选择 | 既有 `remotehosts`，按现有选择参与云同步 | 不自动改地址 |
| 局域网搜索结果 | 静态 IP | 既有 `remotehosts`，按现有选择参与云同步 | 不自动改地址 |
| 局域网搜索结果 | 动态 IP | 当前 owner 物理库的非分布式本地扩展；不得写入、迁移到或触发 `remotehosts` 云上传 | 进入主机页、前台恢复和连接前按稳定身份重新发现，匹配后原子更新本地地址 |

从局域网结果进入认证步骤时必须显式选择静态或动态，并在同屏说明：静态可云同步但地址变化后需手动修改；动态仅本机保存但会自动更新 IP。没有做出选择不能保存。

## 2. 稳定身份与发现

- RustDesk 继续使用官方 UDP `PeerDiscovery`，稳定身份为响应中的 peer ID，连接端口仍使用 peer TCP 端口。
- RDP 在添加页使用用户当前填写的端口。通过 API 23 `connection.getDefaultNet()` / `getConnectionProperties()` 读取当前 IPv4 链路，在有界子网内并发 TCP 探测；开放端口必须再由现有 FreeRDP 证书预检确认，稳定身份为规范化证书 SHA-256 指纹，展示名优先使用证书 Common Name。
- RDP 端口开放但没有稳定证书身份的结果不得承诺动态更新；允许作为静态发现结果保存，动态选项必须禁用并解释原因。
- 扫描有 generation/cancel fence、并发和地址数量上限，不扫描 IPv6、回环、本机地址、网络地址或广播地址；大于 `/24` 的网络只扫描本机所在 `/24`，避免无界探测。

## 3. 数据边界

`RemoteHost` 增加兼容字段：

- `lanAddressMode`: `manual | static | dynamic`，旧行缺失时归一为 `manual`；
- `lanDiscoveryIdentity`: 稳定发现身份；
- `lanLastResolvedAt`: 最近成功解析时间。

静态/手动主机仍走原 `remotehosts` CRUD。动态主机完整业务记录进入 `localextensions` 的独立命名空间，密码字段使用当前 owner、reset epoch 和独立 AAD 加密；本地记录不写 mutation journal、不请求 `remotehosts` automatic push。读取时由 `HostSyncService` 合并到可见目录，账号切换按既有物理 store/generation 隔离。

动态记录的新增、修改、删除、本机健康/最近连接、RDP 证书信任和 Restricted Admin 本机 secret 必须保持同一 host ID。静态/动态存储类型不允许由普通编辑隐式转换，避免产生一份本地行和一份云行。

## 4. 自动刷新

刷新器按协议和端口合并扫描：一次 RustDesk 广播服务所有动态 RustDesk 主机；相同端口的动态 RDP 主机共享一次子网扫描。只有稳定身份完全匹配时才更新：

- RDP 同时更新 `host`；端口保持该记录配置；
- RustDesk 同时更新 `host`、`port`、`rustdeskDirectHost`、`rustdeskDirectPort`；
- 未找到、身份变化、扫描失败或账号 generation 变化时保留旧地址，不删除、不改云端、不跨 owner 写入。

连接前刷新有短时 freshness 窗口，避免刚完成的页面刷新又重复扫描。刷新失败不绕过现有锁、证书、认证、2FA 或独立窗口路径；它只决定连接前使用哪个本地地址。

## 5. 实施与验收

1. 先落纯策略、模型兼容和测试，再实现本地存储路由。
2. 接入 RDP 当前端口扫描与两个添加流程的显式策略 UI。
3. 接入自动刷新生命周期和连接前刷新。
4. 定向测试覆盖：旧行兼容、手动路径不变、静态可云路由、动态拒绝云路由、稳定身份匹配、错误身份不更新、RDP 子网边界、RustDesk peer 匹配、持久化/删除/账号隔离。
5. 运行 `default@OhosTestCompileArkTS`、`assembleHap`、`git diff --check`、Light 合规门；独立 reviewer 比对用户需求、计划、diff 和验证证据。

真实设备验收需补充：至少一个 DHCP 地址变化的 Windows RDP 主机和一个 RustDesk peer，验证重新发现后卡片与连接使用新 IP，同时云端不存在动态主机行。
