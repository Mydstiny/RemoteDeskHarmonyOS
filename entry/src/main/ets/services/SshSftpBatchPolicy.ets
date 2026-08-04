/**
 * Pure policy for SFTP recursive batches.
 *
 * Providers perform I/O and return a flattened tree. This module validates
 * that tree before any transfer task is created.
 */
export type SshSftpConflictPolicy = 'ask' | 'overwrite' | 'skip' | 'keepBoth' | 'resume';
export type SshSftpVerificationPolicy = 'sizeMtime' | 'sizeOnly';

export interface SshSftpBatchLimits {
  maxDepth: number;
  maxItems: number;
  maxFiles: number;
  maxTotalBytes: number;
  maxSingleFileBytes: number;
  maxPathLength: number;
  allowSymbolicLinks: boolean;
  allowSpecialFiles: boolean;
}

export interface SshSftpTreeItem {
  relativePath: string;
  name: string;
  isDirectory: boolean;
  isSymbolicLink: boolean;
  isSpecialFile: boolean;
  size: number;
  mtime: number;
  mode: number;
  uid: number;
  gid: number;
}

export interface SshSftpBatchPlan {
  accepted: boolean;
  reason: string;
  rejectedPath: string;
  items: SshSftpTreeItem[];
  fileCount: number;
  totalBytes: number;
}

export interface SshSftpConflictResolution {
  action: 'ask' | 'overwrite' | 'skip' | 'keepBoth' | 'resume';
  requiresDecision: boolean;
}

export interface SshSftpRelativePathInfo {
  valid: boolean;
  depth: number;
  normalized: string;
  reason: string;
}

export const DEFAULT_SSH_SFTP_BATCH_LIMITS: SshSftpBatchLimits = {
  maxDepth: 32,
  maxItems: 10000,
  maxFiles: 5000,
  maxTotalBytes: 10 * 1024 * 1024 * 1024,
  maxSingleFileBytes: 4 * 1024 * 1024 * 1024,
  maxPathLength: 2048,
  allowSymbolicLinks: false,
  allowSpecialFiles: false
};

function invalidPlan(reason: string, path: string): SshSftpBatchPlan {
  return {
    accepted: false,
    reason,
    rejectedPath: path,
    items: [],
    fileCount: 0,
    totalBytes: 0
  };
}

function validLimits(limits: SshSftpBatchLimits): boolean {
  return Number.isFinite(limits.maxDepth) && limits.maxDepth > 0 &&
    Number.isFinite(limits.maxItems) && limits.maxItems > 0 &&
    Number.isFinite(limits.maxFiles) && limits.maxFiles > 0 &&
    Number.isFinite(limits.maxTotalBytes) && limits.maxTotalBytes >= 0 &&
    Number.isFinite(limits.maxSingleFileBytes) && limits.maxSingleFileBytes >= 0 &&
    Number.isFinite(limits.maxPathLength) && limits.maxPathLength > 0;
}

function normalizedSegments(path: string, allowAbsolute: boolean): string[] | null {
  if (typeof path !== 'string' || path.length === 0 || path.indexOf('\0') >= 0) {
    return null;
  }
  if (!allowAbsolute && (path.startsWith('/') || path.startsWith('\\'))) { return null; }
  const parts: string[] = path.replace(/\\/g, '/').split('/');
  const result: string[] = [];
  for (let index = 0; index < parts.length; index++) {
    const part: string = parts[index];
    if (part.length === 0 || part === '.') { continue; }
    if (part === '..') {
      if (result.length === 0) { return null; }
      result.pop();
      continue;
    }
    result.push(part);
  }
  return result.length === 0 ? null : result;
}

/** Normalize a remote path without allowing traversal above its root. */
export function normalizeSshSftpRemotePath(path: string): string | null {
  if (typeof path !== 'string' || path.trim().length === 0 || path.indexOf('\0') >= 0) {
    return null;
  }
  const raw: string = path.trim().replace(/\\/g, '/');
  const absolute: boolean = raw.startsWith('/');
  const parts: string[] = raw.split('/');
  const result: string[] = [];
  for (let index = 0; index < parts.length; index++) {
    const part: string = parts[index];
    if (part.length === 0 || part === '.') { continue; }
    if (part === '..') {
      if (result.length === 0) { return null; }
      result.pop();
      continue;
    }
    result.push(part);
  }
  if (result.length === 0) { return absolute ? '/' : '.'; }
  return (absolute ? '/' : '') + result.join('/');
}

/** Join a directory and a single child name after validating both sides. */
export function joinSshSftpRemotePath(parent: string, child: string): string | null {
  const normalizedParent: string | null = normalizeSshSftpRemotePath(parent);
  if (normalizedParent === null) { return null; }
  const childParts: string[] | null = normalizedSegments(child, false);
  if (childParts === null || childParts.length !== 1) { return null; }
  const joined: string = normalizedParent === '/' ? '/' + childParts[0] :
    (normalizedParent === '.' ? './' + childParts[0] : normalizedParent + '/' + childParts[0]);
  return normalizeSshSftpRemotePath(joined);
}

/** Join a validated relative tree path to a remote directory root. */
export function joinSshSftpRelativeRemotePath(parent: string, relativePath: string): string | null {
  const normalizedParent: string | null = normalizeSshSftpRemotePath(parent);
  const parts: string[] | null = normalizedSegments(relativePath, false);
  if (normalizedParent === null || parts === null) { return null; }
  let current: string = normalizedParent;
  for (let index = 0; index < parts.length; index++) {
    const next: string | null = joinSshSftpRemotePath(current, parts[index]);
    if (next === null) { return null; }
    current = next;
  }
  return current;
}

