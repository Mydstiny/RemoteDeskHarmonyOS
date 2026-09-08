import { fileIo, fileUri, statfs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export const TRANSFER_COPY_BLOCK_BYTES: number = 64 * 1024;
export const TRANSFER_FILE_LIMIT_BYTES: number = 2 * 1024 * 1024 * 1024;
export const TRANSFER_CACHE_QUOTA_BYTES: number = 4 * 1024 * 1024 * 1024;
const TRANSFER_SPACE_RESERVE: number = 32 * 1024 * 1024;
const TRANSFER_BATCH_LIMIT: number = 15;
const DEFAULT_ARTIFACT_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
const MANIFEST_LIMIT_BYTES: number = 2 * 1024 * 1024;
export type ArtifactPurpose = 'clipboard' | 'received';
type ArtifactState = 'partial' | 'complete' | 'removed';

export interface TransferArtifact {
  id: string;
  name: string;
  path: string;
  size: number;
  mtime: number;
  sha256: string;
  relativePath?: string;
  directory?: boolean;
}
export interface TransferLocalTreeSource {
  uri: string;
  relativePath: string;
  directory: boolean;
  size: number;
  mtime: number;
}
interface LocalTreeSourceIdentity {
  source: TransferLocalTreeSource;
  path: string;
  stat: fileIo.Stat;
}
interface LocalTreePlan {
  sources: TransferLocalTreeSource[];
  rootPath: string;
  rootName: string;
  totalBytes: number;
}
interface ArtifactManifestEntry {
  id: string;
  name: string;
  size: number;
  mtime: number;
  sha256: string;
  state: ArtifactState;
  storageRelativePath: string;
  relativePath: string;
  directory: boolean;
}
interface ArtifactPublicationManifest {
  id: string;
  kind: 'native' | 'system';
}
interface NativeDirectoryManifest {
  id: string;
  state: 'active' | 'retained' | 'complete' | 'aborted';
  layout?: 'rdpReceive' | 'localTree';
}
export interface TransferNativeReceivedEntry {
  index: number;
  relativeName: string;
  directory: boolean;
  size: number;
}
interface ArtifactManifest {
  schemaVersion: number;
  id: string;
  createdAt: number;
  updatedAt: number;
  scopeKey: string;
  purpose: string;
  published: boolean;
  holders: string[];
  artifacts: ArtifactManifestEntry[];
  nativeDirectories: NativeDirectoryManifest[];
  platformDirectories: NativeDirectoryManifest[];
  publications: ArtifactPublicationManifest[];
  untrackedPublished: boolean;
}
export interface TransferArtifactBatchInfo {
  id: string;
  purpose: ArtifactPurpose;
  createdAt: number;
  updatedAt: number;
  fileCount: number;
  directoryCount: number;
  bytes: number;
  held: boolean;
  published: boolean;
  unknown: boolean;
  active: boolean;
  canCleanup: boolean;
  retentionReason: string;
}
export interface TransferArtifactInventory {
  artifacts: TransferArtifact[];
  batches: TransferArtifactBatchInfo[];
  invalidBatches: number;
}
interface ImportedArtifactEntry {
  storageRelativePath: string;
  relativePath: string;
  directory: boolean;
  size: number;
}
export interface TransferArtifactCleanupResult {
  removedFiles: number;
  removedBytes: number;
  retainedBatches: number;
  invalidBatches: number;
}
export interface TransferArtifactExportResult {
  status: 'saved' | 'cancelled' | 'failed' | 'commitUnknown';
  writtenBytes: number;
  sha256: string;
  verified: boolean;
  diagnosticCode: string;
  evidence: 'none' | 'writtenAndSynced';
}

function digestHex(bytes: Uint8Array): string {
  let value: string = '';
  for (let index: number = 0; index < bytes.length; index++) {
    value += bytes[index].toString(16).padStart(2, '0');
  }
  return value;
}
function validId(value: string): boolean { return typeof value === 'string' && /^[a-zA-Z0-9-]{8,80}$/.test(value); }
function validCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }
function current(guard: () => boolean): boolean { try { return guard(); } catch (_error) { return false; } }
function checkCurrent(guard: () => boolean): void { if (!current(guard)) { throw new Error('transfer_cancelled'); } }
function safeProgress(progress: (copied: number, total: number) => void, copied: number, total: number): void {
  try { progress(copied, total); } catch (_error) { /* Observers cannot undo a committed copy. */ }
}
function partialName(name: string): string { return name === 'content.partial' ? '_content.partial' : 'content.partial'; }
function artifactNameKey(name: string): string { return name.normalize('NFC').toLowerCase(); }

/** Short, non-secret namespace; never use a display/drive name as an owner. */
export function transferScopeKey(accountScope: string, hostIdentity: string): string {
  if (accountScope.length === 0 || hostIdentity.length === 0) { throw new Error('transfer_scope_invalid'); }
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: new util.TextEncoder().encode(accountScope.length.toString() + ':' + accountScope + hostIdentity) });
  return digestHex(digest.digestSync().data);
}
export function safeTransferFileName(value: string): string {
  let name: string = value.replace(/[\\/:*?"<>|\x00-\x1f\x7f]/g, '_').replace(/[. ]+$/g, '').trim();
  // Isolated UTF-16 surrogates cannot become stable filenames across providers.
  let unicode: string = '';
  for (let i: number = 0; i < name.length; i++) {
    const unit: number = name.charCodeAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      const low: number = i + 1 < name.length ? name.charCodeAt(i + 1) : 0;
      if (low >= 0xDC00 && low <= 0xDFFF) { unicode += name.substring(i, i + 2); i++; } else { unicode += '_'; }
    } else { unicode += unit >= 0xDC00 && unit <= 0xDFFF ? '_' : name.charAt(i); }
  }
  name = unicode;
  if (name === '' || name === '.' || name === '..') { name = 'file'; }
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(name)) { name = '_' + name; }
  const encoder = new util.TextEncoder();
  while (encoder.encode(name).byteLength > 180) {
    const end: number = name.charCodeAt(name.length - 1);
    name = name.substring(0, name.length - (end >= 0xDC00 && end <= 0xDFFF ? 2 : 1));
  }
  return name;
}
function assertDirectory(path: string): void {
  const info: fileIo.Stat = fileIo.lstatSync(path);
  if (!info.isDirectory() || info.isSymbolicLink()) { throw new Error('transfer_directory_invalid'); }
}
function ensurePrivateDirectory(path: string): void {
  try { fileIo.mkdirSync(path); } catch (_error) { /* Existing object is verified below. */ }
  assertDirectory(path);
}
function validateFilesDir(filesDir: string): void {
  if (!filesDir.startsWith('/') || filesDir.indexOf('\0') >= 0 || filesDir.indexOf('\\') >= 0 ||
    filesDir.split('/').some((part: string): boolean => part === '..' || part === '.')) {
    throw new Error('transfer_root_invalid');
  }
  assertDirectory(filesDir);
}
export function ensureTransferScopeDirectory(filesDir: string, scopeKey: string,
  purpose: 'clipboard' | 'received' | 'rdp-shared'): string {
  validateFilesDir(filesDir);
  if (!/^[a-f0-9]{64}$/.test(scopeKey) || ['clipboard', 'received', 'rdp-shared'].indexOf(purpose) < 0) {
    throw new Error('transfer_scope_invalid');
  }
  const root: string = filesDir + '/transfer-artifacts-v1';
  ensurePrivateDirectory(root);
  const scope: string = root + '/' + scopeKey;
  ensurePrivateDirectory(scope);
  const directory: string = scope + '/' + purpose;
  ensurePrivateDirectory(directory);
  return directory;
}
function validateBatchPath(filesDir: string, scopeKey: string, purpose: ArtifactPurpose, batchId: string): string {
  validateFilesDir(filesDir);
  if (!/^[a-f0-9]{64}$/.test(scopeKey) || !validId(batchId) ||
    (purpose !== 'clipboard' && purpose !== 'received')) { throw new Error('transfer_manifest_invalid'); }
  const root: string = filesDir + '/transfer-artifacts-v1';
  const scope: string = root + '/' + scopeKey;
  const parent: string = scope + '/' + purpose;
  const batch: string = parent + '/batch-' + batchId;
  for (const path of [root, scope, parent, batch]) { assertDirectory(path); }
  return batch;
}
function readManifest(filesDir: string, scopeKey: string, purpose: ArtifactPurpose, batchId: string): ArtifactManifest {
  const directory: string = validateBatchPath(filesDir, scopeKey, purpose, batchId);
  const path: string = directory + '/manifest.json';
  const info: fileIo.Stat = fileIo.lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size <= 0 || info.size > MANIFEST_LIMIT_BYTES) {
    throw new Error('transfer_manifest_invalid');
  }
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  let text: string = '';
  try {
    const buffer: ArrayBuffer = new ArrayBuffer(info.size);
    let read: number = 0;
    while (read < info.size) {
      const remaining: ArrayBuffer = new ArrayBuffer(info.size - read);
      const count: number = fileIo.readSync(file.fd, remaining);
      if (count <= 0 || count > remaining.byteLength) { throw new Error('transfer_manifest_invalid'); }
      new Uint8Array(buffer).set(new Uint8Array(remaining, 0, count), read); read += count;
    }
    text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(buffer));
  } finally { fileIo.closeSync(file); }
  const parsed: ArtifactManifest = JSON.parse(text) as ArtifactManifest;
  if ((parsed.schemaVersion !== 1 && parsed.schemaVersion !== 2) || parsed.id !== batchId ||
    parsed.scopeKey !== scopeKey || parsed.purpose !== purpose || !validCount(parsed.createdAt) ||
    !Array.isArray(parsed.artifacts) || parsed.artifacts.length > 1024) {
    throw new Error('transfer_manifest_invalid');
  }
  const legacy: boolean = parsed.schemaVersion === 1;
  if (!legacy && (!validCount(parsed.updatedAt) || typeof parsed.published !== 'boolean' ||
    !Array.isArray(parsed.holders) || parsed.holders.length > 64 || parsed.holders.some(
      (holder: string): boolean => typeof holder !== 'string' || !/^[a-zA-Z0-9_.:@-]{1,128}$/.test(holder)))) {
    throw new Error('transfer_manifest_invalid');
  }
  const nativeDirectories: NativeDirectoryManifest[] = parseOwnedDirectories(parsed.nativeDirectories);
  const platformDirectories: NativeDirectoryManifest[] = parseOwnedDirectories(parsed.platformDirectories);
  const publications: ArtifactPublicationManifest[] = [];
  if (parsed.publications !== undefined) {
    if (!Array.isArray(parsed.publications) || parsed.publications.length > 64) { throw new Error('transfer_manifest_invalid'); }
    for (const item of parsed.publications) {
      if (item === null || !validId(item.id) || (item.kind !== 'native' && item.kind !== 'system') ||
        publications.some((other: ArtifactPublicationManifest): boolean => other.id === item.id)) { throw new Error('transfer_manifest_invalid'); }
      publications.push({ id: item.id, kind: item.kind });
    }
  }
  const artifacts: ArtifactManifestEntry[] = [];
  const names: string[] = [];
  for (let i: number = 0; i < parsed.artifacts.length; i++) {
    const item: ArtifactManifestEntry = parsed.artifacts[i];
    if (item === null) { throw new Error('transfer_manifest_invalid'); }
    const state: ArtifactState = legacy ? 'complete' : item.state;
    const native: boolean = typeof item.storageRelativePath === 'string' && item.storageRelativePath.length > 0;
    const directory: boolean = !legacy && item.directory === true;
    const relativePath: string = !legacy && typeof item.relativePath === 'string' && item.relativePath.length > 0 ? item.relativePath : item.name;
    const storageRelativePath: string = native ? item.storageRelativePath : '';
    if ((native && (!validRelativeTransferPath(relativePath) || !validRelativeTransferPath(storageRelativePath, 36, 1200) ||
      !(nativeDirectories.some((owner: NativeDirectoryManifest): boolean => storageRelativePath.startsWith('native-' + owner.id + '/')) ||
        platformDirectories.some((owner: NativeDirectoryManifest): boolean => storageRelativePath.startsWith('incoming-' + owner.id + '/'))) ||
      relativePath.split('/').pop() !== item.name)) || !validRelativeTransferPath(relativePath) ||
      (directory && item.size !== 0) || item === null || !validId(item.id) || typeof item.name !== 'string' || (!native && item.name !== safeTransferFileName(item.name)) ||
      !validCount(item.size) || item.size > TRANSFER_FILE_LIMIT_BYTES || !Number.isFinite(item.mtime) || item.mtime < 0 ||
      (state !== 'partial' && state !== 'complete' && state !== 'removed') ||
      (state === 'complete' && !directory && !/^[a-f0-9]{64}$/.test(item.sha256)) ||
      (state !== 'complete' && item.sha256 !== '' && !/^[a-f0-9]{64}$/.test(item.sha256)) ||
      artifacts.some((existing: ArtifactManifestEntry): boolean => existing.id === item.id) ||
      names.indexOf(artifactNameKey(relativePath)) >= 0) { throw new Error('transfer_manifest_invalid'); }
    artifacts.push({ id: item.id, name: item.name, size: item.size, mtime: item.mtime, sha256: item.sha256, state, storageRelativePath, relativePath, directory });
    names.push(artifactNameKey(relativePath));
  }
  resolveNativeDirectoryLayouts(nativeDirectories, artifacts);
  return { schemaVersion: 2, id: batchId, createdAt: parsed.createdAt,
    updatedAt: legacy ? parsed.createdAt : parsed.updatedAt, scopeKey, purpose,
    published: legacy || parsed.published || publications.length > 0, holders: legacy ? ['legacy-unknown'] : parsed.holders.slice(), artifacts, nativeDirectories, platformDirectories, publications,
    untrackedPublished: legacy || parsed.untrackedPublished === true || (parsed.published && publications.length === 0) };
}
function parseOwnedDirectories(value: NativeDirectoryManifest[] | undefined): NativeDirectoryManifest[] {
  const result: NativeDirectoryManifest[] = [];
  if (value === undefined) { return result; }
  if (!Array.isArray(value) || value.length > 15) { throw new Error('transfer_manifest_invalid'); }
  for (const item of value) {
    if (item === null || !validId(item.id) || ['active', 'retained', 'complete', 'aborted'].indexOf(item.state) < 0 ||
      (item.layout !== undefined && item.layout !== 'rdpReceive' && item.layout !== 'localTree') ||
      result.some((other: NativeDirectoryManifest): boolean => other.id === item.id)) { throw new Error('transfer_manifest_invalid'); }
    const owner: NativeDirectoryManifest = { id: item.id, state: item.state };
    if (item.layout !== undefined) { owner.layout = item.layout; }
    result.push(owner);
  }
  return result;
}
/** Schema 2 predates the layout discriminator. Its recorded path mapping is
 * sufficient to distinguish old local trees from RDP receive-N/files trees.
 * Mixed/forged mappings remain invalid; an empty old container uses the stricter
 * RDP layout, which cannot authorize deleting any unrecorded object.
 */
