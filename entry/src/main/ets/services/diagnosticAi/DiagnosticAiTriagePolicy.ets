/**
 * 排障问答: before a capture, a few tap-to-answer questions about what the app cannot read by itself (which host,
 * what the user saw, the network, how to reproduce). The answers choose the 日志子模块 and the duration, and travel
 * with the capture to the AI so its analysis starts from them. Common problems use this local question bank (instant,
 * stable choices); others get questions from the AI.
 */

export class AiTriageOption {
  id: string;
  label: string;
  /** 日志子模块 this answer adds to the capture. */
  facets: string[];
  /** Minutes the capture should run when this answer is chosen (0: keep the script's). */
  minutes: number;

  constructor(id: string, label: string, facets: string[] = [], minutes: number = 0) {
    this.id = id;
    this.label = label;
    this.facets = facets;
    this.minutes = minutes;
  }
}

/**
 * 'protocol' picks the connection type, 'symptom' what is going wrong (for a vague report), 'host' a saved host,
 * 'reproduce' auto/manual, 'choice' anything else.
 */
export type AiTriageKind = 'protocol' | 'symptom' | 'host' | 'choice' | 'reproduce';

export class AiTriageQuestion {
  id: string;
  text: string;
  kind: AiTriageKind;
  options: AiTriageOption[];

  constructor(id: string, text: string, kind: AiTriageKind, options: AiTriageOption[]) {
    this.id = id;
    this.text = text;
    this.kind = kind;
    this.options = options;
  }
}

export class AiTriageHost {
  id: string;
  label: string;

  constructor(id: string, label: string) {
    this.id = id;
    this.label = label;
  }
}

/** What a troubleshooting run asks and captures. */
export class AiTriageScript {
  /** rdp | rustdesk | ssh | vnc | moonlight, or '' when the problem is not about one connection type. */
  protocol: string;
  /** connect | black | lag | disconnect | audio | clipboard | file | sync | crash | other */
  symptom: string;
  questions: AiTriageQuestion[];
  baseFacets: string[];
  minutes: number;
  /** Questions written by the AI (the local bank had none for this problem). */
  fromAi: boolean;

  constructor(protocol: string, symptom: string, questions: AiTriageQuestion[], baseFacets: string[], minutes: number,
    fromAi: boolean = false) {
    this.protocol = protocol;
    this.symptom = symptom;
    this.questions = questions;
    this.baseFacets = baseFacets;
    this.minutes = minutes;
    this.fromAi = fromAi;
  }
}

/**
 * Saved hosts for the host question and the "替我连一次" run. The host page registers itself; host names stay on
 * the device (the AI only learns that a saved host was chosen).
 */
export class DiagnosticAiHostBridge {
  private static lister: ((protocol: string) => AiTriageHost[]) | null = null;
  private static connector: ((hostId: string) => boolean) | null = null;

  static register(list: (protocol: string) => AiTriageHost[], connect: (hostId: string) => boolean): void {
    DiagnosticAiHostBridge.lister = list;
    DiagnosticAiHostBridge.connector = connect;
  }

  static unregister(list: (protocol: string) => AiTriageHost[]): void {
    if (DiagnosticAiHostBridge.lister === list) {
      DiagnosticAiHostBridge.lister = null;
      DiagnosticAiHostBridge.connector = null;
    }
  }

  static hosts(protocol: string): AiTriageHost[] {
    const list = DiagnosticAiHostBridge.lister;
    if (list === null || protocol === '') { return []; }
    try { return list(protocol); } catch (_error) { return []; }
  }

  static connect(hostId: string): boolean {
    const connect = DiagnosticAiHostBridge.connector;
    if (connect === null) { return false; }
    try { return connect(hostId); } catch (_error) { return false; }
  }
}

const PROTOCOL_LABELS: string[][] = [['rdp', 'RDP'], ['rustdesk', 'RustDesk'], ['ssh', 'SSH'], ['vnc', 'VNC'],
  ['moonlight', 'Moonlight']];

