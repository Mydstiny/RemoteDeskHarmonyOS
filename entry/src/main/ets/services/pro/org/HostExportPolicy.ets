import { HostGroupDefinition, HostMembership, HostOrganizationHostView, normalizeTags } from './HostOrganizationPolicy';

export const HOST_EXPORT_SCHEMA_VERSION: number = 1;
export interface HostExportRecord extends HostOrganizationHostView { tags?: string[]; color?: string; icon?: string; }
export interface HostExportDocument { schemaVersion: number; exportedAt: number; groups: HostGroupDefinition[]; hosts: HostExportRecord[]; }

// Explicit allowlist. Credentials and runtime secrets never reach the document.
function text(value: Object | undefined, max: number): string {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

export function sanitizeHostForExport(host: HostExportRecord): HostExportRecord {
  const port: number = typeof host.port === 'number' && Number.isInteger(host.port) && host.port > 0 &&
    host.port <= 65535 ? host.port : 0;
  return { id: text(host.id, 160), protocol: text(host.protocol, 32), host: text(host.host, 255), port,
    username: text(host.username, 256), label: text(host.label, 128), groupId: text(host.groupId, 64),
    tags: normalizeTags(Array.isArray(host.tags) ? host.tags : []) };
}

export function exportHosts(hosts: HostExportRecord[], groups: HostGroupDefinition[], nowMs: number = Date.now()): string {
  const document: HostExportDocument = { schemaVersion: HOST_EXPORT_SCHEMA_VERSION, exportedAt: nowMs,
    groups: groups.slice(), hosts: hosts.map((host: HostExportRecord): HostExportRecord => sanitizeHostForExport(host)) };
  return JSON.stringify(document);
}

export function parseHostExport(raw: string): HostExportDocument | null {
  try {
    const value: HostExportDocument = JSON.parse(raw) as HostExportDocument;
    if (!value || value.schemaVersion !== HOST_EXPORT_SCHEMA_VERSION || !Array.isArray(value.groups) ||
        !Array.isArray(value.hosts) || value.hosts.length > 10000) { return null; }
    const groups: HostGroupDefinition[] = value.groups.filter((group: HostGroupDefinition): boolean =>
      group !== null && typeof group === 'object' && typeof group.id === 'string' && typeof group.name === 'string')
      .slice(0, 100);
    const hosts: HostExportRecord[] = value.hosts.filter((host: HostExportRecord): boolean =>
      host !== null && typeof host === 'object').map((host: HostExportRecord): HostExportRecord => sanitizeHostForExport(host))
      .filter((host: HostExportRecord): boolean => host.protocol.length > 0 && host.label.length > 0);
    return { schemaVersion: value.schemaVersion, exportedAt: Number(value.exportedAt) || 0, groups, hosts };
  } catch (_error) { return null; }
}

export function exportContainsSensitiveFields(raw: string): boolean {
  return /(?:password|privateKey|passphrase|token|secret|credential|sshKeyData)/i.test(raw);
}

export function dedupeImportedHosts(hosts: HostExportRecord[], existing: HostExportRecord[]): HostExportRecord[] {
  const keys: Set<string> = new Set<string>(existing.map((host: HostExportRecord): string =>
    [host.protocol, host.host.trim().toLowerCase(), host.port.toString(), host.username.trim().toLowerCase()].join('|')));
  const result: HostExportRecord[] = [];
  hosts.forEach((host: HostExportRecord): void => {
    const clean: HostExportRecord = sanitizeHostForExport(host);
    const key: string = [clean.protocol, clean.host.trim().toLowerCase(), clean.port.toString(), clean.username.trim().toLowerCase()].join('|');
    if (!keys.has(key)) { keys.add(key); result.push(clean); }
  });
  return result;
}

export function hostExportFileName(nowMs: number = Date.now()): string {
  const date: Date = new Date(nowMs);
  const pad = (value: number): string => (value < 10 ? '0' : '') + value.toString();
  return 'RemoteDesk-hosts-' + date.getFullYear().toString() + pad(date.getMonth() + 1) + pad(date.getDate()) + '.json';
}

export function hostImportKey(host: HostExportRecord): string {
  return [host.protocol, host.host.trim().toLowerCase(), host.port.toString(), host.username.trim().toLowerCase()].join('|');
}

/** Protocols whose hosts can be re-created from an export (the user still enters credentials). */
export function hostImportSupported(protocol: string): boolean {
  return protocol === 'rdp' || protocol === 'ssh' || protocol === 'vnc';
}
