# 远程 AI 插件改动（2026-10-07，待同步回插件仓库）

本机正在运行的插件副本已经改好并通过联调：DSH `0.3.0-c1f1cb7`、Codex `0.3.0-codex01592-a0788dc`、Claude Code `0.2.0-82f7608`。Claude Code 插件随后改成了 Pi 插件，改动见 `2026-10-07-pi-plugin.md`。
插件源码不在这台 Mac 上，以下改动需要同步回各自的 GitHub 仓库。代码差异见同目录的 `2026-10-07-compact-pairing-qr-plugin.patch`。

## 1. 精简配对二维码（三个插件）

- 二维码只放 `{caSha256, code, expires, serverInstance}`，约 198 字节，二维码从 153×153 格降到 57×57 格。完整邀请仍保留在文本框和配对链接里。
- `caSha256` 是 CA 证书 DER 的 SHA-256，用 base64url 编码、不带补位。
- App 端（a843b95df）在握手时从服务端证书链取出指纹一致的 CA，严格校验服务端证书和地址后才发送配对码。

## 2. 列出电脑本机的对话（Codex、DSH）

- bridge-core `session.list` 的第一页会调用 `importNative(project)`。
  - 它把项目目录下最新的 100 个本机对话登记为 bridge 会话，`upstream` 指向原生 thread，标记 `nativeImported`。
  - 列表行返回 `origin: "computer" | "remote"`。
  - 同一项目 15 秒内不重复扫描；扫描失败不影响列表，原因写入 service.log（`{"nativeImport": …}`）。
  - `SESSION_LIMIT` 从 1000 提到 5000。
- Codex 适配器 `nativeSessions`：
  - 用 `thread/list`（按 cwd）列出顶层对话，排除子代理和临时对话；
  - 标题取 thread 名，或首条提示的第一行。
- DSH 适配器 `nativeSessions`：
  - 用 `ctx.sessionQuery.listSessions()` 按 `header.cwd` 过滤；
  - 标题取最新的 `session/title`，或首条用户提示，并缓存 60 秒；
  - 导入时以原生 session id 作为 bridge 会话 id，因为 DSH 的事件和 agent 都按这个 id 关联；
  - 恢复时 `upstream` 保留原值。

## 3. 本机部署配置改动（不在代码里，换机或重装时要重做）

- **Codex 服务改用用户本人的 Codex 目录**：`~/.remotedesk/codex/service.json` 和 LaunchAgent plist 里的 `CODEX_HOME`，都从 `~/.remotedesk/codex/codex-home` 改为 `~/.codex`。
  - 只改 plist 不够：`serve` 启动时会用 service.json 再覆盖一次。
  - 改后在手机上新建的对话也会出现在 Codex 桌面版里。
  - 之前在隔离目录里的 3 个测试会话无法再打开。
- **DSH 的插件运行副本不止一份**：DSH 在 profile `~/.dsh/profiles/remotedesk` 里运行插件，同一改动还要复制到以下两处：
  - `node_modules/@remotedesk/dsh-plugin/src/dsh-adapter.mjs`
  - bridge-core 的 `lib/server.mjs`（嵌套副本和 `.dsh-module-fallback` 副本）
- **新增项目**：两个插件都已用 `project-add` 加入以下项目。电脑桌面根目录范围太大，没有加。
  - `remotedesk` = RemoteDeskHarmonyOS
  - `wallpaper` = wallpaper_engine
  - `baoyan` = 本地保研复试训练系统
  - `livis` = Livis
- **设备授权**：已配对设备的项目授权在配对时就固定了，所以手机需要用包含新项目的邀请重新配对。
- **测试客户端**：联调用的只读客户端 `clients/codex-native-test` 和 `clients/dsh-native-test`，在两个插件的设备列表里各占一条，可以撤销。

修改前的原文件备份在本次 session 的 scratchpad `plugin-backup/` 目录。