function resolveNativeDirectoryLayouts(owners: NativeDirectoryManifest[], artifacts: ArtifactManifestEntry[]): void {
  for (const owner of owners) {
    const prefix: string = 'native-' + owner.id + '/';
    const entries: ArtifactManifestEntry[] = artifacts.filter((entry: ArtifactManifestEntry): boolean =>
      entry.storageRelativePath.startsWith(prefix));
    const local: boolean = entries.every((entry: ArtifactManifestEntry): boolean =>
      entry.storageRelativePath === prefix + entry.relativePath);
    const rdp: boolean = entries.every((entry: ArtifactManifestEntry): boolean => {
      const path: string = entry.storageRelativePath.substring(prefix.length);
      const parts: string[] = path.split('/');
      return parts.length >= 3 && /^receive-[0-9]+$/.test(parts[0]) && parts[1] === 'files' &&
        parts.slice(2).join('/') === entry.relativePath;
    });
    if (owner.layout === undefined) {
      if (entries.length > 0 && local) { owner.layout = 'localTree'; }
      else if (rdp) { owner.layout = 'rdpReceive'; }
      else { throw new Error('transfer_manifest_layout_invalid'); }
    }
    if ((owner.layout === 'localTree' && !local) || (owner.layout === 'rdpReceive' && !rdp)) {
      throw new Error('transfer_manifest_layout_invalid');
    }
  }
}
function validRelativeTransferPath(value: string, maxDepth: number = 32, maxBytes: number = 1024): boolean {
  if (typeof value !== 'string' || value.length === 0 || new util.TextEncoder().encode(value).byteLength > maxBytes) { return false; }
  const parts: string[] = value.split('/');
  if (parts.length > maxDepth) { return false; }
  return parts.every((part: string): boolean => part.length > 0 && part !== '.' && part !== '..' &&
    !/[\\:\*?"<>|\x00-\x1f\x7f]/.test(part) && !/[. ]$/.test(part) &&
    new util.TextEncoder().encode(part).byteLength <= 255);
}
function checkedTransferPath(root: string, relativePath: string, directory: boolean): string {
  if (!validRelativeTransferPath(relativePath, 36, 1200)) { throw new Error('transfer_relative_path_invalid'); }
  assertDirectory(root); const parts: string[] = relativePath.split('/'); let path: string = root;
  for (let i: number = 0; i < parts.length; i++) {
    path += '/' + parts[i]; const info: fileIo.Stat = fileIo.lstatSync(path);
    if (info.isSymbolicLink() || ((i < parts.length - 1 || directory) ? !info.isDirectory() : !info.isFile())) {
      throw new Error('transfer_relative_path_invalid');
    }
  }
  return path;
}

async function hashFile(path: string, expectedSize: number, guard: () => boolean): Promise<string> {
  checkCurrent(guard);
  const info: fileIo.Stat = fileIo.lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size !== expectedSize) { throw new Error('transfer_artifact_changed'); }
  const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    const before: fileIo.Stat = await fileIo.stat(file.fd);
    const digest = cryptoFramework.createMd('SHA256');
    let readBytes: number = 0;
    while (readBytes < expectedSize) {
      checkCurrent(guard);
      const buffer: ArrayBuffer = new ArrayBuffer(Math.min(TRANSFER_COPY_BLOCK_BYTES, expectedSize - readBytes));
      const count: number = await fileIo.read(file.fd, buffer);
      if (count <= 0 || count > buffer.byteLength) { throw new Error('transfer_artifact_changed'); }
      await digest.update({ data: new Uint8Array(buffer, 0, count) }); readBytes += count;
    }
    const after: fileIo.Stat = await fileIo.stat(file.fd);
    if (after.size !== expectedSize || before.ino !== after.ino || before.mtime !== after.mtime || before.ctime !== after.ctime) {
      throw new Error('transfer_artifact_changed');
    }
    checkCurrent(guard); return digestHex((await digest.digest()).data);
  } finally { await fileIo.close(file); }
}

