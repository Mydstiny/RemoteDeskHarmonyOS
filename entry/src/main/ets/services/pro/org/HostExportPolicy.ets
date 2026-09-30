import { HostGroupDefinition, HostMembership, HostOrganizationHostView, normalizeTags } from './HostOrganizationPolicy';

export const HOST_EXPORT_SCHEMA_VERSION: number = 1;
export interface HostExportRecord extends HostOrganizationHostView { tags?: string[]; color?: string; icon?: string; }
export interface HostExportDocument { schemaVersion: number; exportedAt: number; groups: HostGroupDefinition[]; hosts: HostExportRecord[]; }

// Explicit allowlist. Credentials and runtime secrets never reach the document.
export function sanitizeHostForExport(host: HostExportRecord): HostExportRecord {
  return { id: host.id, protocol: host.protocol, host: host.host, port: host.port,
    username: host.username, label: host.label, groupId: host.groupId || '',
    tags: normalizeTags(host.tags || []) };
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
    return { schemaVersion: value.schemaVersion, exportedAt: value.exportedAt,
      groups: value.groups.slice(), hosts: value.hosts.map((host: HostExportRecord): HostExportRecord => sanitizeHostForExport(host)) };
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
