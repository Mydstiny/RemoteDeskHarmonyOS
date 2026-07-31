/**
 * Read-only aggregate contract for the third-page relay directory.
 *
 * The directory may combine entries visually, but the `kind` and `owner`
 * fields are deliberately explicit so UI actions can never accidentally send
 * a VNC Gateway mutation to HostSyncService/RustDesk storage.
 */
export type RelayDirectoryKind = 'rustdesk' | 'vnc';
export type RelayDirectoryFilter = 'all' | RelayDirectoryKind;

export interface RelayDirectoryEntry {
  kind: RelayDirectoryKind;
  id: string;
  label: string;
  endpoint: string;
  path: string;
  enabled: boolean;
  status: string;
  owner: string;
}

export function relayDirectoryMatchesFilter(kind: RelayDirectoryKind,
  filter: RelayDirectoryFilter): boolean {
  return filter === 'all' || filter === kind;
}

export function relayDirectoryOwner(kind: RelayDirectoryKind): string {
  return kind === 'vnc' ? 'VncGatewayService/vncrecordv2' : 'HostSyncService/rustdeskrelays';
}

export function relayDirectoryEntry(kind: RelayDirectoryKind, id: string, label: string,
  endpoint: string, path: string, enabled: boolean, status: string): RelayDirectoryEntry {
  return { kind, id, label, endpoint, path, enabled, status, owner: relayDirectoryOwner(kind) };
}
