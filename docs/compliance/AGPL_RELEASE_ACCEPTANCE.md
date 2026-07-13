# AGPL release acceptance

公开二进制必须同时满足：所有权/第三方范围已确认；秘密已轮换；SBOM、
hash、source tag 和 manifest 一致；clean clone 可构建；双 ABI 和 NAPI
导出无非预期差异；四协议、CloudSync、主机锁、后台恢复及 About 设备
矩阵通过。任何 `UNRESOLVED` 或 `NOT VERIFIED` 都阻止 release。
