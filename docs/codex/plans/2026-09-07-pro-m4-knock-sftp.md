# M4：碰一碰文件接收与 SFTP 上传

- 当前状态：代码与 Release 产物独立复核 PASS，设备验收待完成；继续 `codex/pro-purchase-foundation`。每阶段单独 commit；未通过真实 PC 接收与远端完整性验收前保持 experimental。
- 范围：API26、鸿蒙 PC/2in1、当前可见的 SSH 工作区 SFTP 页面；最多 16 个普通文件、合计 512 MiB。
- 依据：本机 API26 SDK `@hms.collaboration.harmonyShare.d.ts` 的 dataReceive、ReceiveCallback、ReceivableTarget；UIContext.getWindowName、WindowProperties.windowRect；FileIO/StatVFS 声明。

## 数据与生命周期

1. Debug 模拟 Pro 可显示已实现的 experimental 入口；Release 不包含实验授权路径，真实 Pro 也不能执行未发布能力。
2. 用户主动准备接收，注册精确的 UI 实例 windowId；等待最长两分钟。开始回调时捕获的账号/权限、页面、SSH 会话 generation、主机和目录必须仍一致。
3. API26 碰点与当前窗口屏幕像素矩形核对；越界拒绝、缺失或无效时明确提示并确认目录。此阶段的目标为应用持有的 SFTP 目录，不推断远端桌面像素对应的文件路径。
4. 官方 Share Kit 仅获本次新建空缓存目录授权。收到完成回调后验证每条 URI 在该目录内，拒绝符号链接、目录、特殊文件、越界、超量和变更文件。
5. 以 64 KiB 分块复制到应用沙箱中的独立 SFTP 批次源，每次 I/O 检查租约；检查空间和复制后的文件身份/长度。无需新增本机公共目录授权。
6. 沿用 SFTP 批次队列、显式同名冲突处理、分块写入、部分文件校验、原子远端提交和取消操作。批次提交前重新鉴权，提交后按既有传输引擎安全收尾；暂存源在完成或明确丢弃后清理。
7. 切后台、隐藏页面、关闭文件页、切主机/目录、断连、账号/模拟模式变化立即注销接收并失效在途回调。系统没有公开的 receive 取消方法：取消后阻止远端投递，等终态回调再清理，不能把 off 说成系统传输已取消。

## 验证与交付边界

- Host：真实生产服务的回调顺序、取消/迟到、重复投递、越界/符号链接、分块复制及文件完整性；实验入口设备/协议限制；Release 实际字节码剔除。
- 本次必须运行：default@OhosTestCompileArkTS、signed assembleHap、Release assembleHap、Light、git diff --check；代码 commit 后独立复核。
- 设备未验收：API26 PC 的真实手机碰触、窗口/密度/多屏坐标、SFTP 目标文件完整性、磁盘不足/断网/冲突/大文件及退出清理；API23 冷启动回退。
- 尚未覆盖：RDP 文件剪贴板、RustDesk 文件投递、远端桌面坐标变换。M4 首阶段选择 SFTP；VNC/Moonlight 不提供通用落盘承诺。
- 系统未返回任何终态时，已失效的接收缓存不会被主动删除，以免与系统写入竞争；后续设备验证需确认异常退出后的平台清理行为。

## 本轮实施与独立复核

- 实现 `02a8cab6`；复核修正 `ee45030b`。接收文件写入前统一规范化名称，空白名称回退为 received-file，并以实际写入名称生成批次。
- 私有 Preferences 先同步登记本应用新建 incoming 源目录，再交给复制/传输。冷启动只清理账本内的旧目录；不扫描并删除同名前缀的用户目录，链接只 unlink，当前进程的活跃批次不重扫。重启后的未完成批次需要重新选择来源。
- 16 文件/512 MiB 是收到之后的验证上限；官方接口没有接收前大小信息或公开取消能力，不能保证系统在校验前不写入更大的缓存。系统在途缓存与批次来源账本分别处理。
- 定向检查：14 knock + 26 runtime PASS，包含真实 stage→plan→provider 路径、部分写入、跨账号/会话失效及只清理登记目录。
- 最终代码门禁：default@OhosTestCompileArkTS BUILD SUCCESSFUL in 10 s 505 ms；signed Debug assembleHap BUILD SUCCESSFUL in 23 s 776 ms；Release BUILD SUCCESSFUL in 53 s 378 ms；Light/diff PASS。
- Release ABC SHA-256：6ce24744096c344e00fe0548237452c3ad456673d94b1700651b02f01f3fc8b3。实际字节码审计确认调试模拟与实验授权分支不可执行。
- 同一独立 reviewer `/root/review_pro_plan` 对精确实现/修正重查 PASS，并独立重跑 14+26 检查与 Release 审计；两项 P2 均关闭。结论仅覆盖代码/实验入口，未代替上面的真实设备验收。