function relativePathInfo(path: string, limits: SshSftpBatchLimits): SshSftpRelativePathInfo {
  if (typeof path !== 'string' || path.length === 0 || path.length > limits.maxPathLength) {
    return { valid: false, depth: 0, normalized: '', reason: 'path-length' };
  }
  const parts: string[] | null = normalizedSegments(path, false);
  if (parts === null) {
    return { valid: false, depth: 0, normalized: '', reason: 'path-traversal' };
  }
  const normalized: string = parts.join('/');
  if (normalized.length > limits.maxPathLength) {
    return { valid: false, depth: parts.length, normalized: '', reason: 'path-length' };
  }
  return { valid: true, depth: parts.length, normalized, reason: '' };
}

function hasPathPrefix(items: SshSftpTreeItem[], path: string): boolean {
  const prefix: string = path + '/';
  for (let index = 0; index < items.length; index++) {
    if (items[index].relativePath !== path && items[index].relativePath.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

/** Validate limits, traversal, duplicates, file types and aggregate size. */
export function planSshSftpBatch(items: SshSftpTreeItem[],
  limits: SshSftpBatchLimits = DEFAULT_SSH_SFTP_BATCH_LIMITS): SshSftpBatchPlan {
  if (!validLimits(limits)) { return invalidPlan('invalid-limits', ''); }
  if (!Array.isArray(items) || items.length === 0) { return invalidPlan('empty-batch', ''); }
  if (items.length > limits.maxItems) { return invalidPlan('item-limit', ''); }

  const accepted: SshSftpTreeItem[] = [];
  let fileCount: number = 0;
  let totalBytes: number = 0;
  for (let index = 0; index < items.length; index++) {
    const item: SshSftpTreeItem = items[index];
    const info = relativePathInfo(item.relativePath, limits);
    if (!info.valid) { return invalidPlan(info.reason, item.relativePath); }
    if (info.depth > limits.maxDepth) { return invalidPlan('depth-limit', info.normalized); }
    if (item.name.trim().length === 0 || item.name.indexOf('/') >= 0 || item.name.indexOf('\\') >= 0 ||
      item.name.indexOf('\0') >= 0) {
      return invalidPlan('invalid-name', info.normalized);
    }
    if (item.isSymbolicLink && !limits.allowSymbolicLinks) {
      return invalidPlan('symbolic-link-not-allowed', info.normalized);
    }
    if (item.isSpecialFile && !limits.allowSpecialFiles) {
      return invalidPlan('special-file-not-allowed', info.normalized);
    }
    if (!item.isDirectory) {
      if (!Number.isFinite(item.size) || item.size < 0) {
        return invalidPlan('unknown-file-size', info.normalized);
      }
      if (item.size > limits.maxSingleFileBytes) {
        return invalidPlan('single-file-limit', info.normalized);
      }
      fileCount++;
      totalBytes += item.size;
      if (fileCount > limits.maxFiles || totalBytes > limits.maxTotalBytes) {
        return invalidPlan(fileCount > limits.maxFiles ? 'file-limit' : 'total-size-limit', info.normalized);
      }
    }
    for (let previous = 0; previous < accepted.length; previous++) {
      if (accepted[previous].relativePath === info.normalized) {
        return invalidPlan('duplicate-path', info.normalized);
      }
    }
    const normalizedItem: SshSftpTreeItem = {
      relativePath: info.normalized,
      name: item.name,
      isDirectory: item.isDirectory,
      isSymbolicLink: item.isSymbolicLink,
      isSpecialFile: item.isSpecialFile,
      size: item.size,
      mtime: item.mtime,
      mode: item.mode,
      uid: item.uid,
      gid: item.gid
    };
    accepted.push(normalizedItem);
  }

  for (let index = 0; index < accepted.length; index++) {
    const item: SshSftpTreeItem = accepted[index];
    if (!item.isDirectory && hasPathPrefix(accepted, item.relativePath)) {
      return invalidPlan('file-directory-conflict', item.relativePath);
    }
  }
  accepted.sort((left: SshSftpTreeItem, right: SshSftpTreeItem): number =>
    left.relativePath.localeCompare(right.relativePath));
  return { accepted: true, reason: '', rejectedPath: '', items: accepted, fileCount, totalBytes };
}

export function resolveSshSftpConflict(existing: boolean, partial: boolean,
  policy: SshSftpConflictPolicy): SshSftpConflictResolution {
  if (!existing && !partial) { return { action: 'overwrite', requiresDecision: false }; }
  if (policy === 'ask') { return { action: 'ask', requiresDecision: true }; }
  if (policy === 'resume' && partial) { return { action: 'resume', requiresDecision: false }; }
  if (policy === 'keepBoth') { return { action: 'keepBoth', requiresDecision: false }; }
  if (policy === 'skip') { return { action: 'skip', requiresDecision: false }; }
  return { action: 'overwrite', requiresDecision: false };
}

/** Return a deterministic sibling name for a keep-both conflict decision. */
export function nextSshSftpKeepBothName(name: string, existingNames: string[]): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) { return ''; }
  let stem: string = trimmed;
  let extension: string = '';
  const dot: number = trimmed.lastIndexOf('.');
  if (dot > 0 && dot < trimmed.length - 1) {
    stem = trimmed.substring(0, dot);
    extension = trimmed.substring(dot);
  }
  for (let suffix: number = 1; suffix <= 10000; suffix++) {
    const candidate: string = stem + ' (' + suffix.toString() + ')' + extension;
    if (existingNames.indexOf(candidate) < 0) { return candidate; }
  }
  return '';
}
