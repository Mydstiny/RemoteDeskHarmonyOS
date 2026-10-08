/** A selected remote directory is an explicit target, never inferred from a username. */
export function remoteTransferPathIsAbsolute(path: string): boolean {
  if (path.length === 0 || path.length > 32768 || /[\x00-\x1f\x7f]/.test(path)) { return false; }
  const windows: boolean = /^[A-Za-z]:[\\/]/.test(path) || path.startsWith('\\\\');
  if (!windows && !path.startsWith('/')) { return false; }
  const components: string[] = path.replace(/\\/g, '/').split('/');
  return !components.some((value: string): boolean => value === '..' || value === '.');
}

export function joinRemoteTransferPath(directory: string, name: string): string {
  if (!remoteTransferPathIsAbsolute(directory) || name.length === 0 || name === '.' || name === '..' ||
    /[\\/\x00-\x1f\x7f]/.test(name)) { return ''; }
  const windows: boolean = /^[A-Za-z]:[\\/]/.test(directory) || directory.startsWith('\\\\');
  if (windows && (/[:*?"<>|]/.test(name) || /[. ]$/.test(name) ||
    /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(name))) { return ''; }
  const separator: string = windows ? '\\' : '/';
  return directory.replace(/[\\/]+$/g, '') + separator + name;
}

export function parentRemoteTransferPath(directory: string): string {
  if (!remoteTransferPathIsAbsolute(directory)) { return ''; }
  const normalized: string = directory.replace(/[\\/]+$/g, '');
  const index: number = Math.max(normalized.lastIndexOf('/'), normalized.lastIndexOf('\\'));
  if (index < 0) { return directory; }
  if (index === 0) { return '/'; }
  if (index === 2 && /^[A-Za-z]:/.test(normalized)) { return normalized.substring(0, 3); }
  // A UNC server/share pair is a root; never navigate to a server-only path.
  if (normalized.startsWith('\\\\') && normalized.substring(2).split('\\').length <= 2) { return directory; }
  return normalized.substring(0, index);
}

/** Fixed RustDesk FileType::DirDrive uses a drive name such as C:, never a child path. */
export function remoteTransferEntryPath(directory: string, name: string, type: number): string {
  if (type === 3) { return /^[A-Za-z]:$/.test(name) ? name + '\\' : ''; }
  return joinRemoteTransferPath(directory, name);
}

/** A preflight name choice still uses no-overwrite on the wire to close races. */
export function renamedRemoteTransferFileName(name: string, occupied: string[]): string {
  const keys: Set<string> = new Set<string>(occupied.map((value: string): string => value.normalize('NFC').toLowerCase()));
  if (!keys.has(name.normalize('NFC').toLowerCase())) { return name; }
  const dot: number = name.lastIndexOf('.');
  const stem: string = dot > 0 ? name.substring(0, dot) : name;
  const extension: string = dot > 0 ? name.substring(dot) : '';
  for (let index: number = 1; index <= 1024; index++) {
    const candidate: string = stem + ' (' + index.toString() + ')' + extension;
    if (candidate.length <= 255 && !keys.has(candidate.normalize('NFC').toLowerCase())) { return candidate; }
  }
  return '';
}