function localTreeSourcePath(uri: string): string {
  const path: string = uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri;
  if (!path.startsWith('/') || path.indexOf('\0') >= 0 || path.indexOf('\\') >= 0 ||
    path.split('/').slice(1).some((part: string): boolean => part.length === 0 || part === '.' || part === '..')) {
    throw new Error('transfer_local_tree_uri_invalid');
  }
  return path;
}
function localTreePlan(sources: TransferLocalTreeSource[]): LocalTreePlan {
  if (sources.length === 0 || sources.length > 1024) { throw new Error('transfer_local_tree_item_limit'); }
  const copies: TransferLocalTreeSource[] = [];
  const names: Map<string, TransferLocalTreeSource> = new Map<string, TransferLocalTreeSource>();
  let root: TransferLocalTreeSource | null = null; let totalBytes: number = 0;
  for (const source of sources) {
    if (!validRelativeTransferPath(source.relativePath) || typeof source.uri !== 'string' || source.uri.length === 0 ||
      typeof source.directory !== 'boolean' || !validCount(source.size) || !Number.isFinite(source.mtime) || source.mtime < 0 ||
      (source.directory && source.size !== 0)) { throw new Error('transfer_local_tree_invalid'); }
    const normalized: string = artifactNameKey(source.relativePath);
    if (names.has(normalized)) { throw new Error('transfer_local_tree_name_collision'); }
    const copy: TransferLocalTreeSource = { uri: source.uri, relativePath: source.relativePath,
      directory: source.directory, size: source.size, mtime: source.mtime };
    names.set(normalized, copy); copies.push(copy);
    if (copy.relativePath.indexOf('/') < 0) {
      if (root !== null || !copy.directory) { throw new Error('transfer_local_tree_root_invalid'); }
      root = copy;
    }
    totalBytes += copy.size;
    if (totalBytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_local_tree_byte_limit'); }
  }
  if (root === null) { throw new Error('transfer_local_tree_root_invalid'); }
  const rootName: string = root.relativePath; const rootPath: string = localTreeSourcePath(root.uri);
  for (const copy of copies) {
    const parts: string[] = copy.relativePath.split('/');
    if (parts[0] !== rootName || localTreeSourcePath(copy.uri) !== rootPath +
      (parts.length > 1 ? '/' + parts.slice(1).join('/') : '')) { throw new Error('transfer_local_tree_source_outside_root'); }
    for (let index: number = 1; index < parts.length; index++) {
      const parent: string = parts.slice(0, index).join('/');
      const declared: TransferLocalTreeSource | undefined = names.get(artifactNameKey(parent));
      if (declared === undefined || !declared.directory || declared.relativePath !== parent) {
        throw new Error('transfer_local_tree_parent_invalid');
      }
    }
  }
  copies.sort((left: TransferLocalTreeSource, right: TransferLocalTreeSource): number => {
    if (left.directory !== right.directory) { return left.directory ? -1 : 1; }
    return left.relativePath.split('/').length - right.relativePath.split('/').length;
  });
  return { sources: copies, rootPath, rootName, totalBytes };
}
function sameLocalTreeIdentity(left: fileIo.Stat, right: fileIo.Stat): boolean {
  return left.ino === right.ino && left.size === right.size && left.mtime === right.mtime && left.ctime === right.ctime;
}
function assertLocalTreeIdentities(identities: LocalTreeSourceIdentity[]): void {
  for (const identity of identities) {
    const currentInfo: fileIo.Stat = fileIo.lstatSync(identity.path);
    if (currentInfo.isSymbolicLink() || !sameLocalTreeIdentity(identity.stat, currentInfo) ||
      (identity.source.directory ? !currentInfo.isDirectory() : !currentInfo.isFile())) {
      throw new Error('transfer_local_tree_source_changed');
    }
  }
}
function assertLocalTreeListing(plan: LocalTreePlan): void {
  const allowed: string[] = plan.sources.map((source: TransferLocalTreeSource): string => source.relativePath);
  validateNativeTreeListing(plan.rootPath, '', allowed.map((relative: string): string =>
    relative === plan.rootName ? '' : relative.substring(plan.rootName.length + 1)));
}

/** One private batch; creator hold is released explicitly when handoff is complete. */
export class TransferArtifactBatch {
  readonly directory: string;
  readonly id: string;
  private filesDir: string;
  private manifest: ArtifactManifest;
  private staging: boolean = false;
  private cleaning: boolean = false;
  private restored: boolean = false;
  private reservedForBatch: number = 0;
  private mutationFile: fileIo.File | null = null;
  private localHolders: Set<string> = new Set<string>();
  private localPublications: Set<string> = new Set<string>();
  private locallyPublished: boolean = false;
  private static reservedBytes: number = 0;
  private static batches: Map<string, TransferArtifactBatch> = new Map<string, TransferArtifactBatch>();

  constructor(filesDir: string, scopeKey: string, purpose: ArtifactPurpose = 'clipboard', restored?: ArtifactManifest) {
    this.filesDir = filesDir;
    if (restored !== undefined) {
      this.restored = true;
      this.id = restored.id;
      this.directory = validateBatchPath(filesDir, scopeKey, purpose, this.id);
      this.manifest = readManifest(filesDir, scopeKey, purpose, this.id);
    } else {
      const root: string = ensureTransferScopeDirectory(filesDir, scopeKey, purpose);
      this.id = util.generateRandomUUID(false);
      if (!validId(this.id)) { throw new Error('transfer_identifier_invalid'); }
      this.directory = root + '/batch-' + this.id;
      fileIo.mkdirSync(this.directory);
      this.manifest = { schemaVersion: 2, id: this.id, scopeKey, purpose, createdAt: Date.now(),
        updatedAt: Date.now(), published: false, holders: ['creator'], artifacts: [], nativeDirectories: [],
        platformDirectories: [], publications: [], untrackedPublished: false };
      this.localHolders.add('creator');
      try { this.acquireMutationLock(false); this.saveManifest(); } catch (_error) { this.closeMutationLock(); throw new Error('transfer_manifest_create_failed'); }
    }
    TransferArtifactBatch.batches.set(this.directory, this);
  }

  static recover(filesDir: string, scopeKey: string, purpose: ArtifactPurpose, batchId: string): TransferArtifactBatch | null {
    try {
      const directory: string = validateBatchPath(filesDir, scopeKey, purpose, batchId);
      const manifest: ArtifactManifest = readManifest(filesDir, scopeKey, purpose, batchId);
      const active: TransferArtifactBatch | undefined = TransferArtifactBatch.batches.get(directory);
      return active ?? new TransferArtifactBatch(filesDir, scopeKey, purpose, manifest);
    } catch (_error) { return null; }
  }

  retain(ownerId: string = 'creator'): void {
    if (this.cleaning || !/^[a-zA-Z0-9_.:@-]{1,128}$/.test(ownerId)) { throw new Error('transfer_holder_invalid'); }
    this.acquireMutationLock();
    if (this.manifest.holders.indexOf(ownerId) >= 0) {
      if (!this.localHolders.has(ownerId)) { this.releaseMutationIfIdle(); throw new Error('transfer_holder_owner_unknown'); }
      return;
    }
    if (this.manifest.holders.length >= 64) { throw new Error('transfer_holders_full'); }
    this.manifest.holders.push(ownerId); this.localHolders.add(ownerId); this.saveManifest();
  }
  release(ownerId: string = 'creator'): void {
    this.acquireMutationLock();
    if (this.manifest.holders.indexOf(ownerId) >= 0 && !this.localHolders.has(ownerId)) {
      this.releaseMutationIfIdle(); throw new Error('transfer_holder_owner_unknown'); }
    this.manifest.holders = this.manifest.holders.filter((holder: string): boolean => holder !== ownerId);
    this.saveManifest(); this.localHolders.delete(ownerId); this.releaseMutationIfIdle();
  }
  setPublished(published: boolean): void {
    if (this.cleaning && published) { throw new Error('transfer_cleanup_in_progress'); }
    this.acquireMutationLock();
    if (!published && this.manifest.untrackedPublished && !this.locallyPublished) {
      this.releaseMutationIfIdle(); throw new Error('transfer_publication_owner_unknown'); }
    this.manifest.untrackedPublished = published;
    this.manifest.published = published || this.manifest.publications.length > 0;
    this.saveManifest(); this.locallyPublished = published; this.releaseMutationIfIdle(); }
  retainPublication(id: string, kind: 'native' | 'system'): void {
    if (!validId(id) || this.cleaning) { throw new Error('transfer_publication_invalid'); }
    this.acquireMutationLock();
    if (this.manifest.publications.some((item: ArtifactPublicationManifest): boolean => item.id === id)) {
      if (!this.localPublications.has(id)) { throw new Error('transfer_publication_owner_unknown'); }
      return;
    }
    if (this.manifest.publications.length >= 64 || this.manifest.holders.length >= 64) { throw new Error('transfer_publications_full'); }
    const previous: ArtifactPublicationManifest[] = this.manifest.publications;
    const holders: string[] = this.manifest.holders; const published: boolean = this.manifest.published;
    const holder: string = 'publication:' + id;
    const publication: ArtifactPublicationManifest = { id, kind };
    this.manifest.publications = previous.concat([publication]);
    this.manifest.holders = holders.concat([holder]); this.manifest.published = true;
    try { this.saveManifest(); this.localPublications.add(id); this.localHolders.add(holder); }
    catch (_error) { this.manifest.publications = previous; this.manifest.holders = holders;
      this.manifest.published = published; throw new Error('transfer_publication_persist_failed'); }
  }
  releasePublication(id: string): boolean {
    if (!this.localPublications.has(id)) { return false; }
    this.acquireMutationLock();
    const previous: ArtifactPublicationManifest[] = this.manifest.publications;
    const holders: string[] = this.manifest.holders; const published: boolean = this.manifest.published;
    this.manifest.publications = previous.filter((item: ArtifactPublicationManifest): boolean => item.id !== id);
    this.manifest.holders = holders.filter((holder: string): boolean => holder !== 'publication:' + id);
    this.manifest.published = this.manifest.untrackedPublished || this.manifest.publications.length > 0;
    try { this.saveManifest(); this.localPublications.delete(id); this.localHolders.delete('publication:' + id);
      this.releaseMutationIfIdle(); return true; }
    catch (_error) { this.manifest.publications = previous; this.manifest.holders = holders;
      this.manifest.published = published; return false; }
  }
  getInfo(): TransferArtifactBatchInfo {
    if (this.mutationFile === null) { this.manifest = readManifest(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id); }
    const unknownHolder: boolean = this.manifest.holders.some((holder: string): boolean => !this.localHolders.has(holder));
    const unknownPublication: boolean = (this.manifest.untrackedPublished && !this.locallyPublished) || this.manifest.publications.some(
      (item: ArtifactPublicationManifest): boolean => !this.localPublications.has(item.id));
    const nativePending: boolean = this.manifest.nativeDirectories.some((item: NativeDirectoryManifest): boolean =>
      item.state === 'retained' || (item.state === 'active' && !this.staging));
    const platformPending: boolean = this.manifest.platformDirectories.some((item: NativeDirectoryManifest): boolean =>
      item.state === 'retained' || (item.state === 'active' && !this.staging));
    const held: boolean = this.manifest.holders.length > 0;
    const active: boolean = this.staging || this.cleaning || this.localHolders.size > 0;
    const unknown: boolean = unknownHolder || unknownPublication || nativePending || platformPending;
    const reason: string = platformPending ? 'platform-writer-unknown' : nativePending ? 'native-writer-unknown' :
      unknownPublication ? 'publication-owner-unknown' : unknownHolder ? 'holder-owner-unknown' :
      this.manifest.publications.some((item: ArtifactPublicationManifest): boolean => item.kind === 'native') ? 'native-published' :
      this.manifest.publications.length > 0 ? 'system-published' : this.manifest.published ? 'untracked-publication' : active ? 'active-holder' : 'none';
    return { id: this.id, purpose: this.manifest.purpose as ArtifactPurpose, createdAt: this.manifest.createdAt,
      updatedAt: this.manifest.updatedAt, fileCount: this.manifest.artifacts.filter(
        (item: ArtifactManifestEntry): boolean => item.state === 'complete' && !item.directory).length,
      directoryCount: this.manifest.artifacts.filter((item: ArtifactManifestEntry): boolean => item.state === 'complete' && item.directory).length,
      bytes: this.manifest.artifacts.reduce((sum: number, item: ArtifactManifestEntry): number =>
        sum + (item.state === 'complete' && !item.directory ? item.size : 0), 0), held,
      published: this.manifest.published, unknown, active,
      canCleanup: !held && !this.manifest.published && !unknown && !active, retentionReason: reason };
  }
  getArtifacts(): TransferArtifact[] {
    this.assertPath();
    return this.manifest.artifacts.filter((item: ArtifactManifestEntry): boolean => item.state === 'complete')
      .map((item: ArtifactManifestEntry): TransferArtifact => {
        const path: string = this.writerPath(item, false);
        const info: fileIo.Stat = fileIo.lstatSync(path);
        if (info.isSymbolicLink() || (item.directory ? !info.isDirectory() : (!info.isFile() || info.size !== item.size))) { throw new Error('transfer_artifact_changed'); }
        return this.toArtifact(item);
      });
  }
  private acquireMutationLock(refresh: boolean = true): void {
    if (this.mutationFile !== null) { return; }
    this.assertPath();
    const file: fileIo.File = fileIo.openSync(this.directory + '/lease.lock',
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    try {
      const info: fileIo.Stat = fileIo.statSync(file.fd);
      if (!info.isFile() || info.size !== 0) { throw new Error('transfer_lease_invalid'); }
      file.tryLock(true);
      if (refresh) { this.manifest = readManifest(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id); }
      this.mutationFile = file;
    } catch (_error) { fileIo.closeSync(file); throw new Error('transfer_lease_busy'); }
  }
  private closeMutationLock(): void {
    const file: fileIo.File | null = this.mutationFile; this.mutationFile = null;
    if (file !== null) { try { file.unlock(); } catch (_error) {} try { fileIo.closeSync(file); } catch (_error) {} }
  }
  private releaseMutationIfIdle(): void {
    if (!this.staging && !this.cleaning && this.localHolders.size === 0 &&
      this.localPublications.size === 0 && !this.locallyPublished) { this.closeMutationLock(); }
  }
  private assertPath(): void {
    validateBatchPath(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id);
  }
  private saveManifest(): void {
    this.assertPath(); this.manifest.updatedAt = Date.now();
    const path: string = this.directory + '/manifest.pending';
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.NOFOLLOW);
    try {
      const data: Uint8Array = new util.TextEncoder().encode(JSON.stringify(this.manifest));
      let written: number = 0;
      while (written < data.byteLength) {
        const count: number = fileIo.writeSync(file.fd, data.slice(written).buffer as ArrayBuffer);
        if (count <= 0 || count > data.byteLength - written) { throw new Error('transfer_manifest_write_failed'); }
        written += count;
      }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    this.assertPath();
    fileIo.renameSync(path, this.directory + '/manifest.json');
  }
  private reserveName(displayName: string, root: boolean = false): string {
    const name: string = safeTransferFileName(displayName);
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    let extension: string = dot > 0 ? name.substring(dot) : '';
    const encoder = new util.TextEncoder();
    while (encoder.encode(extension).byteLength > 64) {
      const last: number = extension.charCodeAt(extension.length - 1);
      extension = extension.substring(0, extension.length - (last >= 0xDC00 && last <= 0xDFFF ? 2 : 1));
    }
    let candidate: string = name;
    let suffix: number = 2;
    const names: string[] = this.manifest.artifacts.map((item: ArtifactManifestEntry): string => artifactNameKey(root ? item.relativePath.split('/')[0] : item.relativePath));
    while (names.indexOf(artifactNameKey(candidate)) >= 0) {
      const tail: string = ' (' + (suffix++).toString() + ')' + extension;
      let prefix: string = stem;
      while (encoder.encode(prefix + tail).byteLength > 180) {
        const last: number = prefix.charCodeAt(prefix.length - 1);
        prefix = prefix.substring(0, prefix.length - (last >= 0xDC00 && last <= 0xDFFF ? 2 : 1));
      }
      candidate = prefix + tail;
    }
    return candidate;
  }
  private startStaging(guard: () => boolean, tree: boolean = false): void {
    if (this.staging || this.cleaning || !current(guard) || this.manifest.artifacts.length >= (tree ? 1024 : TRANSFER_BATCH_LIMIT)) {
      throw new Error('transfer_batch_unavailable');
    }
    if (this.restored) { throw new Error('transfer_recovered_batch_read_only'); }
    this.acquireMutationLock(); this.assertPath(); this.staging = true;
  }
  private async reserve(bytes: number, guard: () => boolean): Promise<void> {
    if (!validCount(bytes) || bytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    this.assertPath();
    this.reserveAgainstFree(bytes, await statfs.getFreeSize(this.directory), guard);
  }
  private reserveAgainstFree(bytes: number, free: number, guard: () => boolean): void {
    if (!validCount(bytes) || bytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    checkCurrent(guard);
    const completeBytes: number = this.manifest.artifacts.reduce((total: number, item: ArtifactManifestEntry): number =>
      total + (item.state === 'complete' && !item.directory ? item.size : 0), 0);
    if (completeBytes + this.reservedForBatch + bytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_batch_size_limit'); }
    if (!Number.isFinite(free) || free < bytes + TransferArtifactBatch.reservedBytes + TRANSFER_SPACE_RESERVE ||
      managedArtifactBytes(this.filesDir) + TransferArtifactBatch.reservedBytes + bytes > TRANSFER_CACHE_QUOTA_BYTES) {
      throw new Error('transfer_space_limit');
    }
    TransferArtifactBatch.reservedBytes += bytes; this.reservedForBatch += bytes;
  }
  private async openWriter(displayName: string, size: number, guard: () => boolean, nativeMode: boolean = false,
    logicalPath: string = ''): Promise<TransferReceivedArtifactWriter> {
    if ((!validCount(size) && size !== -1) || size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    if (logicalPath.length > 0) { this.assertLogicalPath(logicalPath, false); }
    const reserved: number = Math.max(0, size);
    await this.reserve(reserved, guard);
    const id: string = util.generateRandomUUID(false);
    if (!validId(id)) { TransferArtifactBatch.reservedBytes -= reserved; this.reservedForBatch -= reserved; throw new Error('transfer_identifier_invalid'); }
    const entry: ArtifactManifestEntry = { id, name: logicalPath.length > 0 ? safeTransferFileName(displayName) : this.reserveName(displayName), size: Math.max(0, size),
      mtime: 0, sha256: '', state: 'partial', storageRelativePath: '', relativePath: '', directory: false };
    entry.relativePath = logicalPath.length > 0 ? logicalPath : entry.name;
    const directory: string = this.directory + '/' + id;
    let ownsDirectory: boolean = false;
    let file: fileIo.File | null = null;
    try {
      this.assertPath(); fileIo.mkdirSync(directory); ownsDirectory = true;
      this.manifest.artifacts.push(entry); this.saveManifest();
      checkCurrent(guard);
      file = await fileIo.open(directory + '/' + partialName(entry.name),
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      return new TransferReceivedArtifactWriter(this, entry, file, size, reserved, guard, nativeMode);
    } catch (error) {
      if (file !== null) { try { await fileIo.close(file); } catch (_closeError) {} }
      if (ownsDirectory) {
        try { assertDirectory(directory); await fileIo.unlink(directory + '/' + partialName(entry.name)); } catch (_unlinkError) {}
      }
      // The platform rmdir APIs are recursive. Keep this attempt's recorded partial
      // entry so its owned empty directory remains valid for later manifest recovery/TTL.
      if (!ownsDirectory) {
        this.manifest.artifacts = this.manifest.artifacts.filter((item: ArtifactManifestEntry): boolean => item.id !== id);
      }
      try { this.saveManifest(); } catch (_manifestError) { /* The next successful save keeps the ownership entry. */ }
      TransferArtifactBatch.reservedBytes -= reserved; this.reservedForBatch -= reserved;
      throw new Error('transfer_artifact_operation_failed');
    }
  }

  async beginReceive(displayName: string, size: number, isCurrent: () => boolean): Promise<TransferReceivedArtifactWriter> {
    this.startStaging(isCurrent);
    try { return await this.openWriter(displayName, size, isCurrent); }
    catch (error) { this.staging = false; throw new Error('transfer_artifact_operation_failed'); }
  }

  async beginNativeReceive(displayName: string, size: number, isCurrent: () => boolean): Promise<TransferReceivedArtifactWriter> {
    if (!validCount(size) || size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    this.startStaging(isCurrent);
    try { return await this.openWriter(displayName, size, isCurrent, true); }
    catch (error) { this.staging = false; throw new Error('transfer_artifact_operation_failed'); }
  }

  private assertLogicalPath(relativePath: string, directory: boolean): void {
    if (!validRelativeTransferPath(relativePath)) { throw new Error('transfer_logical_path_invalid'); }
    const key: string = artifactNameKey(relativePath);
    for (const item of this.manifest.artifacts) {
      const existing: string = artifactNameKey(item.relativePath);
      if (key === existing || (!item.directory && key.startsWith(existing + '/')) ||
        (!directory && existing.startsWith(key + '/'))) { throw new Error('transfer_logical_path_collision'); }
    }
  }
  async createDirectoryRoot(displayName: string, isCurrent: () => boolean): Promise<TransferArtifact> {
    return await this.createDirectory(this.reserveName(displayName, true), isCurrent);
  }
  async createDirectory(relativePath: string, isCurrent: () => boolean): Promise<TransferArtifact> {
    this.startStaging(isCurrent, true);
    let reserved: boolean = false;
    try {
      const existing: ArtifactManifestEntry | undefined = this.manifest.artifacts.find((item: ArtifactManifestEntry): boolean =>
        item.directory && item.state === 'complete' && artifactNameKey(item.relativePath) === artifactNameKey(relativePath));
      if (existing !== undefined) { this.writerPath(existing, false); return this.toArtifact(existing); }
      this.assertLogicalPath(relativePath, true); await this.reserve(0, isCurrent); reserved = true; checkCurrent(isCurrent);
      const id: string = util.generateRandomUUID(false);
      if (!validId(id)) { throw new Error('transfer_identifier_invalid'); }
      const name: string = safeTransferFileName(relativePath.split('/').pop() || 'folder');
      const entry: ArtifactManifestEntry = { id, name, size: 0, mtime: Date.now() / 1000, sha256: '',
        state: 'partial', storageRelativePath: '', relativePath, directory: true };
      const directory: string = this.directory + '/' + id; fileIo.mkdirSync(directory);
      this.manifest.artifacts.push(entry); this.saveManifest();
      fileIo.mkdirSync(directory + '/' + name); checkCurrent(isCurrent);
      entry.state = 'complete'; this.saveManifest(); return this.toArtifact(entry);
    } finally { if (reserved) { this.finishWriter(0); } else { this.staging = false; this.releaseMutationIfIdle(); } }
  }
  async stageRelative(uri: string, relativePath: string, expectedSize: number,
    isCurrent: () => boolean, progress: (copied: number, total: number) => void): Promise<TransferArtifact> {
    return await this.stage(uri, safeTransferFileName(relativePath.split('/').pop() || 'file'),
      expectedSize, isCurrent, progress, relativePath);
  }
  async beginNativeReceiveRelative(relativePath: string, size: number,
    isCurrent: () => boolean): Promise<TransferReceivedArtifactWriter> {
    if (!validCount(size) || size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    this.startStaging(isCurrent, true);
    try { return await this.openWriter(relativePath.split('/').pop() || 'file', size, isCurrent, true, relativePath); }
    catch (_error) { this.staging = false; this.releaseMutationIfIdle(); throw new Error('transfer_artifact_operation_failed'); }
  }
  async beginReceiveRelative(relativePath: string, size: number,
    isCurrent: () => boolean): Promise<TransferReceivedArtifactWriter> {
    this.startStaging(isCurrent, true);
    try { return await this.openWriter(relativePath.split('/').pop() || 'file', size, isCurrent, false, relativePath); }
    catch (_error) { this.staging = false; this.releaseMutationIfIdle(); throw new Error('transfer_artifact_operation_failed'); }
  }

  /** Stage one authorized local folder directly into a publishable physical tree.
   * The existing owned native-directory container supplies durable ownership/TTL
   * semantics; no native or platform receiver is invoked and no payload is recopied.
   */
  async stageLocalDirectoryTree(sources: TransferLocalTreeSource[], isCurrent: () => boolean,
    progress: (copied: number, total: number) => void): Promise<TransferArtifact[]> {
    checkCurrent(isCurrent); const plan: LocalTreePlan = localTreePlan(sources);
    this.startStaging(isCurrent, true);
    let reserved: boolean = false; let owner: NativeDirectoryManifest | null = null;
    const additions: ArtifactManifestEntry[] = []; const identities: LocalTreeSourceIdentity[] = [];
    const id: string = util.generateRandomUUID(false); const holder: string = 'local-tree:' + id;
    let copied: number = 0; let reportedAt: number = 0;
    try {
      if (!validId(id) || this.manifest.nativeDirectories.length >= 15 ||
        this.manifest.artifacts.length + plan.sources.length > 1024) { throw new Error('transfer_local_tree_item_limit'); }
      for (const source of plan.sources) { this.assertLogicalPath(source.relativePath, source.directory); }
      await this.reserve(plan.totalBytes, isCurrent); reserved = true; checkCurrent(isCurrent);
      for (const source of plan.sources) {
        checkCurrent(isCurrent); const path: string = localTreeSourcePath(source.uri);
        const info: fileIo.Stat = fileIo.lstatSync(path);
        if (info.isSymbolicLink() || (source.directory ? !info.isDirectory() : !info.isFile()) ||
          (!source.directory && info.size !== source.size) || info.mtime !== source.mtime) {
          throw new Error('transfer_local_tree_source_changed');
        }
        identities.push({ source, path, stat: info });
      }
      assertLocalTreeListing(plan); checkCurrent(isCurrent);
      const ownedRoot: string = this.directory + '/native-' + id;
      this.assertPath(); fileIo.mkdirSync(ownedRoot);
      owner = { id, state: 'active', layout: 'localTree' }; this.manifest.nativeDirectories.push(owner); this.retain(holder);
      for (const identity of identities) {
        checkCurrent(isCurrent); const source: TransferLocalTreeSource = identity.source;
        const parents: LocalTreeSourceIdentity[] = identities.filter((item: LocalTreeSourceIdentity): boolean =>
          item.source.directory && (source.relativePath === item.source.relativePath ||
            source.relativePath.startsWith(item.source.relativePath + '/')));
        assertLocalTreeIdentities(parents);
        const entry: ArtifactManifestEntry = { id: util.generateRandomUUID(false), name: source.relativePath.split('/').pop() || '',
          size: source.size, mtime: source.mtime, sha256: '', state: 'partial',
          storageRelativePath: 'native-' + id + '/' + source.relativePath, relativePath: source.relativePath, directory: source.directory };
        if (!validId(entry.id)) { throw new Error('transfer_identifier_invalid'); }
        const target: string = ownedRoot + '/' + source.relativePath;
        const slash: number = source.relativePath.lastIndexOf('/');
        if (slash >= 0) { checkedTransferPath(ownedRoot, source.relativePath.substring(0, slash), true); }
        else { assertDirectory(ownedRoot); }
        if (source.directory) {
          fileIo.mkdirSync(target); additions.push(entry); this.manifest.artifacts.push(entry); this.saveManifest(); continue;
        }
        let input: fileIo.File | null = null; let output: fileIo.File | null = null;
        try {
          checkCurrent(isCurrent); input = await fileIo.open(source.uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
          checkCurrent(isCurrent); const inputFd: number = input.fd;
          const before: fileIo.Stat = await fileIo.stat(inputFd); checkCurrent(isCurrent);
          if (!before.isFile() || !sameLocalTreeIdentity(identity.stat, before)) { throw new Error('transfer_local_tree_source_changed'); }
          assertLocalTreeIdentities(parents);
          // This file is under a new, private UUID root. Record it immediately
          // after synchronous creation, before any asynchronous payload write.
          output = fileIo.openSync(target, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
          additions.push(entry); this.manifest.artifacts.push(entry); this.saveManifest();
          const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
          let fileBytes: number = 0;
          while (fileBytes < source.size) {
            checkCurrent(isCurrent);
            const block: ArrayBuffer = new ArrayBuffer(Math.min(TRANSFER_COPY_BLOCK_BYTES, source.size - fileBytes));
            const read: number = await fileIo.read(inputFd, block); checkCurrent(isCurrent);
            if (read <= 0 || read > block.byteLength) { throw new Error('transfer_source_short_read'); }
            let written: number = 0;
            while (written < read) {
              checkCurrent(isCurrent);
              const count: number = await fileIo.write(output.fd, block.slice(written, read)); checkCurrent(isCurrent);
              if (count <= 0 || count > read - written) { throw new Error('transfer_short_write'); }
              written += count; fileBytes += count; copied += count;
            }
            checkCurrent(isCurrent); await digest.update({ data: new Uint8Array(block, 0, read) }); checkCurrent(isCurrent);
            if (Date.now() - reportedAt >= 250 && copied < plan.totalBytes) {
              reportedAt = Date.now(); safeProgress(progress, copied, plan.totalBytes);
            }
          }
          checkCurrent(isCurrent); const after: fileIo.Stat = await fileIo.stat(inputFd); checkCurrent(isCurrent);
          if (!sameLocalTreeIdentity(before, after)) { throw new Error('transfer_local_tree_source_changed'); }
          checkCurrent(isCurrent); await fileIo.fsync(output.fd); checkCurrent(isCurrent);
          fileIo.closeSync(output); output = null;
          checkCurrent(isCurrent); const value: cryptoFramework.DataBlob = await digest.digest(); checkCurrent(isCurrent);
          entry.sha256 = digestHex(value.data);
          checkCurrent(isCurrent); const actual: string = await hashFile(target, source.size, isCurrent); checkCurrent(isCurrent);
          if (actual !== entry.sha256) { throw new Error('transfer_local_tree_hash_mismatch'); }
          assertLocalTreeIdentities(parents); this.saveManifest();
        } finally {
          if (input !== null) { try { fileIo.closeSync(input); } catch (_error) {} }
          if (output !== null) { try { fileIo.closeSync(output); } catch (_error) {} }
        }
      }
      checkCurrent(isCurrent); assertLocalTreeIdentities(identities); assertLocalTreeListing(plan);
      validateNativeTreeListing(ownedRoot, '', plan.sources.map((source: TransferLocalTreeSource): string => source.relativePath));
      if (copied !== plan.totalBytes) { throw new Error('transfer_local_tree_size_mismatch'); }
      checkCurrent(isCurrent);
      for (const entry of additions) { entry.state = 'complete'; }
      owner.state = 'complete'; this.release(holder);
      // Publishable paths become observable only after the entire tree and its
      // manifest are durable. Progress before this point never reports 100%.
      const result: TransferArtifact[] = additions.map((entry: ArtifactManifestEntry): TransferArtifact => this.toArtifact(entry));
      safeProgress(progress, copied, plan.totalBytes); return result;
    } catch (_error) {
      for (const entry of additions) { entry.state = 'partial'; }
      if (owner !== null) { owner.state = 'aborted'; }
      // All local I/O has drained at this point. Preserve each created object,
      // release only this writer's hold and allow ordinary owned TTL cleanup.
      try { this.release(holder); } catch (_saveError) { /* Failed persistence remains conservatively held on disk. */ }
      throw new Error('transfer_local_tree_stage_failed');
    } finally {
      if (reserved) { this.finishWriter(plan.totalBytes); } else { this.staging = false; this.releaseMutationIfIdle(); }
    }
  }

  async createNativeReceiveDirectory(isCurrent: () => boolean,
    expectedBytes: number = TRANSFER_FILE_LIMIT_BYTES): Promise<TransferNativeReceiveDirectory> {
    this.startStaging(isCurrent); let reserved: boolean = false; let file: fileIo.File | null = null;
    const id: string = util.generateRandomUUID(false);
    try {
      if (this.manifest.purpose !== 'received' || this.manifest.nativeDirectories.length >= 15 || !validId(id)) { throw new Error('transfer_receive_scope_invalid'); }
      await this.reserve(expectedBytes, isCurrent); reserved = true;
      const path: string = this.directory + '/native-' + id; fileIo.mkdirSync(path);
      this.manifest.nativeDirectories.push({ id, state: 'active', layout: 'rdpReceive' }); this.retain('native-directory:' + id);
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR | fileIo.OpenMode.NOFOLLOW);
      checkCurrent(isCurrent); return new TransferNativeReceiveDirectory(this, id, file, expectedBytes, isCurrent);
    } catch (_error) {
      if (file !== null) { try { await fileIo.close(file); } catch (_closeError) {} }
      if (reserved) { this.finishWriter(expectedBytes); } else { this.staging = false; }
      throw new Error('transfer_directory_receive_failed');
    }
  }
  nativeDirectoryPath(id: string): string {
    this.assertPath();
    if (!this.manifest.nativeDirectories.some((item: NativeDirectoryManifest): boolean => item.id === id)) {
      throw new Error('transfer_native_directory_unowned');
    }
    const path: string = this.directory + '/native-' + id; assertDirectory(path); return path;
  }
  retainNativeDirectory(id: string): void {
    const entry: NativeDirectoryManifest | undefined = this.manifest.nativeDirectories.find(
      (item: NativeDirectoryManifest): boolean => item.id === id);
    if (entry === undefined) { throw new Error('transfer_native_directory_unowned'); }
    entry.state = 'retained'; this.retain('native-unknown:' + id); this.saveManifest();
  }
  finishNativeDirectory(id: string, state: 'complete' | 'aborted', reservedBytes: number): void {
    const entry: NativeDirectoryManifest | undefined = this.manifest.nativeDirectories.find(
      (item: NativeDirectoryManifest): boolean => item.id === id);
    if (entry === undefined) { throw new Error('transfer_native_directory_unowned'); }
    entry.state = state; this.release('native-directory:' + id); this.finishWriter(reservedBytes);
  }
  async importReceivedTree(id: string, expectedEntries: TransferNativeReceivedEntry[], reservedBytes: number,
    isCurrent: () => boolean): Promise<TransferArtifact[]> {
    const root: string = this.nativeDirectoryPath(id);
    if (expectedEntries.length === 0 || expectedEntries.length + this.manifest.artifacts.length > 1024) {
      throw new Error('transfer_received_tree_invalid');
    }
    const expected: string[] = []; const normalizedNames: string[] = this.manifest.artifacts.map(
      (item: ArtifactManifestEntry): string => artifactNameKey(item.relativePath));
    const indices: number[] = []; let total: number = 0; let receiveRoot: string = '';
    for (let i: number = 0; i < expectedEntries.length; i++) {
      const item: TransferNativeReceivedEntry = expectedEntries[i];
      if (!validRelativeTransferPath(item.relativeName, 34, 1100) || !validCount(item.index) ||
        indices.indexOf(item.index) >= 0 || !validCount(item.size) || item.size > TRANSFER_FILE_LIMIT_BYTES ||
        typeof item.directory !== 'boolean' || (item.directory && item.size !== 0)) { throw new Error('transfer_received_tree_invalid'); }
      const parts: string[] = item.relativeName.split('/');
      if (parts.length < 3 || !/^receive-[0-9]+$/.test(parts[0]) || parts[1] !== 'files' ||
        (receiveRoot.length > 0 && receiveRoot !== parts[0])) { throw new Error('transfer_received_tree_invalid'); }
      const normalized: string = artifactNameKey(parts.slice(2).join('/'));
      if (normalizedNames.indexOf(normalized) >= 0) { throw new Error('transfer_received_tree_name_collision'); }
      normalizedNames.push(normalized); receiveRoot = parts[0]; indices.push(item.index); total += item.size;
      if (expected.indexOf(item.relativeName) >= 0 || total > reservedBytes) { throw new Error('transfer_received_tree_invalid'); }
      expected.push(item.relativeName); checkedTransferPath(root, item.relativeName, item.directory);
    }
    const allowed: string[] = [receiveRoot, receiveRoot + '/files', receiveRoot + '/partial'];
    for (let i: number = 0; i < expected.length; i++) {
      const parts: string[] = expected[i].split('/'); let parent: string = '';
      for (let j: number = 0; j < parts.length; j++) {
        parent = parent.length === 0 ? parts[j] : parent + '/' + parts[j];
        if (allowed.indexOf(parent) < 0) { allowed.push(parent); }
      }
    }
    validateNativeTreeListing(root, '', allowed, true);
    const additions: ArtifactManifestEntry[] = [];
    for (let i: number = 0; i < expectedEntries.length; i++) {
      checkCurrent(isCurrent); const item: TransferNativeReceivedEntry = expectedEntries[i];
      const path: string = checkedTransferPath(root, item.relativeName, item.directory);
      const relativePath: string = item.relativeName.split('/').slice(2).join('/');
      const parts: string[] = relativePath.split('/'); const info: fileIo.Stat = fileIo.lstatSync(path);
      if (!item.directory && info.size !== item.size) { throw new Error('transfer_received_tree_size_mismatch'); }
      const sha256: string = item.directory ? '' : await hashFile(path, item.size, isCurrent);
      additions.push({ id: util.generateRandomUUID(false), name: parts[parts.length - 1], size: item.size,
        mtime: info.mtime, sha256, state: 'complete', storageRelativePath: 'native-' + id + '/' + item.relativeName,
        relativePath, directory: item.directory });
    }
    checkCurrent(isCurrent); const previous: ArtifactManifestEntry[] = this.manifest.artifacts;
    this.manifest.artifacts = previous.concat(additions);
    try { this.saveManifest(); } catch (_error) { this.manifest.artifacts = previous; throw new Error('transfer_manifest_write_failed'); }
    return additions.map((entry: ArtifactManifestEntry): TransferArtifact => this.toArtifact(entry));
  }

  async createPlatformIncoming(isCurrent: () => boolean,
    expectedBytes: number = TRANSFER_FILE_LIMIT_BYTES): Promise<TransferPlatformIncomingDirectory> {
    return this.createPlatformIncomingSync(isCurrent, expectedBytes);
  }
  /** Must run before returning from onDrop so startDataLoading stays in its valid phase. */
  createPlatformIncomingSync(isCurrent: () => boolean,
    expectedBytes: number = TRANSFER_FILE_LIMIT_BYTES): TransferPlatformIncomingDirectory {
    this.startStaging(isCurrent, true); let reserved: boolean = false; const id: string = util.generateRandomUUID(false);
    try {
      if (!validId(id) || this.manifest.platformDirectories.length >= 15) { throw new Error('transfer_incoming_limit'); }
      this.reserveAgainstFree(expectedBytes, statfs.getFreeSizeSync(this.directory), isCurrent); reserved = true; checkCurrent(isCurrent);
      fileIo.mkdirSync(this.directory + '/incoming-' + id);
      this.manifest.platformDirectories.push({ id, state: 'active' }); this.retain('platform-directory:' + id);
      return new TransferPlatformIncomingDirectory(this, id, expectedBytes);
    } catch (_error) {
      const entry: NativeDirectoryManifest | undefined = this.manifest.platformDirectories.find(
        (item: NativeDirectoryManifest): boolean => item.id === id);
      if (entry !== undefined) { entry.state = 'aborted'; try { this.release('platform-directory:' + id); } catch (_saveError) {} }
      if (reserved) { this.finishWriter(expectedBytes); } else { this.staging = false; this.releaseMutationIfIdle(); }
      throw new Error('transfer_incoming_create_failed');
    }
  }
  platformDirectoryPath(id: string): string {
    this.assertPath();
    if (!this.manifest.platformDirectories.some((item: NativeDirectoryManifest): boolean => item.id === id)) {
      throw new Error('transfer_incoming_unowned');
    }
    const path: string = this.directory + '/incoming-' + id; assertDirectory(path); return path;
  }
  retainPlatformDirectory(id: string): void {
    const entry: NativeDirectoryManifest | undefined = this.manifest.platformDirectories.find(
      (item: NativeDirectoryManifest): boolean => item.id === id);
    if (entry === undefined) { throw new Error('transfer_incoming_unowned'); }
    entry.state = 'retained'; this.retain('platform-unknown:' + id); this.saveManifest();
  }
  finishPlatformDirectory(id: string, reservedBytes: number): void {
    const entry: NativeDirectoryManifest | undefined = this.manifest.platformDirectories.find(
      (item: NativeDirectoryManifest): boolean => item.id === id);
    if (entry === undefined) { throw new Error('transfer_incoming_unowned'); }
    entry.state = 'complete';
    this.release('platform-unknown:' + id); this.release('platform-directory:' + id); this.finishWriter(reservedBytes);
  }
  async importPlatformIncoming(id: string, uris: string[], reservedBytes: number): Promise<TransferArtifact[]> {
    const root: string = this.platformDirectoryPath(id);
    if (uris.length === 0 || uris.length > 1024) { throw new Error('transfer_incoming_empty'); }
    const entries: ImportedArtifactEntry[] = []; const seen: string[] = []; const total: number[] = [0];
    for (const uri of uris) {
      if (typeof uri !== 'string' || !uri.startsWith('file://')) { throw new Error('transfer_incoming_uri_invalid'); }
      const path: string = new fileUri.FileUri(uri).path;
      if (!path.startsWith(root + '/')) { throw new Error('transfer_incoming_uri_unowned'); }
      const relative: string = path.substring(root.length + 1);
      collectPlatformEntries(root, relative, entries, seen, total, reservedBytes);
    }
    if (entries.length + this.manifest.artifacts.length > 1024) { throw new Error('transfer_incoming_limit'); }
    const allowed: string[] = [];
    for (const entry of entries) {
      const parts: string[] = entry.storageRelativePath.split('/'); let path: string = '';
      for (const part of parts) { path = path.length === 0 ? part : path + '/' + part;
        if (allowed.indexOf(path) < 0) { allowed.push(path); } }
    }
    validateNativeTreeListing(root, '', allowed);
    const names: string[] = this.manifest.artifacts.map((item: ArtifactManifestEntry): string => artifactNameKey(item.relativePath));
    const additions: ArtifactManifestEntry[] = [];
    for (const entry of entries) {
      const key: string = artifactNameKey(entry.relativePath);
      if (names.indexOf(key) >= 0) { throw new Error('transfer_incoming_name_collision'); } names.push(key);
      const path: string = checkedTransferPath(root, entry.storageRelativePath, entry.directory);
      const info: fileIo.Stat = fileIo.lstatSync(path);
      const digest: string = entry.directory ? '' : await hashFile(path, entry.size, (): boolean => true);
      additions.push({ id: util.generateRandomUUID(false), name: entry.relativePath.split('/').pop() || 'file',
        size: entry.size, mtime: info.mtime, sha256: digest, state: 'complete',
        storageRelativePath: 'incoming-' + id + '/' + entry.storageRelativePath,
        relativePath: entry.relativePath, directory: entry.directory });
    }
    validateNativeTreeListing(root, '', allowed);
    const previous: ArtifactManifestEntry[] = this.manifest.artifacts; this.manifest.artifacts = previous.concat(additions);
    try { this.saveManifest(); } catch (_error) { this.manifest.artifacts = previous; throw new Error('transfer_manifest_write_failed'); }
    return additions.map((entry: ArtifactManifestEntry): TransferArtifact => this.toArtifact(entry));
  }

  async stage(uri: string, displayName: string, expectedSize: number,
    isCurrent: () => boolean, progress: (copied: number, total: number) => void,
    logicalPath: string = ''): Promise<TransferArtifact> {
    if ((!validCount(expectedSize) && expectedSize !== -1) || expectedSize > TRANSFER_FILE_LIMIT_BYTES) {
      throw new Error('transfer_size_limit');
    }
    this.startStaging(isCurrent, logicalPath.length > 0);
    let input: fileIo.File | null = null;
    let writer: TransferReceivedArtifactWriter | null = null;
    try {
      input = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      const before: fileIo.Stat = await fileIo.stat(input.fd);
      checkCurrent(isCurrent);
      if (!before.isFile() || !validCount(before.size) || before.size > TRANSFER_FILE_LIMIT_BYTES ||
        (expectedSize !== -1 && before.size !== expectedSize)) { throw new Error('transfer_source_changed'); }
      const size: number = before.size;
      writer = await this.openWriter(displayName, size, isCurrent, false, logicalPath);
      let copied: number = 0;
      let reportedAt: number = 0;
      while (copied < size) {
        checkCurrent(isCurrent);
        const block: ArrayBuffer = new ArrayBuffer(Math.min(TRANSFER_COPY_BLOCK_BYTES, size - copied));
        const read: number = await fileIo.read(input.fd, block);
        if (read <= 0 || read > block.byteLength) { throw new Error('transfer_source_short_read'); }
        copied += await writer.write(block.slice(0, read));
        if (Date.now() - reportedAt >= 250) { reportedAt = Date.now(); safeProgress(progress, copied, size); }
      }
      const after: fileIo.Stat = await fileIo.stat(input.fd);
      checkCurrent(isCurrent);
      if (after.size !== before.size || after.mtime !== before.mtime || after.ctime !== before.ctime || after.ino !== before.ino) {
        throw new Error('transfer_source_changed');
      }
      const result: TransferArtifact = await writer.commit(before.mtime);
      safeProgress(progress, size, size); return result;
    } catch (error) {
      if (writer !== null) { await writer.abort(); }
      throw new Error('transfer_artifact_operation_failed');
    } finally {
      if (input !== null) { try { await fileIo.close(input); } catch (_closeError) {} }
      this.staging = false;
    }
  }

  /** Internal writer hooks operate only on this batch's recorded entry. */
  async reserveAdditional(bytes: number, guard: () => boolean): Promise<void> { await this.reserve(bytes, guard); }
  writerPath(entry: ArtifactManifestEntry, partial: boolean): string {
    this.assertPath();
    if (this.manifest.artifacts.indexOf(entry) < 0) { throw new Error('transfer_artifact_unowned'); }
    if (entry.storageRelativePath.length > 0) {
      if (partial) { throw new Error('transfer_native_tree_no_partial'); }
      return checkedTransferPath(this.directory, entry.storageRelativePath, entry.directory);
    }
    assertDirectory(this.directory + '/' + entry.id);
    return this.directory + '/' + entry.id + '/' + (partial ? partialName(entry.name) : entry.name);
  }
  async commitWriter(entry: ArtifactManifestEntry, bytes: number, sha256: string, mtime: number): Promise<TransferArtifact> {
    const partial: string = this.writerPath(entry, true);
    const path: string = this.writerPath(entry, false);
    try { fileIo.lstatSync(path); throw new Error('transfer_target_exists'); }
    catch (error) {
      const detail: ArtifactIoError = error as ArtifactIoError;
      if (detail.code !== 13900002 && detail.code !== 'ENOENT') { throw new Error('transfer_artifact_operation_failed'); }
    }
    await fileIo.rename(partial, path);
    entry.size = bytes; entry.sha256 = sha256; entry.mtime = mtime; entry.state = 'complete';
    try { this.saveManifest(); }
    catch (error) {
      // Rename belongs to this attempt; preserve no unrecorded success for callers.
      try { this.writerPath(entry, false); await fileIo.unlink(path); } catch (_unlinkError) {}
      entry.state = 'partial'; entry.sha256 = ''; throw new Error('transfer_artifact_operation_failed');
    }
    return this.toArtifact(entry);
  }
  async abortWriter(entry: ArtifactManifestEntry): Promise<void> {
    if (entry.state === 'complete') { return; }
    try { const partial: string = this.writerPath(entry, true); await fileIo.unlink(partial); }
    catch (_unlinkError) { /* Retain a recorded partial if deletion or validation fails. */ }
    try { this.saveManifest(); } catch (_manifestError) {}
  }
  finishWriter(reservedBytes: number): void {
    TransferArtifactBatch.reservedBytes = Math.max(0, TransferArtifactBatch.reservedBytes - reservedBytes);
    this.reservedForBatch = Math.max(0, this.reservedForBatch - reservedBytes);
    this.staging = false; this.releaseMutationIfIdle();
  }
  private toArtifact(entry: ArtifactManifestEntry): TransferArtifact {
    return { id: entry.id, name: entry.name, path: this.directory + '/' +
      (entry.storageRelativePath.length > 0 ? entry.storageRelativePath : entry.id + '/' + entry.name),
      size: entry.size, mtime: entry.mtime, sha256: entry.sha256, relativePath: entry.relativePath, directory: entry.directory };
  }
  static owner(artifact: TransferArtifact): TransferArtifactBatch | null {
    const values: TransferArtifactBatch[] = Array.from(TransferArtifactBatch.batches.values());
    for (let i: number = 0; i < values.length; i++) {
      const batch: TransferArtifactBatch = values[i];
      const entry: ArtifactManifestEntry | undefined = batch.manifest.artifacts.find(
        (item: ArtifactManifestEntry): boolean => item.id === artifact.id && item.state === 'complete');
      if (entry !== undefined && batch.toArtifact(entry).path === artifact.path && entry.name === artifact.name &&
        entry.size === artifact.size && entry.sha256 === artifact.sha256) { batch.writerPath(entry, false); return batch; }
    }
    return null;
  }
  async cleanupExpired(ttlMs: number): Promise<TransferArtifactCleanupResult> {
    if (this.cleaning) { return { removedFiles: 0, removedBytes: 0, retainedBatches: 1, invalidBatches: 0 }; }
    try { this.acquireMutationLock(); } catch (_error) { return { removedFiles: 0, removedBytes: 0, retainedBatches: 1, invalidBatches: 0 }; }
    this.cleaning = true;
    try { return await this.cleanupExpiredOwned(ttlMs); } finally { this.cleaning = false; this.releaseMutationIfIdle(); }
  }
  private async cleanupExpiredOwned(ttlMs: number): Promise<TransferArtifactCleanupResult> {
    const result: TransferArtifactCleanupResult = { removedFiles: 0, removedBytes: 0, retainedBatches: 0, invalidBatches: 0 };
    if (this.staging || this.manifest.published || this.manifest.holders.length > 0 ||
      Date.now() - this.manifest.updatedAt < ttlMs) { result.retainedBatches++; return result; }
    this.assertPath();
    // Re-read the on-disk ownership evidence before any deletion, including active instances.
    const disk: ArtifactManifest = readManifest(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id);
    if (disk.published || disk.holders.length > 0 || JSON.stringify(disk.artifacts) !== JSON.stringify(this.manifest.artifacts) ||
      JSON.stringify(disk.nativeDirectories) !== JSON.stringify(this.manifest.nativeDirectories) ||
      JSON.stringify(disk.platformDirectories) !== JSON.stringify(this.manifest.platformDirectories)) {
      result.retainedBatches++; return result;
    }
    const roots: string[] = fileIo.listFileSync(this.directory, { recursion: false });
    const flatEntries: ArtifactManifestEntry[] = this.manifest.artifacts.filter(
      (item: ArtifactManifestEntry): boolean => item.storageRelativePath.length === 0);
    const allowed: string[] = ['manifest.json', 'manifest.pending', 'lease.lock'].concat(
      flatEntries.map((item: ArtifactManifestEntry): string => item.id),
      this.manifest.nativeDirectories.map((item: NativeDirectoryManifest): string => 'native-' + item.id),
      this.manifest.platformDirectories.map((item: NativeDirectoryManifest): string => 'incoming-' + item.id));
    if (roots.some((name: string): boolean => allowed.indexOf(name) < 0)) { result.invalidBatches++; return result; }
    for (const entry of flatEntries) {
      const directory: string = this.directory + '/' + entry.id; assertDirectory(directory);
      const expected: string = entry.directory || entry.state === 'complete' || entry.state === 'removed' ? entry.name : partialName(entry.name);
      if (fileIo.listFileSync(directory, { recursion: false }).some((name: string): boolean => name !== expected)) {
        result.invalidBatches++; return result;
      }
    }
    for (const native of this.manifest.nativeDirectories) {
      if (native.state !== 'complete' && native.state !== 'aborted') { result.retainedBatches++; return result; }
      const nativeRoot: string = this.nativeDirectoryPath(native.id);
      const nativeAllowed: string[] = [];
      for (const item of this.manifest.artifacts) {
        if (!item.storageRelativePath.startsWith('native-' + native.id + '/')) { continue; }
        const parts: string[] = item.storageRelativePath.split('/').slice(1); let relative: string = '';
        for (let i: number = 0; i < parts.length; i++) {
          relative = relative.length === 0 ? parts[i] : relative + '/' + parts[i];
          if (nativeAllowed.indexOf(relative) < 0) { nativeAllowed.push(relative); }
        }
        if (native.layout === 'rdpReceive' && nativeAllowed.indexOf(parts[0] + '/partial') < 0) {
          nativeAllowed.push(parts[0] + '/partial');
        }
      }
      validateNativeTreeListing(nativeRoot, '', nativeAllowed, native.layout === 'rdpReceive');
    }
    for (const platform of this.manifest.platformDirectories) {
      if (platform.state !== 'complete' && platform.state !== 'aborted') { result.retainedBatches++; return result; }
      const platformRoot: string = this.platformDirectoryPath(platform.id); const platformAllowed: string[] = [];
      for (const item of this.manifest.artifacts) {
        if (!item.storageRelativePath.startsWith('incoming-' + platform.id + '/')) { continue; }
        const parts: string[] = item.storageRelativePath.split('/').slice(1); let path: string = '';
        for (const part of parts) { path = path.length === 0 ? part : path + '/' + part;
          if (platformAllowed.indexOf(path) < 0) { platformAllowed.push(path); } }
      }
      validateNativeTreeListing(platformRoot, '', platformAllowed);
    }
    const paths: string[] = []; const snapshots: fileIo.Stat[] = []; const entries: ArtifactManifestEntry[] = [];
    for (const entry of this.manifest.artifacts) {
      if (entry.directory) {
        if (entry.storageRelativePath.length === 0 && entry.state === 'complete') {
          const path: string = this.writerPath(entry, false); assertDirectory(path);
          if (fileIo.listFileSync(path, { recursion: false }).length !== 0) { result.invalidBatches++; return result; }
        }
        continue;
      }
      if (entry.state === 'removed') { continue; }
      let path: string = '';
      if (entry.storageRelativePath.length > 0) { path = this.writerPath(entry, false); }
      else {
        const directory: string = this.directory + '/' + entry.id; assertDirectory(directory);
        const children: string[] = fileIo.listFileSync(directory, { recursion: false });
        const expected: string = entry.state === 'complete' ? entry.name : partialName(entry.name);
        if (children.some((name: string): boolean => name !== expected)) { result.invalidBatches++; return result; }
        if (children.length === 0) { continue; } path = directory + '/' + expected;
      }
      const info: fileIo.Stat = fileIo.lstatSync(path);
      if (!info.isFile() || info.isSymbolicLink()) { result.invalidBatches++; return result; }
      if (entry.state === 'complete' && (info.size !== entry.size ||
        await hashFile(path, entry.size, (): boolean => !this.staging && !this.manifest.published && this.manifest.holders.length === 0) !== entry.sha256)) {
        result.invalidBatches++; return result;
      }
      paths.push(path); snapshots.push(info); entries.push(entry);
    }
    for (let i: number = 0; i < paths.length; i++) {
      if (this.staging || this.manifest.published || this.manifest.holders.length > 0) { result.retainedBatches++; break; }
      const latest: ArtifactManifest = readManifest(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id);
      if (latest.published || latest.holders.length > 0) { result.retainedBatches++; break; }
      this.assertPath(); checkedTransferPath(this.directory, paths[i].substring(this.directory.length + 1), false);
      const info: fileIo.Stat = fileIo.lstatSync(paths[i]); const before: fileIo.Stat = snapshots[i];
      if (!info.isFile() || info.isSymbolicLink() || info.size !== before.size || info.ino !== before.ino ||
        info.mtime !== before.mtime || info.ctime !== before.ctime) { result.invalidBatches++; break; }
      await fileIo.unlink(paths[i]); result.removedFiles++; result.removedBytes += before.size; entries[i].state = 'removed';
    }
    // Keep directory topology and ownership evidence; clear only the completed UI records.
    if (result.invalidBatches === 0 && result.retainedBatches === 0) {
      for (const entry of this.manifest.artifacts) { if (entry.directory && entry.state === 'complete') { entry.state = 'removed'; } }
    }
    this.saveManifest(); return result;
  }
}
interface ArtifactIoError { code?: number | string; }

/** The native adapter must drain every duplicated FD before commit/abort. */
export class TransferReceivedArtifactWriter {
  private batch: TransferArtifactBatch;
  private entry: ArtifactManifestEntry;
  private file: fileIo.File | null;
  private expectedSize: number;
  private reservedBytes: number;
  private guard: () => boolean;
  private copied: number = 0;
  private busy: boolean = false;
  private closing: boolean = false;
  private cancelled: boolean = false;
  private finished: boolean = false;
  private nativeMode: boolean = false;
  private retainedPartial: boolean = false;
  private commitTail: Promise<void> = Promise.resolve();
  private tail: Promise<void> = Promise.resolve();
  private result: TransferArtifact | null = null;
  private digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');

  constructor(batch: TransferArtifactBatch, entry: ArtifactManifestEntry, file: fileIo.File,
    expectedSize: number, reservedBytes: number, guard: () => boolean, nativeMode: boolean = false) {
    this.batch = batch; this.entry = entry; this.file = file; this.expectedSize = expectedSize;
    this.reservedBytes = reservedBytes; this.guard = guard; this.nativeMode = nativeMode;
  }
  get fd(): number { return this.file === null ? -1 : this.file.fd; }
  get path(): string { return this.batch.writerPath(this.entry, true); }

  async write(block: ArrayBuffer): Promise<number> {
    if (this.busy || this.closing || this.finished || this.nativeMode || block.byteLength > 256 * 1024) {
      throw new Error('transfer_writer_unavailable');
    }
    const bytes: ArrayBuffer = block.slice(0);
    this.busy = true;
    const operation: Promise<number> = this.writeOnce(bytes);
    this.tail = operation.then((): void => {}, (): void => {});
    try { return await operation; } finally { this.busy = false; }
  }
  private async writeOnce(bytes: ArrayBuffer): Promise<number> {
    checkCurrent(this.guard);
    if (this.cancelled || this.file === null || this.copied + bytes.byteLength > TRANSFER_FILE_LIMIT_BYTES ||
      (this.expectedSize >= 0 && this.copied + bytes.byteLength > this.expectedSize)) { throw new Error('transfer_size_limit'); }
    if (this.expectedSize < 0) {
      await this.batch.reserveAdditional(bytes.byteLength, this.guard); this.reservedBytes += bytes.byteLength;
    }
    let written: number = 0;
    while (written < bytes.byteLength) {
      checkCurrent(this.guard);
      if (this.cancelled) { throw new Error('transfer_cancelled'); }
      const count: number = await fileIo.write(this.file.fd, bytes.slice(written));
      if (count <= 0 || count > bytes.byteLength - written) { throw new Error('transfer_short_write'); }
      written += count;
    }
    await this.digest.update({ data: new Uint8Array(bytes) }); this.copied += written;
    return written;
  }
  async commit(mtime: number = Date.now() / 1000): Promise<TransferArtifact> {
    if (this.result !== null) { return this.result; }
    if (this.closing || this.finished) { throw new Error('transfer_writer_unavailable'); }
    this.closing = true; await this.tail;
    const operation: Promise<TransferArtifact> = this.commitOnce(mtime);
    this.commitTail = operation.then((): void => {}, (): void => {});
    return operation;
  }
  private async commitOnce(mtime: number): Promise<TransferArtifact> {
    try {
      checkCurrent(this.guard);
      if (this.cancelled || this.file === null) { throw new Error('transfer_cancelled'); }
      const info: fileIo.Stat = await fileIo.stat(this.file.fd);
      if (!info.isFile() || !validCount(info.size) || info.size > TRANSFER_FILE_LIMIT_BYTES ||
        (this.expectedSize >= 0 && info.size !== this.expectedSize) || (!this.nativeMode && info.size !== this.copied)) {
        throw new Error('transfer_received_size_mismatch');
      }
      await fileIo.fsync(this.file.fd);
      await fileIo.close(this.file); this.file = null;
      const path: string = this.batch.writerPath(this.entry, true);
      const actualHash: string = await hashFile(path, info.size, this.guard);
      if (!this.nativeMode && actualHash !== digestHex((await this.digest.digest()).data)) { throw new Error('transfer_received_hash_mismatch'); }
      checkCurrent(this.guard);
      if (this.cancelled) { throw new Error('transfer_cancelled'); }
      this.result = await this.batch.commitWriter(this.entry, info.size, actualHash, Number.isFinite(mtime) && mtime >= 0 ? mtime : 0);
      this.finish(); return this.result;
    } catch (error) {
      await this.abortOwned(); throw new Error('transfer_artifact_operation_failed');
    }
  }
  async retainPartial(): Promise<void> {
    if (this.finished || this.result !== null) { return; }
    this.cancelled = true; this.closing = true;
    this.retainedPartial = true;
    try { this.batch.retain('native-unknown:' + this.entry.id); } finally {
      await this.tail; await this.commitTail;
      if (this.file !== null) { try { await fileIo.close(this.file); } catch (_error) {} this.file = null; }
    }
    // Do not finish: reservation and batch admission remain held until process restart/reconciliation.
  }
  async abandon(): Promise<void> { await this.retainPartial(); }
  async abort(): Promise<void> {
    if (this.finished || this.retainedPartial) { return; }
    this.cancelled = true; this.closing = true; await this.tail; await this.commitTail;
    await this.abortOwned();
  }
  private async abortOwned(): Promise<void> {
    if (this.finished || this.retainedPartial) { return; }
    if (this.file !== null) { try { await fileIo.close(this.file); } catch (_closeError) {} this.file = null; }
    await this.batch.abortWriter(this.entry); this.finish();
  }
  private finish(): void {
    if (this.finished) { return; }
    this.finished = true; this.batch.finishWriter(this.reservedBytes); this.reservedBytes = 0;
  }
}

function validateNativeTreeListing(root: string, relative: string, allowed: string[], nativeLayout: boolean = false): void {
  const path: string = relative.length === 0 ? root : checkedTransferPath(root, relative, true);
  const children: string[] = fileIo.listFileSync(path, { recursion: false });
  for (let i: number = 0; i < children.length; i++) {
    const name: string = relative.length === 0 ? children[i] : relative + '/' + children[i];
    if (allowed.indexOf(name) < 0) { throw new Error('transfer_received_tree_unexpected_entry'); }
    const info: fileIo.Stat = fileIo.lstatSync(root + '/' + name);
    if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory()) ||
      (nativeLayout && name.split('/').length === 2 && name.endsWith('/partial') && !info.isDirectory())) { throw new Error('transfer_received_tree_invalid'); }
    if (info.isDirectory()) { validateNativeTreeListing(root, name, allowed, nativeLayout); }
  }
}
export class TransferNativeReceiveDirectory {
  private batch: TransferArtifactBatch;
  private id: string;
  private file: fileIo.File | null;
  private reservedBytes: number;
  private guard: () => boolean;
  private retained: boolean = false;
  private closing: boolean = false;
  private finished: boolean = false;
  private result: TransferArtifact[] | null = null;
  private commitTail: Promise<void> = Promise.resolve();
  constructor(batch: TransferArtifactBatch, id: string, file: fileIo.File, reservedBytes: number, guard: () => boolean) {
    this.batch = batch; this.id = id; this.file = file; this.reservedBytes = reservedBytes; this.guard = guard;
  }
  get fd(): number { return this.file === null ? -1 : this.file.fd; }
  get path(): string { return this.batch.nativeDirectoryPath(this.id); }
  async commit(expectedEntries: TransferNativeReceivedEntry[]): Promise<TransferArtifact[]> {
    if (this.result !== null) { return this.result; }
    if (this.finished || this.retained || this.closing) { throw new Error('transfer_native_directory_unavailable'); }
    this.closing = true;
    const operation: Promise<TransferArtifact[]> = this.commitOnce(expectedEntries);
    this.commitTail = operation.then((): void => {}, (): void => {});
    return operation;
  }
  private async commitOnce(expectedEntries: TransferNativeReceivedEntry[]): Promise<TransferArtifact[]> {
    try {
      checkCurrent(this.guard);
      if (this.file !== null) { await fileIo.fsync(this.file.fd); await fileIo.close(this.file); this.file = null; }
      const artifacts: TransferArtifact[] = await this.batch.importReceivedTree(this.id, expectedEntries, this.reservedBytes,
        (): boolean => !this.retained && current(this.guard));
      this.batch.finishNativeDirectory(this.id, 'complete', this.reservedBytes); this.finished = true; this.result = artifacts; return artifacts;
    } catch (_error) { await this.retainOwned(); throw new Error('transfer_native_directory_import_failed'); }
  }
  async retainPartial(): Promise<void> {
    if (this.finished) { return; }
    this.retained = true; this.closing = true; await this.commitTail; await this.retainOwned();
  }
  private async retainOwned(): Promise<void> {
    this.retained = true; this.closing = true;
    try { this.batch.retainNativeDirectory(this.id); } finally {
      if (this.file !== null) { try { await fileIo.close(this.file); } catch (_error) {} this.file = null; }
    }
  }
  async abandon(): Promise<void> { await this.retainPartial(); }
  async abort(): Promise<void> {
    if (this.finished || this.retained || this.closing) { return; }
    this.closing = true;
    if (this.file !== null) { try { await fileIo.close(this.file); } catch (_error) {} this.file = null; }
    if (fileIo.listFileSync(this.path, { recursion: false }).length > 0) { await this.retainPartial(); return; }
    this.batch.finishNativeDirectory(this.id, 'aborted', this.reservedBytes); this.finished = true;
  }
}

function collectPlatformEntries(root: string, relative: string, entries: ImportedArtifactEntry[],
  seen: string[], total: number[], limit: number): void {
  if (!validRelativeTransferPath(relative)) { throw new Error('transfer_incoming_path_invalid'); }
  if (seen.indexOf(relative) >= 0) { return; }
  const raw: fileIo.Stat = fileIo.lstatSync(root + '/' + relative);
  const directory: boolean = raw.isDirectory();
  const path: string = checkedTransferPath(root, relative, directory);
  if ((!directory && !raw.isFile()) || raw.isSymbolicLink() || !validCount(raw.size)) { throw new Error('transfer_incoming_type_invalid'); }
  if (entries.length >= 1024) { throw new Error('transfer_incoming_limit'); }
  const size: number = directory ? 0 : raw.size; total[0] += size;
  if (total[0] > limit || size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_incoming_size_limit'); }
  seen.push(relative); entries.push({ storageRelativePath: relative, relativePath: relative, directory, size });
  if (directory) {
    const children: string[] = fileIo.listFileSync(path, { recursion: false });
    for (const child of children) { collectPlatformEntries(root, relative + '/' + child, entries, seen, total, limit); }
  }
}

/** complete() requires the platform's 100% DataProgress callback and its delivered URIs.
 * Failure, cancellation requests and lost UI ownership never prove the writer stopped.
 */
export class TransferPlatformIncomingDirectory {
  private batch: TransferArtifactBatch;
  private id: string;
  private reservedBytes: number;
  private result: TransferArtifact[] | null = null;
  private imported: TransferArtifact[] | null = null;
  private inFlight: Promise<TransferArtifact[]> | null = null;
  constructor(batch: TransferArtifactBatch, id: string, reservedBytes: number) {
    this.batch = batch; this.id = id; this.reservedBytes = reservedBytes;
  }
  get path(): string { return this.batch.platformDirectoryPath(this.id); }
  async complete(uris: string[]): Promise<TransferArtifact[]> {
    if (this.result !== null) { return this.result; }
    if (this.inFlight !== null) { return await this.inFlight; }
    const operation: Promise<TransferArtifact[]> = this.completeOnce(uris.slice()); this.inFlight = operation;
    try { return await operation; } finally { this.inFlight = null; }
  }
  private async completeOnce(uris: string[]): Promise<TransferArtifact[]> {
    try {
      if (this.imported === null) { this.imported = await this.batch.importPlatformIncoming(this.id, uris, this.reservedBytes); }
      this.batch.finishPlatformDirectory(this.id, this.reservedBytes); this.result = this.imported; return this.result;
    } catch (_error) { this.batch.retainPlatformDirectory(this.id); throw new Error('transfer_incoming_completion_failed'); }
  }
  async retainPartial(): Promise<void> {
    if (this.inFlight !== null) { try { await this.inFlight; } catch (_error) {} }
    if (this.result === null) { this.batch.retainPlatformDirectory(this.id); }
  }
}

function measuredTreeBytes(path: string, depth: number, budget: number[]): number {
  if (depth > 40 || budget[0]-- <= 0) { return TRANSFER_CACHE_QUOTA_BYTES; }
  const info: fileIo.Stat = fileIo.lstatSync(path);
  if (info.isSymbolicLink()) { return 0; }
  if (info.isFile()) { return validCount(info.size) ? info.size : TRANSFER_CACHE_QUOTA_BYTES; }
  if (!info.isDirectory()) { return TRANSFER_CACHE_QUOTA_BYTES; }
  let total: number = 0; const children: string[] = fileIo.listFileSync(path, { recursion: false });
  for (let i: number = 0; i < children.length; i++) {
    total += measuredTreeBytes(path + '/' + children[i], depth + 1, budget);
    if (total >= TRANSFER_CACHE_QUOTA_BYTES) { return TRANSFER_CACHE_QUOTA_BYTES; }
  }
  return total;
}
function managedArtifactBytes(filesDir: string): number {
  // Count regular-file allocation conservatively even for unknown or retained ownership.
  // Quota measurement never reads payloads, follows symlinks, or grants deletion rights.
  try { const root: string = filesDir + '/transfer-artifacts-v1'; assertDirectory(root);
    return measuredTreeBytes(root, 0, [100000]); } catch (_error) { return TRANSFER_CACHE_QUOTA_BYTES; }
}

export function recoverTransferArtifactBatches(filesDir: string, scopeKey: string,
  purpose: ArtifactPurpose = 'clipboard'): TransferArtifactBatch[] {
  const result: TransferArtifactBatch[] = [];
  let names: string[] = [];
  try {
    validateFilesDir(filesDir);
    if (!/^[a-f0-9]{64}$/.test(scopeKey) || (purpose !== 'clipboard' && purpose !== 'received')) { return result; }
    const parent: string = filesDir + '/transfer-artifacts-v1/' + scopeKey + '/' + purpose;
    assertDirectory(filesDir + '/transfer-artifacts-v1'); assertDirectory(filesDir + '/transfer-artifacts-v1/' + scopeKey);
    assertDirectory(parent); names = fileIo.listFileSync(parent, { recursion: false });
  } catch (_error) { return result; }
  for (let i: number = 0; i < names.length; i++) {
    if (!names[i].startsWith('batch-')) { continue; }
    const batch: TransferArtifactBatch | null = TransferArtifactBatch.recover(filesDir, scopeKey, purpose, names[i].substring(6));
    if (batch !== null) { result.push(batch); }
  }
  return result;
}
export async function cleanupExpiredTransferArtifacts(filesDir: string, scopeKey: string,
  purpose: ArtifactPurpose = 'clipboard', ttlMs: number = DEFAULT_ARTIFACT_TTL_MS): Promise<TransferArtifactCleanupResult> {
  const result: TransferArtifactCleanupResult = { removedFiles: 0, removedBytes: 0, retainedBatches: 0, invalidBatches: 0 };
  if (!Number.isFinite(ttlMs) || ttlMs < 0) { result.invalidBatches++; return result; }
  const batches: TransferArtifactBatch[] = recoverTransferArtifactBatches(filesDir, scopeKey, purpose);
  for (let i: number = 0; i < batches.length; i++) {
    try {
      const removed: TransferArtifactCleanupResult = await batches[i].cleanupExpired(ttlMs);
      result.removedFiles += removed.removedFiles; result.removedBytes += removed.removedBytes;
      result.retainedBatches += removed.retainedBatches; result.invalidBatches += removed.invalidBatches;
    } catch (_error) { result.invalidBatches++; }
  }
  return result;
}

/** Recovery never infers that an old holder died from age or a successful file lock. */
export function recoverTransferArtifactInventory(filesDir: string, scopeKey: string,
  purpose: ArtifactPurpose = 'received'): TransferArtifactInventory {
  const result: TransferArtifactInventory = { artifacts: [], batches: [], invalidBatches: 0 };
  let names: string[] = [];
  try {
    validateFilesDir(filesDir);
    if (!/^[a-f0-9]{64}$/.test(scopeKey) || (purpose !== 'received' && purpose !== 'clipboard')) { return result; }
    const root: string = filesDir + '/transfer-artifacts-v1'; assertDirectory(root); assertDirectory(root + '/' + scopeKey);
    const parent: string = root + '/' + scopeKey + '/' + purpose; assertDirectory(parent);
    names = fileIo.listFileSync(parent, { recursion: false }).filter((name: string): boolean => name.startsWith('batch-'));
  } catch (_error) { return result; }
  for (const name of names) {
    const id: string = name.substring(6);
    const batch: TransferArtifactBatch | null = TransferArtifactBatch.recover(filesDir, scopeKey, purpose, id);
    if (batch === null) {
      result.invalidBatches++;
      result.batches.push({ id, purpose, createdAt: 0, updatedAt: 0, fileCount: 0, directoryCount: 0, bytes: 0,
        held: true, published: false, unknown: true, active: false, canCleanup: false, retentionReason: 'ownership-manifest-invalid' });
      continue;
    }
    try {
      const info: TransferArtifactBatchInfo = batch.getInfo();
      try { result.artifacts = result.artifacts.concat(batch.getArtifacts()); }
      catch (_error) { info.unknown = true; info.canCleanup = false; info.retentionReason = 'artifact-validation-failed'; result.invalidBatches++; }
      result.batches.push(info);
    } catch (_error) { result.invalidBatches++; }
  }
  return result;
}
export async function cleanupOwnedTransferArtifactBatch(filesDir: string, scopeKey: string,
  purpose: ArtifactPurpose, batchId: string): Promise<TransferArtifactCleanupResult> {
  const batch: TransferArtifactBatch | null = TransferArtifactBatch.recover(filesDir, scopeKey, purpose, batchId);
  if (batch === null) { return { removedFiles: 0, removedBytes: 0, retainedBatches: 0, invalidBatches: 1 }; }
  if (!batch.getInfo().canCleanup) { return { removedFiles: 0, removedBytes: 0, retainedBatches: 1, invalidBatches: 0 }; }
  return await batch.cleanupExpired(0);
}

/** Picker owns destination authorization. No source deletion and no atomic-export claim. */
export async function exportTransferArtifact(artifact: TransferArtifact, pickerUri: string,
  isCurrent: () => boolean, progress: (written: number, total: number) => void,
  allowOverwrite: boolean = false): Promise<TransferArtifactExportResult> {
  return exportTransferArtifactImpl(artifact, pickerUri, isCurrent, progress, allowOverwrite, -1);
}

/** Caller owns an exclusively created, empty target FD and closes it after this operation. */
export async function exportTransferArtifactToFd(artifact: TransferArtifact, exclusiveFd: number,
  isCurrent: () => boolean, progress: (written: number, total: number) => void): Promise<TransferArtifactExportResult> {
  if (!Number.isInteger(exclusiveFd) || exclusiveFd < 0) {
    return { status: 'failed', writtenBytes: 0, sha256: '', verified: false,
      diagnosticCode: 'export_invalid_fd', evidence: 'none' };
  }
  return exportTransferArtifactImpl(artifact, '', isCurrent, progress, false, exclusiveFd);
}

async function exportTransferArtifactImpl(artifact: TransferArtifact, pickerUri: string,
  isCurrent: () => boolean, progress: (written: number, total: number) => void,
  allowOverwrite: boolean, exclusiveFd: number): Promise<TransferArtifactExportResult> {
  const result: TransferArtifactExportResult = { status: 'failed', writtenBytes: 0, sha256: '', verified: false, diagnosticCode: '', evidence: 'none' };
  let owner: TransferArtifactBatch | null = null;
  let source: fileIo.File | null = null;
  let destination: fileIo.File | null = null;
  let destinationTouched: boolean = false;
  const holder: string = 'export:' + util.generateRandomUUID(false);
  try {
    checkCurrent(isCurrent);
    owner = TransferArtifactBatch.owner(artifact);
    if (owner === null || artifact.directory === true) { throw new Error('transfer_artifact_unowned'); }
    owner.retain(holder);
    if (await hashFile(artifact.path, artifact.size, isCurrent) !== artifact.sha256) { throw new Error('transfer_artifact_changed'); }
    source = await fileIo.open(artifact.path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    const sourceInfo: fileIo.Stat = await fileIo.stat(source.fd);
    checkCurrent(isCurrent);
    if (exclusiveFd < 0) {
      destination = await fileIo.open(pickerUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    }
    const targetFd: number = destination === null ? exclusiveFd : destination.fd;
    const targetInfo: fileIo.Stat = await fileIo.stat(targetFd);
    if (!targetInfo.isFile() || targetInfo.ino === sourceInfo.ino || (targetInfo.size > 0 && !allowOverwrite)) {
      throw new Error('transfer_export_target_unavailable');
    }
    checkCurrent(isCurrent);
    if (allowOverwrite) { destinationTouched = true; await fileIo.truncate(targetFd, 0); }
    const digest = cryptoFramework.createMd('SHA256');
    let reportedAt: number = 0;
    while (result.writtenBytes < artifact.size) {
      checkCurrent(isCurrent);
      const buffer: ArrayBuffer = new ArrayBuffer(Math.min(TRANSFER_COPY_BLOCK_BYTES, artifact.size - result.writtenBytes));
      const read: number = await fileIo.read(source.fd, buffer);
      if (read <= 0 || read > buffer.byteLength) { throw new Error('transfer_artifact_changed'); }
      let written: number = 0;
      while (written < read) {
        checkCurrent(isCurrent); destinationTouched = true;
        const count: number = await fileIo.write(targetFd, buffer.slice(written, read));
        if (count <= 0 || count > read - written) { throw new Error('transfer_export_short_write'); }
        written += count; result.writtenBytes += count;
      }
      await digest.update({ data: new Uint8Array(buffer, 0, read) });
      if (Date.now() - reportedAt >= 250) { reportedAt = Date.now(); safeProgress(progress, result.writtenBytes, artifact.size); }
    }
    result.sha256 = digestHex((await digest.digest()).data);
    const after: fileIo.Stat = await fileIo.stat(source.fd);
    if (after.size !== sourceInfo.size || after.ino !== sourceInfo.ino || after.mtime !== sourceInfo.mtime ||
      after.ctime !== sourceInfo.ctime || result.sha256 !== artifact.sha256) { throw new Error('transfer_artifact_changed'); }
    checkCurrent(isCurrent); await fileIo.fsync(targetFd);
    if ((await fileIo.stat(targetFd)).size !== artifact.size) { throw new Error('transfer_export_size_mismatch'); }
    if (destination !== null) { await fileIo.close(destination); destination = null; }
    result.status = 'saved'; result.evidence = 'writtenAndSynced'; safeProgress(progress, artifact.size, artifact.size);
    return result;
  } catch (error) {
    result.status = destinationTouched ? 'commitUnknown' : (current(isCurrent) ? 'failed' : 'cancelled');
    result.diagnosticCode = destinationTouched ? 'export_destination_retained' : 'export_not_committed';
    return result;
  } finally {
    if (source !== null) { try { await fileIo.close(source); } catch (_error) {} }
    if (destination !== null) { try { await fileIo.close(destination); } catch (_error) {} }
    if (owner !== null) { try { owner.release(holder); } catch (_error) { /* Durable hold remains conservative. */ } }
  }
}
