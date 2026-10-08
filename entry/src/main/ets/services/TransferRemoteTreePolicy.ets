import { SessionRemoteDirectory, SessionRemoteFileEntry } from '../types/rdpnapi';
import { joinRemoteTransferPath, remoteTransferPathIsAbsolute } from './TransferRemotePathPolicy';

export interface RemoteTransferTreeItem {
  path: string;
  relativePath: string;
  entry: SessionRemoteFileEntry;
}
export interface RemoteTransferTree {
  items: RemoteTransferTreeItem[];
  totalBytes: number;
}

export function sameRemoteTransferDirectory(a: string, b: string): boolean {
  const normalize = (path: string): string => {
    const value: string = path.replace(/\\/g, '/').replace(/\/+$/g, '');
    return /^[A-Za-z]:/.test(value) || value.startsWith('//') ? value.toLowerCase() : value;
  };
  return remoteTransferPathIsAbsolute(a) && remoteTransferPathIsAbsolute(b) && normalize(a) === normalize(b);
}

/** Preflight the entire tree before creating a receive batch; never follow remote links. */
export async function collectRemoteTransferTree(root: string, rootName: string,
  list: (path: string) => Promise<SessionRemoteDirectory | null>, current: () => boolean): Promise<RemoteTransferTree> {
  if (!remoteTransferPathIsAbsolute(root) || !rootName || /[\\/\x00-\x1f]/.test(rootName) ||
    rootName === '.' || rootName === '..') { throw new Error('remote_tree_root_invalid'); }
  const result: RemoteTransferTree = { items: [], totalBytes: 0 };
  const names: Set<string> = new Set<string>();
  const visit = async (path: string, relativePath: string, depth: number): Promise<void> => {
    if (!current()) { throw new Error('remote_tree_cancelled'); }
    if (depth > 32) { throw new Error('remote_tree_depth'); }
    const directory: SessionRemoteDirectory | null = await list(path);
    if (!current()) { throw new Error('remote_tree_cancelled'); }
    if (directory === null || !sameRemoteTransferDirectory(directory.path, path)) { throw new Error('remote_tree_directory_unconfirmed'); }
    for (const entry of directory.entries) {
      if (!current()) { throw new Error('remote_tree_cancelled'); }
      const child: string = joinRemoteTransferPath(path, entry.name);
      const relative: string = relativePath + '/' + entry.name;
      const key: string = relative.normalize('NFC').toLowerCase();
      if (child.length === 0 || names.has(key) || (entry.type !== 0 && entry.type !== 4)) {
        throw new Error('remote_tree_unsupported_or_collision');
      }
      names.add(key);
      if (result.items.length >= 1024) { throw new Error('remote_tree_count'); }
      if (!Number.isSafeInteger(entry.size) || entry.size < 0 || !Number.isSafeInteger(entry.modifiedTime) || entry.modifiedTime < 0) {
        throw new Error('remote_tree_metadata');
      }
      if (entry.type === 4) { result.totalBytes += entry.size; }
      if (result.totalBytes > 2147483648) { throw new Error('remote_tree_size'); }
      result.items.push({ path: child, relativePath: relative, entry });
      if (entry.type === 0) { await visit(child, relative, depth + 1); }
    }
  };
  result.items.push({ path: root, relativePath: rootName, entry: { name: rootName, type: 0, size: 0, modifiedTime: 0 } });
  names.add(rootName.normalize('NFC').toLowerCase());
  await visit(root, rootName, 0);
  return result;
}

/**
 * The same tree from the peer's own recursive listing (every file below `root`, names relative to it, '/' separated),
 * with the folders those files live in. Budgets and collision checks match collectRemoteTransferTree.
 */
export function remoteTransferTreeFromFiles(root: string, rootName: string,
  listing: SessionRemoteDirectory): RemoteTransferTree {
  if (!remoteTransferPathIsAbsolute(root) || !rootName || /[\\/\x00-\x1f]/.test(rootName) ||
    rootName === '.' || rootName === '..') { throw new Error('remote_tree_root_invalid'); }
  const result: RemoteTransferTree = { items: [], totalBytes: 0 };
  const names: Set<string> = new Set<string>();
  result.items.push({ path: root, relativePath: rootName, entry: { name: rootName, type: 0, size: 0, modifiedTime: 0 } });
  names.add(rootName.normalize('NFC').toLowerCase());
  const add = (path: string, relativePath: string, entry: SessionRemoteFileEntry): void => {
    const key: string = relativePath.normalize('NFC').toLowerCase();
    if (names.has(key)) {
      if (entry.type === 0) { return; }
      throw new Error('remote_tree_unsupported_or_collision');
    }
    names.add(key);
    if (result.items.length >= 1024) { throw new Error('remote_tree_count'); }
    result.items.push({ path, relativePath, entry });
  };
  for (const file of listing.entries) {
    if (file.type !== 4) { continue; }
    const parts: string[] = file.name.split('/');
    if (parts.length > 32 || parts.some((part: string): boolean => part.length === 0 || part === '.' || part === '..' ||
      /[\\\x00-\x1f]/.test(part))) { throw new Error('remote_tree_unsupported_or_collision'); }
    if (!Number.isSafeInteger(file.size) || file.size < 0 || !Number.isSafeInteger(file.modifiedTime) ||
      file.modifiedTime < 0) { throw new Error('remote_tree_metadata'); }
    let path: string = root;
    let relative: string = rootName;
    for (let i: number = 0; i < parts.length; i++) {
      path = joinRemoteTransferPath(path, parts[i]);
      relative = relative + '/' + parts[i];
      if (path.length === 0) { throw new Error('remote_tree_unsupported_or_collision'); }
      if (i < parts.length - 1) {
        add(path, relative, { name: parts[i], type: 0, size: 0, modifiedTime: 0 });
      } else {
        add(path, relative, { name: parts[i], type: 4, size: file.size, modifiedTime: file.modifiedTime });
        result.totalBytes += file.size;
        if (result.totalBytes > 2147483648) { throw new Error('remote_tree_size'); }
      }
    }
  }
  return result;
}
