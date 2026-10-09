/**
 * 截屏给 AI 看 and 诊断证据包 (Pro, plan 2026-10-09 §2): what a session summary says, in plain words, and how the
 * recognised text is handed to the AI. Pure: no ArkUI, files or native calls.
 */

export const PRO_SESSION_EVIDENCE_FEATURE: string = 'pro.session.evidence';
/** Text handed to the AI from one screenshot (the rest is cut, with a note). */
export const SESSION_SCREENSHOT_TEXT_LIMIT: number = 4000;

/** What the session page knows about the connection at the moment of the screenshot. */
export interface SessionEvidenceFacts {
  protocol: string;
  /** The host's display name, as its card shows it (never an address). */
  hostLabel: string;
  capturedAt: number;
  remoteWidth: number;
  remoteHeight: number;
  viewportWidth: number;
  viewportHeight: number;
  /** '' when the protocol has no codec choice (RDP GDI, VNC). */
  codec: string;
  /** 'hardware' / 'software' / ''. */
  decoder: string;
  fps: number;
  /** 'direct' / 'relay' / 'gateway' / 'proxy' / ''. */
  route: string;
  /** The last error the session showed, already in plain words; '' when none. */
  lastError: string;
  appVersion: string;
  deviceType: string;
}

function protocolName(protocol: string): string {
  switch (protocol) {
    case 'rdp': return 'RDP';
    case 'rustdesk': return 'RustDesk';
    case 'vnc': return 'VNC';
    case 'moonlight': return 'Moonlight';
    case 'ssh': return 'SSH';
    default: return protocol.toUpperCase();
  }
}

function routeText(route: string): string {
  switch (route) {
    case 'direct': return '直连';
    case 'relay': return '经中继';
    case 'gateway': return '经 RD 网关';
    case 'proxy': return '经代理';
    default: return '';
  }
}

function pad(value: number): string { return (value < 10 ? '0' : '') + value.toString(); }

/** 2026-10-09 14:20:05 */
export function sessionEvidenceTime(time: number): string {
  const d: Date = new Date(time);
  return d.getFullYear().toString() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

/** The session summary in the evidence pack, one fact per line; unknown facts are left out rather than guessed. */
export function sessionEvidenceSummary(facts: SessionEvidenceFacts): string {
  const lines: string[] = ['RemoteDesktop 会话摘要'];
  lines.push('时间：' + sessionEvidenceTime(facts.capturedAt));
  lines.push('协议：' + protocolName(facts.protocol) + (facts.hostLabel.trim() !== '' ? '（' + facts.hostLabel.trim() + '）' : ''));
  if (facts.remoteWidth > 0 && facts.remoteHeight > 0) {
    lines.push('远端画面：' + facts.remoteWidth.toString() + ' × ' + facts.remoteHeight.toString());
  }
  if (facts.viewportWidth > 0 && facts.viewportHeight > 0) {
    lines.push('本机显示区域：' + facts.viewportWidth.toString() + ' × ' + facts.viewportHeight.toString());
  }
  if (facts.codec !== '') {
    lines.push('编解码：' + facts.codec + (facts.decoder === 'hardware' ? '（硬件解码）' :
      facts.decoder === 'software' ? '（软件解码）' : ''));
  }
  if (facts.fps > 0) { lines.push('帧率：' + Math.round(facts.fps).toString() + ' fps'); }
  if (routeText(facts.route) !== '') { lines.push('连接路径：' + routeText(facts.route)); }
  lines.push('最近错误：' + (facts.lastError.trim() !== '' ? facts.lastError.trim() : '无'));
  if (facts.appVersion !== '') { lines.push('应用版本：' + facts.appVersion); }
  if (facts.deviceType !== '') { lines.push('设备：' + facts.deviceType); }
  return lines.join('\n');
}

/** The question handed to the AI with the text read from a screenshot (cut to SESSION_SCREENSHOT_TEXT_LIMIT). */
export function sessionScreenshotQuestion(text: string, protocol: string): string {
  const clean: string = text.replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  const cut: boolean = clean.length > SESSION_SCREENSHOT_TEXT_LIMIT;
  const body: string = cut ? clean.slice(0, SESSION_SCREENSHOT_TEXT_LIMIT) : clean;
  return '这是我在 ' + protocolName(protocol) + ' 远程会话里截屏、本机识别出的文字' +
    (cut ? '（太长，只截取了前 ' + SESSION_SCREENSHOT_TEXT_LIMIT.toString() + ' 字）' : '') +
    '。请告诉我它是什么意思、可能是什么问题、我该怎么做：\n\n' + body;
}

/** File names inside an evidence pack: ASCII, so every mail app shows them right. */
export function sessionEvidenceFileName(kind: 'screenshot' | 'summary', capturedAt: number): string {
  const d: Date = new Date(capturedAt);
  const stamp: string = d.getFullYear().toString() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' +
    pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
  return kind === 'screenshot' ? 'RemoteDesk-screenshot-' + stamp + '.png' : 'RemoteDesk-session-' + stamp + '.txt';
}
