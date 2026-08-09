# Corresponding source offer

每个 HAP release 页面必须提供与产物完全一致的 source tag、源码归档、
SPDX SBOM、release manifest、RustDesk proto 修订/哈希和第三方来源。
源码长期地址为 `https://github.com/Mydstiny/RemoteDeskHarmonyOS`。

Moonlight 产物一旦进入 HAP，源码归档必须完整包含
`entry/src/main/cpp/moonlight/upstream/moonlight-common-c/`、项目的
`vendor-build/` 与 `patches/`，并保持以下版本不变：moonlight-common-c
`e41355ea01670fd4c830b384009d31dd0339a705`、ENet
`aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`、nanors
`b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a`。归档中的
`UPSTREAM.lock.json`、SPDX 文件记录和
`THIRD_PARTY_ARTIFACTS.sha256` 必须通过
`scripts/verify_moonlight_vendor.py`，因此构建者不依赖网络也能取得并
核验本 HAP 对应的完整上游源码。若任何 project patch 存在，源码归档
必须同时包含补丁、基准 revision、应用顺序和修改说明。

签名证书、口令、AGConnect secret 与用户数据不是对应源码的一部分；
非秘密配置结构和构建说明必须包含在源码归档中。
