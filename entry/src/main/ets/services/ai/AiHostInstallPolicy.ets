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

// Public, version-pinned metadata from the reviewed native-host handoff.
// Callers own their copy; no account, host configuration or invitation is read.
export function aiInstallRelease(backend: AiBackend): AiInstallRelease {
  if (backend === 'codex') {
    return { name: 'Codex', repository: 'Mydstiny/remotedesk-codex-plugin', version: '0.3.0', protocol: 1,
      engine: 'Codex CLI 0.153.4', commit: '87203937ff20c8d527ef2fe09a0b7e4a2ce0af4d',
      asset: 'remotedesk-codex-plugin-0.3.0.tgz',
      sha256: 'd2559c8d9a560740355fdbb6ad1a55ea332891d32126f6914449d8636fc1a67f' };
  }
  if (backend === 'dsh') {
    return { name: 'DSH', repository: 'Mydstiny/remotedesk-dsh-plugin', version: '0.3.0', protocol: 1,
      engine: 'DSH 0.1.2-rc.1', commit: 'c75f6b8e1e904bb4406e46bd476b8849108622c0',
      asset: 'remotedesk-dsh-plugin-0.3.0.tgz',
      sha256: 'c17d0e05fc656ceee96fffdad175dfd702f8ebe45ccdcae457d0aff12ada873e' };
  }
  if (backend === 'pi') {
    // No release package yet: installed from the pinned source commit, so there is no asset or checksum to show.
    return { name: 'Pi', repository: 'Mydstiny/remotedesk-pi-plugin', version: '0.3.0', protocol: 1,
      engine: 'Pi 1.0 或更新（@earendil-works/pi-coding-agent）', commit: 'a826216a559bd44508fa77f1ec08b36fc711a37e',
      asset: '', sha256: '' };
  }
  throw new Error('Unsupported AI installation backend');
}

export function aiInstallManualUrl(backend: AiBackend): string {
  const release = aiInstallRelease(backend);
  return 'https://github.com/' + release.repository + '/blob/' + release.commit +
    (release.asset === '' ? '/README.md' : '/docs/operations.md');
}

