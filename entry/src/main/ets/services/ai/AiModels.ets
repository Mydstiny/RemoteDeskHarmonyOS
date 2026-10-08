import { parseEndpointHost, parseEndpointServerIdentity } from '../EndpointAddressPolicy';
/** Local AI configuration. No credential is projected into RemoteHost/CloudStore. */
/** The backend ID is the host plugin's engine name: the handshake must report the same engine. */
export type AiBackend = 'codex' | 'dsh' | 'pi';
export const AI_BACKENDS: AiBackend[] = ['codex', 'dsh', 'pi'];
export function aiBackendValid(value: string): boolean { return value === 'codex' || value === 'dsh' || value === 'pi'; }
export function aiBackendName(backend: AiBackend): string {
  return backend === 'codex' ? 'Codex' : backend === 'dsh' ? 'DSH' : 'Pi';
}
export function aiBackendSubtitle(backend: AiBackend): string {
  return backend === 'codex' ? 'OpenAI Codex · 9443' : backend === 'dsh' ? 'DeepSeek Harness · 9444' :
    'Pi 编程代理 · 9445';
}
/** Engines whose bridge streams agent events (replies, tool calls, tool results), read by aiAgentItems. */
export function aiAgentEvents(backend: string): boolean { return backend === 'pi'; }
/**
 * The Claude Agent plugin (engine `claudecode`, port 9445) became the Pi plugin. A host saved for it reads as a Pi
 * host; its pairing belonged to the old service, so it must be paired again. Returns whether the host was one.
 */
export function aiMigrateLegacyHost(host: AiHost): boolean {
  if ((host.backend as string) !== 'claudecode') { return false; }
  host.backend = 'pi';
  return true;
}
export function aiMigrateLegacySettings(settings: AiSettings): AiSettings {
  if ((settings.defaultBackend as string) === 'claudecode') { settings.defaultBackend = 'pi'; }
  return settings;
}
export function aiBackendDefaultPort(backend: AiBackend): number {
  return backend === 'codex' ? 9443 : backend === 'dsh' ? 9444 : 9445;
}
export type AiTransportKind = 'lan' | 'rustdesk';
export interface AiHost {
  id: string;
  owner: string;
  revision: number;
  label: string;
  backend: AiBackend;
  address: string;
  port: number;
  serverName: string;
  groupId: string;
  sortOrder: number;
  lastConnected: number;
  createdAt: number;
  transport: AiTransportKind;
  relayHostId: string;
  projectId: string;
}
export interface AiIdentity {
  ca: string;
  certificate: string;
  privateKey: string;
  deviceId: string;
  instance: string;
}
/**
 * A pairing invite. The full form carries the private CA itself; the compact form (what the QR shows, so it stays
 * scannable on small or low-resolution screens) carries only its SHA-256 and the CA is taken from the server's chain.
 */
export interface AiInvite { code: string; expires: number; ca: string; caSha256: string; serverInstance: string; }
/** Look of the remote AI session page, after the Claude app (conversation timeline) or the Codex app. */
export type AiUiStyle = 'claude' | 'codex';
export interface AiSettings {
  showExecution: boolean;
  textSize: number;
  reconnectOnForeground: boolean;
  defaultBackend: AiBackend;
  /** Absent in settings saved before the style choice existed; read as 'claude'. */
  uiStyle?: AiUiStyle;
}
export function aiUiStyle(settings: AiSettings): AiUiStyle { return settings.uiStyle === 'codex' ? 'codex' : 'claude'; }
/**
 * `stored` with only what changed from `before` to `after` written over it: two writers (设置 → 远程 AI and the AI
 * 助理) each change their own fields and never put back a value the other one just saved.
 */
