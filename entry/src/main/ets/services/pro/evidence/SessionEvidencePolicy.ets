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

/**
 * The question handed to the AI with the text read from a screenshot — or, with `source` 'terminal', the text on an
 * SSH terminal screen (cut to SESSION_SCREENSHOT_TEXT_LIMIT).
 */
export function sessionScreenshotQuestion(text: string, protocol: string,
  source: 'screenshot' | 'terminal' = 'screenshot'): string {
  const clean: string = text.replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  const cut: boolean = clean.length > SESSION_SCREENSHOT_TEXT_LIMIT;
  const body: string = cut ? clean.slice(0, SESSION_SCREENSHOT_TEXT_LIMIT) : clean;
  const lead: string = source === 'terminal' ? '这是我的 ' + protocolName(protocol) + ' 终端当前屏幕上的文字' :
    '这是我在 ' + protocolName(protocol) + ' 远程会话里截屏、本机识别出的文字';
  return lead +
    (cut ? '（太长，只截取了前 ' + SESSION_SCREENSHOT_TEXT_LIMIT.toString() + ' 字）' : '') +
    '。请告诉我它是什么意思、可能是什么问题、我该怎么做：\n\n' + body;
}

/** File names inside an evidence pack: ASCII, so every mail app shows them right. */
export function sessionEvidenceFileName(kind: 'screenshot' | 'summary' | 'timeline', capturedAt: number): string {
  const d: Date = new Date(capturedAt);
  const stamp: string = d.getFullYear().toString() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' +
    pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
  if (kind === 'screenshot') { return 'RemoteDesk-screenshot-' + stamp + '.png'; }
  return (kind === 'summary' ? 'RemoteDesk-session-' : 'RemoteDesk-timeline-') + stamp + '.txt';
}

/** The minutes of 诊断时间线 a pack can carry. */
export const SESSION_TIMELINE_MINUTES: number[] = [1, 5, 10];
/** At most this many events go into one pack (the newest are kept). */
export const SESSION_TIMELINE_EVENT_LIMIT: number = 2000;

/** One diagnostic event as the timeline shows it. */
export interface SessionTimelineEvent {
  wallTimeMs: number;
  moduleId: string;
  eventCode: string;
  outcome: string;
  code: number;
  durationMs: number;
}

function clock(time: number): string {
  const d: Date = new Date(time);
  const ms: number = d.getMilliseconds();
  return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()) + '.' +
    (ms < 100 ? (ms < 10 ? '00' : '0') : '') + ms.toString();
}

/** The last `minutes` of the running diagnostic capture, one event per line, oldest first. */
export function sessionTimelineText(events: SessionTimelineEvent[], minutes: number, now: number): string {
  const since: number = now - minutes * 60 * 1000;
  const kept: SessionTimelineEvent[] = events.filter((event: SessionTimelineEvent): boolean =>
    event.wallTimeMs >= since && event.wallTimeMs <= now)
    .sort((a: SessionTimelineEvent, b: SessionTimelineEvent): number => a.wallTimeMs - b.wallTimeMs);
  const cut: number = Math.max(0, kept.length - SESSION_TIMELINE_EVENT_LIMIT);
  const lines: string[] = ['RemoteDesktop 诊断时间线（最近 ' + minutes.toString() + ' 分钟，' +
    (kept.length - cut).toString() + ' 条' + (cut > 0 ? '，更早的 ' + cut.toString() + ' 条已省略' : '') + '）'];
  for (let i = cut; i < kept.length; i++) {
    const event: SessionTimelineEvent = kept[i];
    lines.push(clock(event.wallTimeMs) + '  ' + event.moduleId + '  ' + event.eventCode + '  ' + event.outcome +
      (event.code !== 0 ? '  code=' + event.code.toString() : '') +
      (event.durationMs > 0 ? '  ' + event.durationMs.toString() + 'ms' : ''));
  }
  return lines.join('\n');
}
