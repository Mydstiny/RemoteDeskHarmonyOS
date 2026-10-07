import { AiBackend } from './AiModels';

export type AiInstallMode = 'local' | 'lan';
export interface AiInstallRelease {
  name: string;
  repository: string;
  version: string;
  protocol: number;
  engine: string;
  commit: string;
  asset: string;
  sha256: string;
}

/**
 * The Gitee owner that mirrors the plugin repositories (same commits as GitHub), for computers that cannot reach
 * GitHub; '' until the mirror exists, and the prompts then name GitHub only.
 */
export const AI_PLUGIN_GITEE_OWNER: string = '';

// Public, version-pinned metadata from the reviewed native-host handoff.
// Callers own their copy; no account, host configuration or invitation is read.
export function aiInstallRelease(backend: AiBackend): AiInstallRelease {
  // Every plugin installs from its pinned source commit (the fixes after the v0.3.0 packages, such as approvals that
  // survive a lapsed lease, are in no release package), so there is no asset or checksum to show.
  if (backend === 'codex') {
    return { name: 'Codex', repository: 'Mydstiny/remotedesk-codex-plugin', version: '0.3.0', protocol: 1,
      engine: 'Codex CLI 0.153.4', commit: '7e3fe3fff01242a2d664a7df88001ab6d78604a5', asset: '', sha256: '' };
  }
  if (backend === 'dsh') {
    return { name: 'DSH', repository: 'Mydstiny/remotedesk-dsh-plugin', version: '0.3.0', protocol: 1,
      engine: 'DSH 0.1.2-rc.1', commit: 'bbf715fb054f52f1aacd7ccbe5c5b029526de547', asset: '', sha256: '' };
  }
  if (backend === 'pi') {
    return { name: 'Pi', repository: 'Mydstiny/remotedesk-pi-plugin', version: '0.3.0', protocol: 1,
      engine: 'Pi 1.0 或更新（@earendil-works/pi-coding-agent）', commit: 'f0f8fad88f4035968e22fe64d7f0a33e064da3f1',
      asset: '', sha256: '' };
  }
  throw new Error('Unsupported AI installation backend');
}

export function aiInstallManualUrl(backend: AiBackend): string {
  const release = aiInstallRelease(backend);
  return 'https://github.com/' + release.repository + '/blob/' + release.commit +
    (backend === 'pi' ? '/README.md' : '/docs/operations.md');
}

/** The plugin's Gitee mirror ('' while there is none). */
export function aiInstallMirror(backend: AiBackend): string {
  if (AI_PLUGIN_GITEE_OWNER === '') { return ''; }
  return 'https://gitee.com/' + AI_PLUGIN_GITEE_OWNER + '/' + aiInstallRelease(backend).repository.split('/')[1];
}

interface AiInstallEngine {
  /** The plugin's command, its bridge port and its loopback control-panel port. */
  bin: string;
  port: number;
  panelPort: number;
  /** What must already work on the computer. */
  requires: string;
  /** How the plugin uses the engine and what to configure for it. */
  setup: string;
  /** Where the computer app's own projects and conversations come from. */
  native: string;
}

function aiInstallEngine(backend: AiBackend): AiInstallEngine {
  if (backend === 'dsh') {
    return { bin: 'remotedesk-dsh.mjs', port: 9444, panelPort: 9544,
      requires: 'DSH 0.1.2-rc.1 与 pnpm 已能在这台电脑上运行，并已在 DSH 里配置好要用的模型。',
      setup: 'DSH 默认创建独立 RemoteDesk profile（~/.dsh/profiles/remotedesk）。不要停止承载当前对话的 DSH，不接管或重复启动原有 web profile。新 profile 无法使用现有模型登录时，通过原生流程让我配置，不复制账号密钥。插件在这个 profile 的 node_modules 里也有运行副本，升级时要一起更新。源码安装后在程序目录运行 npm ci --omit=dev（只安装仓库 vendor 里自带的 bridge-core，不联网下载其他包）。',
      native: 'DSH 的工作区会作为电脑 App 里的项目出现，工作区里已有的会话也能在手机上继续。' };
  }
  if (backend === 'pi') {
    return { bin: 'remotedesk-pi.mjs', port: 9445, panelPort: 9545,
      requires: '已安装 Pi 1.0 或更新（npm i -g @earendil-works/pi-coding-agent），并至少登录过一个模型提供方（在 Pi 里 /login，或在 pi-gui 里登录）。',
      setup: 'Pi 插件使用我电脑上已安装的 Pi 和它已登录的模型提供方，与 Pi 终端、pi-gui 共用 ~/.pi/agent 里的对话；不读取、不复制 Pi 的凭据，也不加载 Pi 扩展。插件通过 Pi 的 SDK 运行，不需要另装依赖。权限分三档：只读（默认，只能读和搜索）、修改前询问（每条命令、每次改文件都先在手机上批准）、完全访问。pi-gui 会一直占用它打开过的对话，直到在 pi-gui 里关闭该对话或退出 pi-gui；这期间手机只能查看，可以在手机上「复制到新对话继续」。',
      native: 'pi-gui 的工作区和所有有过 Pi 对话的文件夹会作为电脑 App 里的项目出现，里面的对话可以在手机上继续。' };
  }
  return { bin: 'remotedesk-codex.mjs', port: 9443, panelPort: 9543,
    requires: 'Codex CLI 0.153.4 已安装并登录（Codex App 或 codex login 的现有登录即可）。',
    setup: 'Codex 保留现有会话、账号和配置，通过受支持的现有登录使用 provider/model。使用原生工具、默认只读沙箱和按需审批，不覆盖整个 Codex 配置。服务默认使用 state 里独立的 CODEX_HOME；如果我希望手机看到 Codex App 里的对话、手机上的对话也出现在 Codex App 里，先问我，再把服务环境的 CODEX_HOME 改为 ~/.codex：service.json 和后台服务定义都要改，因为 serve 启动时会以 service.json 为准。',
    native: 'Codex App 里的项目会作为电脑 App 里的项目出现，项目目录下的 Codex 对话也能在手机上继续（需使用我的 CODEX_HOME）。' };
}

