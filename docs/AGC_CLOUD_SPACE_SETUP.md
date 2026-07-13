# AGC 云空间配置清单

> RemoteDesktop — 华为云空间端云同步

## 容器名称

```
remotedesktop
```

---

## 数据类型 1: remotehosts (远程主机)

**主键**: `id` (String, 勾选"端侧去重主键")

| 字段名 | 字段类型 |
|--------|----------|
| `id` | String |
| `userid` | String |
| `label` | String |
| `protocol` | String |
| `host` | String |
| `port` | Integer |
| `username` | String |
| `password` | Encrypted String |
| `customhostname` | String |
| `sshusekey` | Integer |
| `sshkeypath` | String |
| `sshkeydata` | Encrypted String |
| `proxyhost` | String |
| `proxyport` | Integer |
| `proxyusername` | String |
| `gatewayhost` | String |
| `gatewayport` | Integer |
| `displayconfig` | String |
| `locked` | Integer |
| `locktype` | Integer |
| `isfavorite` | Integer |
| `groupid` | String |
| `sortorder` | Integer |
| `icon` | String |
| `lastconnected` | Integer |
| `lasthealth` | Integer |
| `lastlatency` | Integer |
| `syncversion` | Integer |
| `createdat` | Integer |
| `updatedat` | Integer |

共 30 字段

---

## 数据类型 2: sshkeys (SSH 密钥)

**主键**: `id` (String, 勾选"端侧去重主键")

| 字段名 | 字段类型 |
|--------|----------|
| `id` | String |
| `userid` | String |
| `label` | String |
| `keytype` | Integer |
| `publickey` | String |
| `privatekey` | Encrypted String |
| `fingerprint` | String |
| `comment` | String |
| `locked` | Integer |
| `locktype` | Integer |
| `syncversion` | Integer |
| `createdat` | Integer |
| `updatedat` | Integer |

共 13 字段

---

## 数据类型 3: totpentries (TOTP 2FA 条目)

**主键**: `id` (String, 勾选"端侧去重主键")

| 字段名 | 字段类型 |
|--------|----------|
| `id` | String |
| `userid` | String |
| `issuer` | String |
| `account` | String |
| `secret` | Encrypted String |
| `algorithm` | Integer |
| `digits` | Integer |
| `period` | Integer |
| `iconurl` | String |
| `locked` | Integer |
| `locktype` | Integer |
| `syncversion` | Integer |
| `createdat` | Integer |
| `updatedat` | Integer |

共 14 字段

---

## 配置步骤

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
2. 进入项目 → 左侧"构建" → **云空间服务**
3. 创建容器 → 名称填 `remotedesktop`
4. 数据类型配置 → 依次创建上述 3 个数据类型
5. 每个数据类型: 添加字段 → 保存
6. 全部完成后 → **实施变更到生产环境**

## 部署步骤

配置完成并发布后:

```bash
# 两台设备卸载旧版
hdc -t 192.168.31.223:40123 shell bm uninstall com.example.remotedesktop
hdc -t 192.168.31.222:38451 shell bm uninstall com.example.remotedesktop

# 构建并部署新版
```

然后按照 `docs/CLOUD_SYNC_TEST_CHECKLIST.md` 执行双设备同步验证。