export function diagnosticAiProtocolLabel(protocol: string): string {
  const pair: string[] | undefined = PROTOCOL_LABELS.find((p: string[]): boolean => p[0] === protocol);
  return pair !== undefined ? pair[1] : protocol;
}

function protocolOf(text: string): string {
  if (text.indexOf('rustdesk') >= 0) { return 'rustdesk'; }
  if (text.indexOf('moonlight') >= 0 || text.indexOf('串流') >= 0) { return 'moonlight'; }
  if (text.indexOf('rdp') >= 0 || text.indexOf('远程桌面') >= 0 || text.indexOf('windows') >= 0) { return 'rdp'; }
  if (text.indexOf('sftp') >= 0 || text.indexOf('ssh') >= 0 || text.indexOf('终端') >= 0) { return 'ssh'; }
  if (text.indexOf('vnc') >= 0) { return 'vnc'; }
  return '';
}

function has(text: string, words: string[]): boolean {
  return words.some((word: string): boolean => text.indexOf(word) >= 0);
}

/** "ai" as a word ("ai 不回答"), not inside one ("failed"). */
function mentionsAi(text: string): boolean {
  return /(^|[^a-z])ai([^a-z]|$)/.test(text) || has(text, ['助手', '小艺', '大模型', 'apikey', 'api key']);
}

function symptomOf(text: string): string {
  if (mentionsAi(text)) { return 'ai'; }
  if (protocolOf(text) === '' && has(text, ['华为账号', '账号', '登录不了', '登不上', '登录失败'])) { return 'account'; }
  if (has(text, ['闪退', '崩溃'])) { return 'crash'; }
  if (has(text, ['同步', '云端', '换设备', '新设备'])) { return 'sync'; }
  if (has(text, ['黑屏', '花屏', '白屏', '没画面', '没有画面'])) { return 'black'; }
  if (has(text, ['卡顿', '卡住', '很卡', '有点卡', '卡死', '延迟', '掉帧', '不流畅', '慢'])) { return 'lag'; }
  if (has(text, ['断开', '掉线', '断线', '自动断'])) { return 'disconnect'; }
  if (has(text, ['没声音', '没有声音', '听不到', '无声', '声音'])) { return 'audio'; }
  if (has(text, ['剪贴板', '复制', '粘贴'])) { return 'clipboard'; }
  if (has(text, ['sftp', '上传', '下载', '传输', '文件'])) { return 'file'; }
  if (has(text, ['连不上', '连接不上', '连接不了', '连接失败', '失败', '超时', 'tcp', '拒绝', '无法连接', '打不开', '认证',
    '密码错误', '证书', '连不了'])) { return 'connect'; }
  return '';
}

/** Words of a problem report that do not say what goes wrong ("出问题", "用不了"). */
const VAGUE_PROBLEM: string[] = ['出问题', '有问题', '出了问题', '用不了', '不能用', '没法用', '不好用', '不行', '不好使', '不工作',
  '打不开', '进不去', '登不上', '登录不了', '怎么回事', '咋回事', '坏了', '异常', '报错', '错误'];

/** Whether a question reports a problem at all (precise or vague). */
export function diagnosticAiLooksLikeProblem(question: string): boolean {
  const text: string = question.toLowerCase().replace(/\s+/g, '');
  return symptomOf(text) !== '' || has(text, VAGUE_PROBLEM);
}

function symptomQuestion(): AiTriageQuestion {
  return new AiTriageQuestion('symptom', '具体是什么情况？', 'symptom', [
    new AiTriageOption('symptom:connect', '连不上'), new AiTriageOption('symptom:black', '连上后黑屏'),
    new AiTriageOption('symptom:lag', '卡顿或延迟'), new AiTriageOption('symptom:disconnect', '连上后断开'),
    new AiTriageOption('symptom:clipboard', '剪贴板不通'), new AiTriageOption('symptom:file', '文件传输'),
    new AiTriageOption('symptom:other', '其它')]);
}