export function aiInstallPrompt(backend: AiBackend, mode: AiInstallMode): string {
  if (mode !== 'local' && mode !== 'lan') { throw new Error('Unsupported AI installation mode'); }
  const release = aiInstallRelease(backend);
  const engine = aiInstallEngine(backend);
  const source = 'https://github.com/' + release.repository;
  const mirror = aiInstallMirror(backend);
  const pinned = source + '/blob/' + release.commit + '/';
  const local = mode === 'local';
  const command = 'node bin/' + engine.bin;
  const connection = local ?
    '连接方式：仅本机准备。服务仅监听电脑回环地址，不监听局域网或公网，不修改防火墙、路由器或端口转发；本轮不进行手机连接。' :
    '连接方式：局域网连接。先确认电脑上的监听网卡与端口，只绑定所选局域网地址；不开放公网、不配置 RustDesk 中继。防火墙或其他网络配置变更须另行确认。';
  const fromSource = release.asset === '';
  const documents = backend === 'pi' ?
    [pinned + 'README.md', pinned + 'docs/compatibility.md', pinned + 'SECURITY.md', pinned + 'compatibility.json'] :
    [pinned + 'docs/agent-deploy.md', aiInstallManualUrl(backend), pinned + 'SECURITY.md', pinned + 'compatibility.json'];
  const lines: string[] = [
    '请在这台电脑上为我安装并配置 RemoteDesk ' + release.name + ' 插件 ' + release.version +
      '，让我能用手机或平板上的 RemoteDesk 查看和操控电脑上的 ' + release.name + '。按以下范围完成电脑端验收。',
    connection,
    '一、固定版本与来源',
    '仓库：' + source,
    fromSource ? (backend === 'pi' ? '发行方式：尚无发行包，从固定提交的源码安装' :
      '发行方式：从固定提交的源码安装（v' + release.version + ' 发行包之后的修复只在源码里，不要改用发行包）') :
      '发行页：' + source + '/releases/tag/v' + release.version,
    '固定提交：' + release.commit
  ];
  if (mirror !== '') {
    lines.push('优先使用 GitHub。先用 git ls-remote ' + source + '.git 检查能否连接；连不上（超时、被拒绝或 DNS 失败）时改用 Gitee 镜像：' +
      mirror + '（与 GitHub 同一份提交，克隆地址 ' + mirror + '.git）。镜像同样检出上面的完整提交哈希，哈希不一致就停止并报告；文档链接把 github.com/' +
      release.repository + '/blob/ 换成 gitee.com/' + AI_PLUGIN_GITEE_OWNER + '/' + release.repository.split('/')[1] + '/blob/ 阅读。报告里写明实际使用的来源。');
  }
  if (!fromSource) { lines.push('资产：' + release.asset, '资产 SHA256：' + release.sha256); }
  lines.push(
    '协议：v' + release.protocol + '；支持引擎：' + release.engine + '。',
    '先阅读固定提交文档：\n' + documents.join('\n'),
    fromSource ?
      '克隆仓库并检出以上完整提交哈希，核对后再安装依赖。不要使用浮动分支、latest 或执行浮动远程脚本，不臆造 install --dry-run 参数。' :
      '核对 tag 对应提交，下载指定发行资产与 SHA256SUMS，并核对以上 SHA256。仓库 checksum 只证明完整性，不等于独立签名。不要执行浮动远程脚本，不使用 latest 或臆造 install --dry-run 参数。',
    '二、电脑端环境',
    '先检测系统、架构与 compatibility.json。需要 Node >=22.16 和 OpenSSL 3；' + engine.requires +
      '无需 Docker。依赖不兼容时报告具体待办，不降级或替换正在使用的引擎；下载不可达时报告原因，不索取或显示 token。',
    engine.setup,
    '三、安装位置与初始化',
    '程序放在持久的版本目录（macOS：~/Library/Application Support/RemoteDesk/' + backend + '/<版本>-<提交前 7 位>；Windows：%LOCALAPPDATA%\\RemoteDesk\\' + backend +
      '\\…；Linux：~/.local/share/remotedesk/' + backend + '/…），私有 state 放在项目之外的 ~/.remotedesk/' + backend + '。先检查已有安装归属，按手册初始化、升级或恢复，保留证书、设备、项目和历史；不覆盖整个配置。',
    local ?
      '初始化只绑定回环地址：' + command + ' init --state ~/.remotedesk/' + backend + ' --host 127.0.0.1 --hosts localhost,127.0.0.1 --port ' + engine.port + '。' :
      '初始化绑定所选局域网地址，证书名称包含它：' + command + ' init --state ~/.remotedesk/' + backend + ' --host <局域网 IP> --hosts <局域网 IP>,localhost,127.0.0.1 --port ' + engine.port +
        '。电脑的局域网 IP 以后变了，要重新签发服务器证书（renew-server）并让手机重新配对。',
    '升级或换版本：先 ' + command + ' stop --state <state>，再用旧版本 service --action uninstall 卸载旧服务注册，然后用新版本 install、start。切换版本路径前必须先卸载旧服务注册。',
    '四、项目与主机权限',
    '电脑项目目录尚未指定，请在电脑端集中询问；不要自动授权当前目录或整个主目录，也不要把手机路径当作电脑路径。用 project-add 登记我确认的项目。项目登记不保证读取隔离；原生提权可能扩大访问，项目文本与工具输出可能交给所选模型提供方。只补充确认尚未授权的项目、原生权限和模型使用预算。',
    engine.native + '只有我在配对邀请里勾选「全部项目（含电脑 App 里的项目）」时，手机才能看到这些项目；授权在配对时固定，以后要多看项目需重新生成邀请再配对。若当前版本的控制面板没有这个选项，就只授权已登记的项目，并在报告里注明。',
    '五、前台验收',
    '先运行 doctor 和 probe，再以前台方式运行 serve，用独立测试项目与包内参考客户端验证 HTTPS 配对、项目列表、会话/任务/历史、电脑上已有对话的列表、模型列表、原生命令与文件审批接受/拒绝、结构化问答、取消、受管理后台终端和停启历史恢复（引擎不支持的项目注明“不适用”）。真实模型调用仅在已授权预算内进行。unknown/超时保留原操作 ID 和回执，不自动换 ID 重发。',
    '六、后台服务与控制面板',
    '额外软件、模型费用、自启动服务及网络变更只在对应授权明确后执行。前台验收成功后才配置已授权的用户后台服务（' + command + ' service --state <state> --action install，然后 --action start；macOS 为 LaunchAgent，Linux 为 systemd --user，Windows 为计划任务）；未授权的项目继续列为待办。',
    '控制面板只监听本机：' + command + ' panel --state <state> --port ' + engine.panelPort + '，在电脑浏览器里打开。经我同意后可以设为登录时自动打开。',
    '停止服务只用 ' + command + ' stop --state <state>，不要直接结束进程；服务异常退出后先 recover --action inspect，确认列出的原生任务都已停止，再用返回的摘要 recover --confirm-native-cleanup <摘要>。',
    '七、' + (local ? '以后配对手机' : '配对手机'),
    local ?
      '本轮不配对。以后要连手机时，改为绑定局域网地址（重新初始化或签发证书），再按下面的步骤配对。' :
      '在控制面板的「生成邀请」里选择项目（或「全部项目（含电脑 App 里的项目）」）和权限（可操作或只读），点「生成 120 秒邀请」，页面会显示配对二维码。我在手机上打开 RemoteDesk：设置 → 远程 AI → 添加主机，选 ' + release.name +
        '，填电脑的局域网 IP 和端口 ' + engine.port + '，在「配对与保存」点「扫描电脑上的配对二维码」，然后点「配对并连接」。',
    '配对优先使用电脑端设置页生成的二维码；二维码不可用时提供 remotedesk://pair 链接作为备用。二维码、链接和 invite.json 都只通过可信渠道传输，不写入服务日志、终端回显、工单或聊天记录；生成后核对 120 秒有效期并在完成配对后删除传输副本。邀请只写入私有文件，通过可信渠道交给目标客户端；客户端私钥留在客户端。',
    '八、安全边界',
    '保持 TLS/mTLS、证书校验、项目授权及原生审批，不把原生引擎端口暴露到网络，不开启远程扩展或子 Agent 委派。不读取、复制或打印账号密钥和模型凭据。不要把邀请、私钥、token 或聊天内容放入报告。',
    '九、报告',
    '最后按“版本与哈希、安装/state 路径、服务状态、监听端点、控制面板地址、二维码/链接配对结果、CA 指纹、授权项目、真实任务结果、启停/升级/卸载方法、未完成项”报告。依赖检查、服务就绪、客户端配对和真实任务成功分别报告；不能把 doctor 或电脑端成功写成鸿蒙双机验收通过。'
  );
  return lines.join('\n\n');
}
