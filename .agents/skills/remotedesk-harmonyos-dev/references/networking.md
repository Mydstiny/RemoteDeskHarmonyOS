# 端点、网络变化与连接

核验快照：2026-09-07，`0000d4ca4`。主要来源：[2026-08-29-all-protocol-ipv6-upgrade.md](../../../../docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md)、当前实现及测试。

## 身份与地址各司其职

- 原始输入只进入 parser；通过校验后使用 canonical endpoint。
- hostname/typed server identity 用于信任、证书、route；解析出的 sockaddr、scope index 是本次运行的数据。
- IPv6 socket authority 与 URI authority 的 scope 编码不同；调用对应 formatter，不拼接 `host:port` 字符串解析身份。
- 修改端点时同时检查 UI、保存/重启、迁移、预认证、证书/host key、代理/跳板、控制和数据通道。

入口：[EndpointAddressPolicy.ets](../../../../entry/src/main/ets/services/EndpointAddressPolicy.ets)、[endpoint_address_policy.h](../../../../entry/src/main/cpp/common/endpoint_address_policy.h)、[happy_eyeballs_connector.cpp](../../../../entry/src/main/cpp/common/happy_eyeballs_connector.cpp)。测试：[EndpointAddressPolicy.test.ets](../../../../entry/src/test/EndpointAddressPolicy.test.ets)、[endpoint_address_policy_test.cpp](../../../../entry/src/main/cpp/test/endpoint_address_policy_test.cpp)。

## 默认网络观察

[native_network_observer_state.h](../../../../entry/src/main/cpp/extensions/native_network_observer_state.h) 的 `observeAvailability`：

1. 注册后的首次 callback 建立 baseline，不人为增加 generation。
2. 新网络已经生效后，旧 network ID 的 lost callback 不应终止新连接。
3. 相同 available 状态不代表网络相同；有 identity 时比较 network ID。
4. 无默认网络不证明 LAN/VPN/link-local 目标不可达，新的 socket 尝试仍由实际 I/O 决定。

[native_network_observer_lease.h](../../../../entry/src/main/cpp/extensions/native_network_observer_lease.h) 管理观察者租约，[network_generation_fence.h](../../../../entry/src/main/cpp/common/network_generation_fence.h) 约束过期操作。测试看 [native_network_observer_state_test.cpp](../../../../entry/src/main/cpp/test/native_network_observer_state_test.cpp)、[network_generation_fence_test.cpp](../../../../entry/src/main/cpp/test/network_generation_fence_test.cpp)。

## 协议差异

| 协议 | 必查路径 |
|---|---|
| RDP | 直连与 Gateway 分开；证书身份、预检和正式连接保持 route 一致 |
| RustDesk | ID/relay/direct/presence/file transfer 分开；取消不能误入 relay fallback |
| SSH/SFTP | proxy、每一跳 host key、forward target、认证/channel/SFTP 与 teardown 都检查 generation |
| VNC | 直连、repeater/gateway、TLS identity 与实际端点 |
| Moonlight | discovery、HTTPS control、stream media 不共享“一个 socket 成功即全通”的假设 |

## 能力与验收

[Ipv6CapabilityPolicy.ets](../../../../entry/src/main/ets/services/Ipv6CapabilityPolicy.ets) 的核验快照仍返回关闭的产品能力位。计划中的 M0–M4 代码完成不等于能力已经正式发布；后续使用时重新读取该文件。

双栈竞争检查共同 deadline、每个候选 socket 所有权、loser 取消、会话取消、DNS/路由变化和背压。RustDesk UDP/KCP/NAT 需要固定版本 hbbs/hbbr、受控 peers、对称 NAT/CGNAT/UDP blocked/TCP only/IPv6 only/NAT64/relay fallback 矩阵，不能从本机单测推定完成。

诊断仅输出协议、阶段、地址族、代次和脱敏错误；不记录完整地址、接口名、relay token 或密码。解析出的候选族不能冒充实际获胜连接的地址族。