/** 日志子模块 for a protocol and symptom. */
function baseFacets(protocol: string, symptom: string): string[] {
  if (symptom === 'sync') { return ['cloud.sync', 'store.database', 'account.login']; }
  if (symptom === 'crash') { return ['app.faults', 'app.lifecycle', 'app.window']; }
  if (symptom === 'ai') { return ['ai.request', 'ai.actions']; }
  if (symptom === 'account') { return ['account.login', 'cloud.sync']; }
  switch (protocol) {
    case 'rdp':
      if (symptom === 'connect') { return ['rdp.connect', 'rdp.security', 'routing.gateway']; }
      if (symptom === 'lag') { return ['rdp.display']; }
      if (symptom === 'black') { return ['rdp.connect', 'rdp.display']; }
      if (symptom === 'disconnect') { return ['rdp.connect', 'app.lifecycle']; }
      if (symptom === 'audio' || symptom === 'clipboard' || symptom === 'file') { return ['rdp.connect', 'rdp.devices']; }
      return ['rdp.connect', 'rdp.display'];
    case 'rustdesk':
      if (symptom === 'connect') { return ['rustdesk.connect', 'routing.relay']; }
      if (symptom === 'lag') { return ['rustdesk.display', 'routing.relay']; }
      if (symptom === 'black') { return ['rustdesk.connect', 'rustdesk.display']; }
      if (symptom === 'disconnect') { return ['rustdesk.connect', 'app.lifecycle']; }
      if (symptom === 'clipboard') { return ['rustdesk.connect', 'rustdesk.clipboard']; }
      return ['rustdesk.connect', 'rustdesk.display'];
    case 'ssh':
      if (symptom === 'file') { return ['sftp.transfer', 'ssh.session']; }
      if (symptom === 'connect') { return ['ssh.session', 'routing.ssh', 'keys.auth']; }
      if (symptom === 'disconnect') { return ['ssh.session', 'app.lifecycle']; }
      return ['ssh.session'];
    case 'vnc':
      if (symptom === 'connect') { return ['vnc.connect', 'routing.gateway']; }
      if (symptom === 'disconnect') { return ['vnc.connect', 'app.lifecycle']; }
      return ['vnc.connect', 'vnc.display'];
    case 'moonlight':
      if (symptom === 'connect') { return ['moonlight.pairing', 'moonlight.stream']; }
      return ['moonlight.stream'];
    default:
      return ['app.lifecycle'];
  }
}

function routingFacet(protocol: string): string[] {
  if (protocol === 'rustdesk') { return ['routing.relay']; }
  if (protocol === 'ssh') { return ['routing.ssh']; }
  if (protocol === 'rdp' || protocol === 'vnc') { return ['routing.gateway']; }
  return [];
}