export function aiInstallPrompt(backend: AiBackend, mode: AiInstallMode): string {
  if (mode !== 'local' && mode !== 'lan') { throw new Error('Unsupported AI installation mode'); }
  const release = aiInstallRelease(backend);
  const source = 'https://github.com/' + release.repository;
  const pinned = source + '/blob/' + release.commit + '/';
  const connection = mode === 'local' ?
    '连接方式：仅本机准备。服务仅监听电脑回环地址，不监听局域网或公网，不修改防火墙、路由器或端口转发；本轮不进行手机连接。' :
    '连接方式：局域网连接。先确认电脑上的监听网卡与端口，只绑定所选局域网地址；不开放公网、不配置 RustDesk 中继。防火墙或其他网络配置变更须另行确认。';
  const engine = backend === 'dsh' ?
    'DSH 默认创建独立 RemoteDesk profile。不要停止承载当前对话的 DSH，不接管或重复启动原有 web profile。新 profile 无法使用现有模型登录时，通过原生流程让我配置，不复制账号密钥。' :
    backend === 'pi' ?
    'Pi 插件使用我电脑上已安装的 Pi（需 1.0 或更新）和它已登录的模型提供方（在 Pi 里 /login 或在 pi-gui 里登录）；不读取、不复制 Pi 的凭据，也不加载 Pi 扩展。权限默认只读，可在手机上切换为「修改前询问」或「完全访问」。' :
    'Codex 保留现有会话、账号和配置，通过受支持的现有登录使用 provider/model。使用原生工具、默认只读沙箱和按需审批，不覆盖整个 Codex 配置。';
  const fromSource = release.asset === '';
  const documents = fromSource ?
    [pinned + 'README.md', pinned + 'docs/compatibility.md', pinned + 'SECURITY.md', pinned + 'compatibility.json'] :
    [pinned + 'docs/agent-deploy.md', aiInstallManualUrl(backend), pinned + 'SECURITY.md', pinned + 'compatibility.json'];
  const lines: string[] = [
    '请在这台电脑上为我准备 RemoteDesk ' + release.name + ' 插件 ' + release.version + '，按以下范围完成电脑端验收。',
    connection,
    '一、固定版本与来源',
    '仓库：' + source,
    fromSource ? '发行方式：尚无发行包，从固定提交的源码安装' : '发行页：' + source + '/releases/tag/v' + release.version,
    '固定提交：' + release.commit
  ];
  if (!fromSource) { lines.push('资产：' + release.asset, '资产 SHA256：' + release.sha256); }
  lines.push(
    '协议：v' + release.protocol + '；支持引擎：' + release.engine + '。',
    '先阅读固定提交文档：\n' + documents.join('\n'),
    fromSource ?
      '克隆仓库并检出以上完整提交哈希，核对后再安装依赖。不要使用浮动分支、latest 或执行浮动远程脚本，不臆造 install --dry-run 参数。' :
      '核对 tag 对应提交，下载指定发行资产与 SHA256SUMS，并核对以上 SHA256。仓库 checksum 只证明完整性，不等于独立签名。不要执行浮动远程脚本，不使用 latest 或臆造 install --dry-run 参数。',
    '二、项目与主机权限',
    '电脑项目目录尚未指定，请在电脑端集中询问；不要自动授权当前目录或整个主目录，也不要把手机路径当作电脑路径。项目登记不保证读取隔离；原生提权可能扩大访问，项目文本与工具输出可能交给所选模型提供方。只补充确认尚未授权的项目、原生权限和模型使用预算。',
    '三、安装与保留',
    '先检测系统、架构与 compatibility.json。需要 Node >=22.16、OpenSSL 3 和对应引擎；DSH 另需 pnpm。无需 Docker。依赖不兼容时报告具体待办，不降级或替换正在使用的引擎；下载不可达时报告原因，不索取或显示 token。',
    engine,
    '使用持久版本目录和项目之外的私有 state。先检查已有安装归属，按手册初始化、升级或恢复，保留证书、设备、项目和历史；切换版本路径前卸载旧服务注册，不覆盖整个配置。',
    '保持 TLS/mTLS、证书校验、项目授权及原生审批，不把原生引擎端口暴露到网络，不开启远程扩展或子 Agent 委派。不读取、复制或打印账号密钥和模型凭据。',
    '四、验收与后续配对',
    '先以前台方式运行，用独立测试项目与包内参考客户端验证 HTTPS 配对、项目列表、会话/任务/历史、原生命令与文件审批接受/拒绝、结构化问答、取消、受管理后台终端和停启历史恢复。真实模型调用仅在已授权预算内进行。unknown/超时保留原操作 ID 和回执，不自动换 ID 重发。',
    '配对优先使用电脑端设置页生成的二维码；二维码不可用时提供 remotedesk://pair 链接作为备用。二维码、链接和 invite.json 都只通过可信渠道传输，不写入服务日志、终端回显、工单或聊天记录；生成后核对 120 秒有效期并在完成配对后删除传输副本。',
    '额外软件、模型费用、自启动服务及网络变更只在对应授权明确后执行。前台验收成功后才配置已授权的用户后台服务；未授权的项目继续列为待办。',
    '邀请只写入私有文件，通过可信渠道交给目标客户端；客户端私钥留在客户端。不要把邀请、私钥、token 或聊天内容放入报告。',
    '最后按“版本与哈希、安装/state 路径、服务状态、监听端点、二维码/链接配对结果、CA 指纹、授权项目、真实任务结果、启停/升级/卸载方法、未完成项”报告。依赖检查、服务就绪、客户端配对和真实任务成功分别报告；不能把 doctor 或电脑端成功写成鸿蒙双机验收通过。'
  );
  return lines.join('\n\n');
}