export function aiSettingsMerged(stored: AiSettings, before: AiSettings, after: AiSettings): AiSettings {
  const next: AiSettings = JSON.parse(JSON.stringify(stored)) as AiSettings;
  if (after.showExecution !== before.showExecution) { next.showExecution = after.showExecution; }
  if (after.textSize !== before.textSize) { next.textSize = after.textSize; }
  if (after.reconnectOnForeground !== before.reconnectOnForeground) { next.reconnectOnForeground = after.reconnectOnForeground; }
  if (after.defaultBackend !== before.defaultBackend) { next.defaultBackend = after.defaultBackend; }
  if (aiUiStyle(after) !== aiUiStyle(before)) { next.uiStyle = aiUiStyle(after); }
  return next;
}
/** 远程 AI 设置 the AI 助理 may change (ids in its settings catalog); the rest stay in 设置 → 远程 AI. */
export const AI_REMOTE_SETTING_IDS: string[] = ['remoteAi.uiStyle', 'remoteAi.showExecution', 'remoteAi.reconnectOnForeground',
  'remoteAi.defaultBackend', 'remoteAi.textSize'];
/** One of those settings as a catalog value (claude / codex, true / false, codex / dsh / pi, 12–22), or null for another id. */
export function aiRemoteSettingValue(settings: AiSettings, id: string): string | null {
  if (id === 'remoteAi.uiStyle') { return aiUiStyle(settings); }
  if (id === 'remoteAi.showExecution') { return settings.showExecution ? 'true' : 'false'; }
  if (id === 'remoteAi.reconnectOnForeground') { return settings.reconnectOnForeground ? 'true' : 'false'; }
  if (id === 'remoteAi.defaultBackend') { return settings.defaultBackend; }
  if (id === 'remoteAi.textSize') { return settings.textSize.toString(); }
  return null;
}
/** A copy of `settings` with one of those set to a catalog value, or null when the id or value is not one of them. */
export function aiRemoteSettingChanged(settings: AiSettings, id: string, value: string): AiSettings | null {
  const next: AiSettings = JSON.parse(JSON.stringify(settings)) as AiSettings;
  const flag: boolean | null = value === 'true' ? true : value === 'false' ? false : null;
  if (id === 'remoteAi.uiStyle' && (value === 'claude' || value === 'codex')) { next.uiStyle = value === 'codex' ? 'codex' : 'claude'; }
  else if (id === 'remoteAi.showExecution' && flag !== null) { next.showExecution = flag; }
  else if (id === 'remoteAi.reconnectOnForeground' && flag !== null) { next.reconnectOnForeground = flag; }
  else if (id === 'remoteAi.defaultBackend' && aiBackendValid(value)) { next.defaultBackend = value as AiBackend; }
  else if (id === 'remoteAi.textSize' && /^\d{2}$/.test(value)) { next.textSize = Number(value); }
  else { return null; }
  return aiSettingsValid(next) ? next : null;
}
export interface AiPendingOperation {
  id: string;
  hostId: string;
  sessionId: string;
  createdAt: number;
  body: string;
  receipt: string;
}
export interface AiProject { id: string; title: string; }
/** origin: 'computer' for a conversation started on the computer itself (the Codex or DSH app), else 'remote'. */
export interface AiSession { id: string; project: string; title: string; archived: boolean; updatedAt: number; origin: string; }
export interface AiCapabilities {
  methods: string[];
  permissionModes: string[];
  collaborationModes: string[];
}
export interface AiEpoch { id: string; device: string; expires: number; }
export interface AiHandshake {
  version: number;
  engine: string;
  instance: string;
  deviceId: string;
  runtime: string;
  role: string;
  epoch: AiEpoch;
  capabilities: Record<string, Object>;
}
export interface AiOperationReceipt {
  operationId: string;
  status: string;
  epoch: string;
  result?: Object;
  error?: string;
}
export interface AiEnvelope { result?: Object; operation?: AiOperationReceipt; error?: string; }
export interface AiEvent {
  cursor: number;
  session: string;
  project: string;
  runtime: string;
  event: Record<string, Object>;
}
export interface AiApproval { id: string; request: Record<string, Object>; expires: number; }
export interface AiTranscriptItem {
  id: string;
  /** 'user' | 'assistant' | 'execution' */
  role: string;
  title: string;
  text: string;
  state: string;
  turnId: string;
  /** 'user' | 'assistant' | 'thinking' | 'tool' | 'notice'; absent on items from older mappers. */
  kind?: string;
  /** tool: its input; notice: extra detail */
  detail?: string;
  /** tool: its result */
  output?: string;
  /** Agent events (Pi): arrival position of the event the item came from (places locally echoed prompts). */
  order?: number;
}
export function defaultAiSettings(): AiSettings {
  return { showExecution: true, textSize: 15, reconnectOnForeground: true, defaultBackend: 'codex', uiStyle: 'claude' };
}
export function emptyAiHost(owner: string, id: string, backend: AiBackend = 'codex'): AiHost {
  return { id, owner, revision: 0, label: '', backend, address: '', port: aiBackendDefaultPort(backend),
    serverName: '', groupId: '', sortOrder: 0, lastConnected: 0, createdAt: Date.now(),
    transport: 'lan', relayHostId: '', projectId: '' };
}
export function aiIdValid(id: string): boolean { return /^[A-Za-z0-9_-]{1,100}$/.test(id); }
export function aiOwnerValid(owner: string): boolean { return /^owner-[a-f0-9]{64}$/.test(owner); }
export function aiHostError(host: AiHost): string {
  if (!aiIdValid(host.id) || !aiOwnerValid(host.owner)) { return '请先登录当前华为账号'; }
  if (host.label.trim().length === 0 || host.label.length > 100) { return '请输入 1–100 字的主机名称'; }
  if (!aiBackendValid(host.backend)) { return '请选择 Codex、DSH 或 Pi'; }
  if (host.transport !== 'lan' && host.transport !== 'rustdesk') { return '请选择局域网或 RustDesk 中继'; }
  if (host.transport === 'lan' && host.relayHostId !== '') { return '局域网连接不应绑定 RustDesk 中继'; }
  if (host.transport === 'rustdesk' && host.relayHostId.trim() === '') { return '请选择已配置的 RustDesk 中继'; }
  if (!parseEndpointHost(host.address, 'runtime').ok) { return '请输入有效的电脑 IP 或域名，不含协议和端口'; }
  if (!Number.isInteger(host.port) || host.port < 1 || host.port > 65535) { return '端口应为 1–65535'; }
  if (host.serverName !== '' && (!parseEndpointServerIdentity(host.serverName).ok ||
    host.serverName.startsWith('.') || host.serverName.endsWith('.') || host.serverName.includes('*'))) {
    return '证书服务器名称无效';
  }
  if (host.groupId.length > 100 || host.projectId.length > 100 ||
    !Number.isSafeInteger(host.revision) || host.revision < 0 ||
    !Number.isSafeInteger(host.sortOrder) || !Number.isSafeInteger(host.createdAt) ||
    !Number.isSafeInteger(host.lastConnected)) { return '主机信息无效'; }
  return '';
}
export function aiSameEndpoint(a: AiHost, b: AiHost): boolean {
  return a.owner === b.owner && a.backend === b.backend && a.address === b.address &&
    a.port === b.port && a.serverName === b.serverName && a.transport === b.transport &&
    a.relayHostId === b.relayHostId;
}
export function aiSettingsValid(settings: AiSettings): boolean {
  return typeof settings.showExecution === 'boolean' && typeof settings.reconnectOnForeground === 'boolean' &&
    Number.isInteger(settings.textSize) && settings.textSize >= 12 && settings.textSize <= 22 &&
    aiBackendValid(settings.defaultBackend) &&
    (settings.uiStyle === undefined || settings.uiStyle === 'claude' || settings.uiStyle === 'codex');
}