function detailQuestion(protocol: string, symptom: string): AiTriageQuestion | null {
  const o = (id: string, label: string, facets: string[] = [], minutes: number = 0): AiTriageOption =>
    new AiTriageOption(id, label, facets, minutes);
  switch (symptom) {
    case 'connect':
      return new AiTriageQuestion('detail', '连接失败时看到的是？', 'choice', [
        o('timeout', '转了很久后超时', routingFacet(protocol)), o('refused', '立刻提示连接失败'),
        o('cert', '证书或安全提示', protocol === 'rdp' ? ['rdp.security'] : []),
        o('auth', '提示用户名或密码不对', protocol === 'ssh' ? ['keys.auth'] : protocol === 'rdp' ? ['rdp.security'] : []),
        o('drop', '连上后马上断开', ['app.lifecycle'])]);
    case 'black':
      return new AiTriageQuestion('detail', '画面是什么情况？', 'choice', [
        o('always', '连上后一直黑屏'), o('cursor', '黑屏但鼠标能动'), o('flash', '偶尔黑一下', [], 10)]);
    case 'lag':
      return new AiTriageQuestion('detail', '什么时候卡？', 'choice', [
        o('always', '一直都卡'), o('motion', '画面一动就卡'), o('input', '打字和鼠标也延迟'), o('sometimes', '偶尔卡一下', [], 10)]);
    case 'disconnect':
      return new AiTriageQuestion('detail', '什么时候断开？', 'choice', [
        o('minutes', '用几分钟就断', [], 10), o('background', '切到后台后断开', ['app.lifecycle']),
        o('network', '网络切换后断开', ['app.lifecycle']), o('random', '不定时断开', [], 10)]);
    case 'audio':
      return new AiTriageQuestion('detail', '声音的情况？', 'choice', [o('none', '完全没有声音'), o('choppy', '断断续续')]);
    case 'clipboard':
      return new AiTriageQuestion('detail', '哪个方向不行？', 'choice', [
        o('toRemote', '本机复制到远端'), o('toLocal', '远端复制到本机'), o('both', '两边都不行')]);
    case 'file':
      return new AiTriageQuestion('detail', '文件哪里出问题？', 'choice', [
        o('upload', '上传失败'), o('download', '下载失败'), o('slow', '传得很慢'), o('list', '看不到目录')]);
    case 'sync':
      return new AiTriageQuestion('detail', '同步是什么情况？', 'choice', [
        o('missing', '新设备看不到主机'), o('stale', '改动没同步过去'), o('error', '提示同步失败')]);
    case 'ai':
      return new AiTriageQuestion('detail', 'AI 出了什么问题？', 'choice', [
        o('slow', '一直在思考，最后超时'), o('network', '提示连接不上'), o('auth', '提示 Key 或权限问题'),
        o('wrong', '回答不对或答非所问'), o('action', '按钮点了没反应', ['ai.actions'])]);
    case 'account':
      return new AiTriageQuestion('detail', '登录时看到的是？', 'choice', [
        o('spin', '一直转圈'), o('error', '提示登录失败（带错误码）'), o('enterprise', '提示企业账号受限'),
        o('data', '登录后主机或数据不对', ['store.database'])]);
    case 'crash':
      return new AiTriageQuestion('detail', '什么时候闪退？', 'choice', [
        o('launch', '一打开就闪退'), o('connect', '连接主机时闪退'), o('action', '做某个操作后闪退')]);
    default:
      return null;
  }
}

function networkQuestion(protocol: string): AiTriageQuestion {
  return new AiTriageQuestion('network', '你和那台设备的网络？', 'choice', [
    new AiTriageOption('lan', '同一 Wi-Fi 或局域网'), new AiTriageOption('wan', '外网直连'),
    new AiTriageOption('vpn', '经过 VPN、网关或中继', routingFacet(protocol)), new AiTriageOption('unknown', '不确定')]);
}

/** The host question for a protocol: its saved hosts (at most five), or none when it has none. */
export function diagnosticAiHostQuestion(protocol: string): AiTriageQuestion | null {
  const hosts: AiTriageHost[] = DiagnosticAiHostBridge.hosts(protocol).slice(0, 5);
  if (hosts.length === 0) { return null; }
  const options: AiTriageOption[] = hosts.map((host: AiTriageHost): AiTriageOption =>
    new AiTriageOption('host:' + host.id, host.label));
  options.push(new AiTriageOption('host:', '不在列表里'));
  return new AiTriageQuestion('host', '是哪台主机？', 'host', options);
}

export function diagnosticAiReproduceQuestion(): AiTriageQuestion {
  return new AiTriageQuestion('reproduce', '抓取时怎么复现？', 'reproduce', [
    new AiTriageOption('auto', '替我连一次'), new AiTriageOption('manual', '我自己操作')]);
}

function protocolQuestion(): AiTriageQuestion {
  return new AiTriageQuestion('protocol', '是哪种连接？', 'protocol',
    PROTOCOL_LABELS.map((pair: string[]): AiTriageOption => new AiTriageOption('protocol:' + pair[0], pair[1])));
}

