import { ProRdpConnectionIdentity, validProRdpConnectionIdentity,
  copyProRdpConnectionIdentity, sameProRdpConnectionIdentity } from './ProRdpConnectionIdentity';
// A deliberately separate wire model. Never serialize a RemoteHost and strip secrets afterwards.
export type ProConnectionProtocol = 'ssh' | 'rdp';
export type ProConnectionPurpose = 'share' | 'continuation';
export interface ProConnectionView {
  sshPane: string;
  sshDirectory: string;
  monitor: number;
  scale: number;
  panX: number;
  panY: number;
  inputMode: string;
  strictBounds?: boolean;
}
export interface ProConnectionDescription {
  protocol: ProConnectionProtocol;
  label: string;
  host: string;
  port: number;
  username: string;
  hostReference: string;
  view: ProConnectionView;
  rdpIdentity?: ProRdpConnectionIdentity;
}
export interface ProConnectionEnvelope {
  version: number;
  purpose: ProConnectionPurpose;
  transferId: string;
  channelId: string;
  owner: string;
  createdAt: number;
  expiresAt: number;
  connection: ProConnectionDescription;
}
export const PRO_CONNECTION_TTL_MS: number = 120000;
export const PRO_CONNECTION_MAX_CHARS: number = 8192; // Even four-byte UTF-8 stays below 100 KB.

function fields(value: Object, allowed: string[]): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) { return false; }
  const keys: string[] = Object.keys(value);
  return keys.length === allowed.length && keys.every((key: string): boolean => allowed.indexOf(key) >= 0);
}
function text(value: Object, max: number, empty: boolean = false): boolean {
  return typeof value === 'string' && value.length <= max && (empty || value.trim().length > 0) &&
    !/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(value);
}
function finite(value: Object, min: number, max: number): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
}
function viewValid(value: Object, protocol: string): boolean {
  const keys: string[] = ['sshPane', 'sshDirectory', 'monitor', 'scale', 'panX', 'panY', 'inputMode'];
  if (protocol === 'rdp') { keys.push('strictBounds'); }
  if (!fields(value, keys)) { return false; }
  const view = value as ProConnectionView;
  if (!text(view.sshDirectory, 4096, true) ||
      (view.sshDirectory !== '' && !view.sshDirectory.startsWith('/')) ||
      (view.sshPane !== 'terminal' && view.sshPane !== 'files') ||
      !finite(view.monitor, 0, 15) || !Number.isInteger(view.monitor) ||
      !finite(view.scale, 0.1, protocol === 'rdp' ? 12 : 8) || !finite(view.panX, -100000, 100000) ||
      !finite(view.panY, -100000, 100000) ||
      ['direct', 'touchpad', 'keyboardMouse'].indexOf(view.inputMode) < 0) { return false; }
  // Unused protocol fields have one canonical value; no hidden command or route payload.
  return protocol === 'ssh'
    ? view.monitor === 0 && view.scale === 1 && view.panX === 0 && view.panY === 0 && view.inputMode === 'direct'
    : view.sshPane === 'terminal' && view.sshDirectory === '' && view.monitor === 0 &&
      typeof view.strictBounds === 'boolean';
}
export function copyProConnectionDescription(value: ProConnectionDescription): ProConnectionDescription {
  const result: ProConnectionDescription = { protocol: value.protocol, label: value.label, host: value.host, port: value.port,
    username: value.username, hostReference: value.hostReference,
    view: { sshPane: value.view.sshPane, sshDirectory: value.view.sshDirectory,
      monitor: value.view.monitor, scale: value.view.scale, panX: value.view.panX,
      panY: value.view.panY, inputMode: value.view.inputMode } };
  if (value.protocol === 'rdp' && value.rdpIdentity !== undefined) {
    result.rdpIdentity = copyProRdpConnectionIdentity(value.rdpIdentity);
    result.view.strictBounds = value.view.strictBounds;
  }
  return result;
}
export function parseProConnectionEnvelope(serialized: string, now: number = Date.now()): ProConnectionEnvelope | null {
  if (typeof serialized !== 'string' || serialized.length === 0 ||
      serialized.length > PRO_CONNECTION_MAX_CHARS || !Number.isFinite(now)) { return null; }
  try {
    const raw = JSON.parse(serialized) as Object;
    if (!fields(raw, ['version', 'purpose', 'transferId', 'channelId', 'owner', 'createdAt', 'expiresAt', 'connection'])) {
      return null;
    }
    const value = raw as ProConnectionEnvelope;
    if ((value.version !== 1 && value.version !== 2) || (value.purpose !== 'share' && value.purpose !== 'continuation') ||
        typeof value.transferId !== 'string' || !/^[a-f0-9]{32}$/.test(value.transferId) ||
        typeof value.channelId !== 'string' || !/^rd_[a-f0-9]{32}$/.test(value.channelId) ||
        !Number.isSafeInteger(value.createdAt) || !Number.isSafeInteger(value.expiresAt) ||
        value.createdAt > now + 5000 || value.createdAt < 0 || value.expiresAt <= now ||
        value.expiresAt <= value.createdAt || value.expiresAt - value.createdAt > PRO_CONNECTION_TTL_MS) { return null; }
    if (value.purpose === 'continuation'
      ? typeof value.owner !== 'string' || !/^owner-[a-f0-9]{64}$/.test(value.owner)
      : value.owner !== '') { return null; }
    const keys: string[] = ['protocol', 'label', 'host', 'port', 'username', 'hostReference', 'view'];
    if (value.version === 2) { keys.push('rdpIdentity'); }
    if (!fields(value.connection, keys)) { return null; }
    const connection = value.connection;
    if ((connection.protocol !== 'ssh' && connection.protocol !== 'rdp') ||
        !text(connection.label, 120) || !text(connection.host, 253) ||
        /[\s/\\?#@]/.test(connection.host) || !Number.isInteger(connection.port) ||
        connection.port < 1 || connection.port > 65535 || !text(connection.username, 256, true) ||
        !text(connection.hostReference, 128, value.purpose === 'share') ||
        (value.purpose === 'share' && connection.hostReference !== '') ||
        !viewValid(connection.view, connection.protocol)) { return null; }
    // V1 SSH stays byte-compatible with existing sharing/continuation clients.
    // RDP requires V2 and a bound identity; reserved V1 RDP data is not executable.
    if (connection.protocol === 'ssh' ? value.version !== 1 :
      value.version !== 2 || value.purpose !== 'continuation' || connection.rdpIdentity === undefined ||
      !validProRdpConnectionIdentity(connection.rdpIdentity) ||
      connection.username !== connection.rdpIdentity.username) { return null; }
    return { version: value.version, purpose: value.purpose, transferId: value.transferId, channelId: value.channelId,
      owner: value.owner, createdAt: value.createdAt, expiresAt: value.expiresAt,
      connection: copyProConnectionDescription(connection) };
  } catch (_error) { return null; }
}
export function sameProConnectionEndpoint(a: ProConnectionDescription, b: ProConnectionDescription): boolean {
  return a.protocol === b.protocol && a.host === b.host && a.port === b.port && a.username === b.username &&
    a.hostReference === b.hostReference && (a.protocol !== 'rdp' ||
      (a.rdpIdentity !== undefined && b.rdpIdentity !== undefined &&
        sameProRdpConnectionIdentity(a.rdpIdentity, b.rdpIdentity)));
}