/** Symptoms the app can reproduce by connecting to the chosen host. */
export function diagnosticAiTriageReproducible(symptom: string): boolean {
  return ['connect', 'black', 'lag', 'disconnect', 'audio'].indexOf(symptom) >= 0;
}

/**
 * The local questions for a described problem, or null when the bank has none (the AI then writes them). The host
 * and reproduce questions are filled in as the run goes (they depend on the protocol answer).
 */
export function diagnosticAiTriageScript(question: string): AiTriageScript | null {
  const text: string = question.toLowerCase().replace(/\s+/g, '');
  let symptom: string = symptomOf(text);
  const protocol: string = protocolOf(text);
  if (symptom === '') {
    if (!has(text, VAGUE_PROBLEM)) { return null; }
    // "SSH 连接出问题": about connecting. Otherwise ask what is going wrong first, then the questions for that.
    if (text.indexOf('连接') >= 0 || text.indexOf('连不') >= 0 || text.indexOf('登') >= 0) {
      symptom = 'connect';
    } else {
      const vague: AiTriageQuestion[] = protocol === '' ? [protocolQuestion(), symptomQuestion()] : [symptomQuestion()];
      return new AiTriageScript(protocol, 'unknown', vague, baseFacets(protocol, 'unknown'), 3);
    }
  }
  return diagnosticAiTriageFor(protocol, symptom, protocol === '' && ['sync', 'crash', 'ai', 'account'].indexOf(symptom) < 0);
}

/** The questions for a known protocol (or one still to be asked) and symptom. */
export function diagnosticAiTriageFor(protocol: string, symptom: string, askProtocol: boolean): AiTriageScript {
  const questions: AiTriageQuestion[] = [];
  const needsProtocol: boolean = askProtocol && symptom !== 'ai' && symptom !== 'account';
  if (needsProtocol) { questions.push(protocolQuestion()); }
  if ((protocol !== '' || needsProtocol) && symptom !== 'ai' && symptom !== 'account') {
    questions.push(new AiTriageQuestion('host', '是哪台主机？', 'host', []));
  }
  const detail: AiTriageQuestion | null = detailQuestion(protocol, symptom);
  if (detail !== null) { questions.push(detail); }
  if (symptom === 'connect' || symptom === 'lag' || symptom === 'disconnect') { questions.push(networkQuestion(protocol)); }
  if (diagnosticAiTriageReproducible(symptom)) { questions.push(diagnosticAiReproduceQuestion()); }
  return new AiTriageScript(protocol, symptom, questions, baseFacets(protocol, symptom), symptom === 'disconnect' ? 5 : 3);
}

/** After the protocol answer: the protocol, its facets, and the questions that depend on it. */
export function diagnosticAiTriageWithProtocol(script: AiTriageScript, protocol: string): AiTriageScript {
  const questions: AiTriageQuestion[] = script.questions.map((q: AiTriageQuestion): AiTriageQuestion => {
    if (q.id === 'detail') { return detailQuestion(protocol, script.symptom) ?? q; }
    if (q.id === 'network') { return networkQuestion(protocol); }
    return q;
  });
  return new AiTriageScript(protocol, script.symptom, questions, baseFacets(protocol, script.symptom), script.minutes,
    script.fromAi);
}

/** The capture a finished run asks for: its facets and minutes. */
export function diagnosticAiTriageFacets(script: AiTriageScript, answers: AiTriageOption[]): string[] {
  const facets: string[] = script.baseFacets.slice();
  answers.forEach((answer: AiTriageOption): void => {
    answer.facets.forEach((facet: string): void => { if (facets.indexOf(facet) < 0) { facets.push(facet); } });
  });
  return facets;
}

export function diagnosticAiTriageMinutes(script: AiTriageScript, answers: AiTriageOption[]): number {
  return answers.reduce((minutes: number, answer: AiTriageOption): number => Math.max(minutes, answer.minutes),
    script.minutes);
}
