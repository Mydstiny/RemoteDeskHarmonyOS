import { fileIo, statfs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export const TRANSFER_COPY_BLOCK_BYTES: number = 64 * 1024;
export const TRANSFER_FILE_LIMIT_BYTES: number = 2 * 1024 * 1024 * 1024;
export const TRANSFER_CACHE_QUOTA_BYTES: number = 4 * 1024 * 1024 * 1024;
const TRANSFER_SPACE_RESERVE: number = 32 * 1024 * 1024;
const TRANSFER_BATCH_LIMIT: number = 15;
const DEFAULT_ARTIFACT_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
const MANIFEST_LIMIT_BYTES: number = 2 * 1024 * 1024;
type ArtifactPurpose = 'clipboard' | 'received';
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
interface NativeDirectoryManifest {
  id: string;
  state: 'active' | 'retained' | 'complete' | 'aborted';
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
  const nativeDirectories: NativeDirectoryManifest[] = [];
  if (parsed.nativeDirectories !== undefined) {
    if (!Array.isArray(parsed.nativeDirectories) || parsed.nativeDirectories.length > 15) { throw new Error('transfer_manifest_invalid'); }
    for (let i: number = 0; i < parsed.nativeDirectories.length; i++) {
      const item: NativeDirectoryManifest = parsed.nativeDirectories[i];
      if (!validId(item.id) || ['active', 'retained', 'complete', 'aborted'].indexOf(item.state) < 0 ||
        nativeDirectories.some((existing: NativeDirectoryManifest): boolean => existing.id === item.id)) { throw new Error('transfer_manifest_invalid'); }
      nativeDirectories.push({ id: item.id, state: item.state });
    }
  }
  const artifacts: ArtifactManifestEntry[] = [];
  const names: string[] = [];
  for (let i: number = 0; i < parsed.artifacts.length; i++) {
    const item: ArtifactManifestEntry = parsed.artifacts[i];
    if (item === null) { throw new Error('transfer_manifest_invalid'); }
    const state: ArtifactState = legacy ? 'complete' : item.state;
    const native: boolean = typeof item.storageRelativePath === 'string' && item.storageRelativePath.length > 0;
    const directory: boolean = native && item.directory === true;
    const relativePath: string = native ? item.relativePath : item.name;
    const storageRelativePath: string = native ? item.storageRelativePath : '';
    if ((native && (!validRelativeTransferPath(relativePath) || !validRelativeTransferPath(storageRelativePath, 36, 1200) ||
      !nativeDirectories.some((owner: NativeDirectoryManifest): boolean => storageRelativePath.startsWith('native-' + owner.id + '/')) ||
      relativePath.split('/').pop() !== item.name)) || item === null || !validId(item.id) || typeof item.name !== 'string' || (!native && item.name !== safeTransferFileName(item.name)) ||
      !validCount(item.size) || item.size > TRANSFER_FILE_LIMIT_BYTES || !Number.isFinite(item.mtime) || item.mtime < 0 ||
      (state !== 'partial' && state !== 'complete' && state !== 'removed') ||
      (state === 'complete' && !directory && !/^[a-f0-9]{64}$/.test(item.sha256)) ||
      (state !== 'complete' && item.sha256 !== '' && !/^[a-f0-9]{64}$/.test(item.sha256)) ||
      artifacts.some((existing: ArtifactManifestEntry): boolean => existing.id === item.id) ||
      names.indexOf(relativePath.normalize('NFC').toLowerCase()) >= 0) { throw new Error('transfer_manifest_invalid'); }
    artifacts.push({ id: item.id, name: item.name, size: item.size, mtime: item.mtime, sha256: item.sha256, state, storageRelativePath, relativePath, directory });
    names.push(relativePath.normalize('NFC').toLowerCase());
  }
  return { schemaVersion: 2, id: batchId, createdAt: parsed.createdAt,
    updatedAt: legacy ? parsed.createdAt : parsed.updatedAt, scopeKey, purpose,
    published: legacy ? true : parsed.published, holders: legacy ? ['legacy-unknown'] : parsed.holders.slice(), artifacts, nativeDirectories };
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

/** One private batch; creator hold is released explicitly when handoff is complete. */
export class TransferArtifactBatch {
  readonly directory: string;
  readonly id: string;
  private filesDir: string;
  private manifest: ArtifactManifest;
  private staging: boolean = false;
  private cleaning: boolean = false;
  private static reservedBytes: number = 0;
  private static batches: Map<string, TransferArtifactBatch> = new Map<string, TransferArtifactBatch>();

  constructor(filesDir: string, scopeKey: string, purpose: ArtifactPurpose = 'clipboard', restored?: ArtifactManifest) {
    this.filesDir = filesDir;
    if (restored !== undefined) {
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
        updatedAt: Date.now(), published: false, holders: ['creator'], artifacts: [], nativeDirectories: [] };
      this.saveManifest();
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
    if (this.manifest.holders.indexOf(ownerId) >= 0) { return; }
    if (this.manifest.holders.length >= 64) { throw new Error('transfer_holders_full'); }
    this.manifest.holders.push(ownerId); this.saveManifest();
  }
  release(ownerId: string = 'creator'): void {
    this.manifest.holders = this.manifest.holders.filter((holder: string): boolean => holder !== ownerId);
    this.saveManifest();
  }
  setPublished(published: boolean): void {
    if (this.cleaning && published) { throw new Error('transfer_cleanup_in_progress'); }
    this.manifest.published = published; this.saveManifest(); }
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
  private reserveName(displayName: string): string {
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
    const names: string[] = this.manifest.artifacts.map((item: ArtifactManifestEntry): string => item.name.toLowerCase());
    while (names.indexOf(candidate.toLowerCase()) >= 0) {
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
  private startStaging(guard: () => boolean): void {
    if (this.staging || this.cleaning || !current(guard) || this.manifest.artifacts.length >= TRANSFER_BATCH_LIMIT) {
      throw new Error('transfer_batch_unavailable');
    }
    this.assertPath(); this.staging = true;
  }
  private async reserve(bytes: number, guard: () => boolean): Promise<void> {
    if (!validCount(bytes) || bytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    this.assertPath();
    const free: number = await statfs.getFreeSize(this.directory);
    checkCurrent(guard);
    if (!Number.isFinite(free) || free < bytes + TransferArtifactBatch.reservedBytes + TRANSFER_SPACE_RESERVE ||
      managedArtifactBytes(this.filesDir) + TransferArtifactBatch.reservedBytes + bytes > TRANSFER_CACHE_QUOTA_BYTES) {
      throw new Error('transfer_space_limit');
    }
    TransferArtifactBatch.reservedBytes += bytes;
  }
  private async openWriter(displayName: string, size: number, guard: () => boolean, nativeMode: boolean = false): Promise<TransferReceivedArtifactWriter> {
    if ((!validCount(size) && size !== -1) || size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_size_limit'); }
    const reserved: number = Math.max(0, size);
    await this.reserve(reserved, guard);
    const id: string = util.generateRandomUUID(false);
    if (!validId(id)) { TransferArtifactBatch.reservedBytes -= reserved; throw new Error('transfer_identifier_invalid'); }
    const entry: ArtifactManifestEntry = { id, name: this.reserveName(displayName), size: Math.max(0, size),
      mtime: 0, sha256: '', state: 'partial', storageRelativePath: '', relativePath: '', directory: false };
    entry.relativePath = entry.name;
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
      this.manifest.artifacts = this.manifest.artifacts.filter((item: ArtifactManifestEntry): boolean => item.id !== id);
      try { this.saveManifest(); } catch (_manifestError) { /* Preserve interrupted manifest for recovery. */ }
      TransferArtifactBatch.reservedBytes -= reserved;
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

  async createNativeReceiveDirectory(isCurrent: () => boolean,
    expectedBytes: number = TRANSFER_FILE_LIMIT_BYTES): Promise<TransferNativeReceiveDirectory> {
    this.startStaging(isCurrent); let reserved: boolean = false; let file: fileIo.File | null = null;
    const id: string = util.generateRandomUUID(false);
    try {
      if (this.manifest.purpose !== 'received' || this.manifest.nativeDirectories.length >= 15 || !validId(id)) { throw new Error('transfer_receive_scope_invalid'); }
      await this.reserve(expectedBytes, isCurrent); reserved = true;
      const path: string = this.directory + '/native-' + id; fileIo.mkdirSync(path);
      this.manifest.nativeDirectories.push({ id, state: 'active' }); this.retain('native-directory:' + id);
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
      (item: ArtifactManifestEntry): string => item.relativePath.normalize('NFC').toLowerCase());
    const indices: number[] = []; let total: number = 0; let receiveRoot: string = '';
    for (let i: number = 0; i < expectedEntries.length; i++) {
      const item: TransferNativeReceivedEntry = expectedEntries[i];
      if (!validRelativeTransferPath(item.relativeName, 34, 1100) || !validCount(item.index) ||
        indices.indexOf(item.index) >= 0 || !validCount(item.size) || item.size > TRANSFER_FILE_LIMIT_BYTES ||
        typeof item.directory !== 'boolean' || (item.directory && item.size !== 0)) { throw new Error('transfer_received_tree_invalid'); }
      const parts: string[] = item.relativeName.split('/');
      if (parts.length < 3 || !/^receive-[0-9]+$/.test(parts[0]) || parts[1] !== 'files' ||
        (receiveRoot.length > 0 && receiveRoot !== parts[0])) { throw new Error('transfer_received_tree_invalid'); }
      const normalized: string = parts.slice(2).join('/').normalize('NFC').toLowerCase();
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
    validateNativeTreeListing(root, '', allowed);
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

  async stage(uri: string, displayName: string, expectedSize: number,
    isCurrent: () => boolean, progress: (copied: number, total: number) => void): Promise<TransferArtifact> {
    if ((!validCount(expectedSize) && expectedSize !== -1) || expectedSize > TRANSFER_FILE_LIMIT_BYTES) {
      throw new Error('transfer_size_limit');
    }
    this.startStaging(isCurrent);
    let input: fileIo.File | null = null;
    let writer: TransferReceivedArtifactWriter | null = null;
    try {
      input = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      const before: fileIo.Stat = await fileIo.stat(input.fd);
      checkCurrent(isCurrent);
      if (!before.isFile() || !validCount(before.size) || before.size > TRANSFER_FILE_LIMIT_BYTES ||
        (expectedSize !== -1 && before.size !== expectedSize)) { throw new Error('transfer_source_changed'); }
      const size: number = before.size;
      writer = await this.openWriter(displayName, size, isCurrent);
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
    this.staging = false;
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
    this.cleaning = true;
    try { return await this.cleanupExpiredOwned(ttlMs); } finally { this.cleaning = false; }
  }
  private async cleanupExpiredOwned(ttlMs: number): Promise<TransferArtifactCleanupResult> {
    const result: TransferArtifactCleanupResult = { removedFiles: 0, removedBytes: 0, retainedBatches: 0, invalidBatches: 0 };
    if (this.staging || this.manifest.published || this.manifest.holders.length > 0 ||
      Date.now() - this.manifest.updatedAt < ttlMs) { result.retainedBatches++; return result; }
    this.assertPath();
    // Re-read the on-disk ownership evidence before any deletion, including active instances.
    const disk: ArtifactManifest = readManifest(this.filesDir, this.manifest.scopeKey, this.manifest.purpose as ArtifactPurpose, this.id);
    if (disk.published || disk.holders.length > 0 || JSON.stringify(disk.artifacts) !== JSON.stringify(this.manifest.artifacts) ||
      JSON.stringify(disk.nativeDirectories) !== JSON.stringify(this.manifest.nativeDirectories)) {
      result.retainedBatches++; return result;
    }
    const roots: string[] = fileIo.listFileSync(this.directory, { recursion: false });
    const flatEntries: ArtifactManifestEntry[] = this.manifest.artifacts.filter(
      (item: ArtifactManifestEntry): boolean => item.storageRelativePath.length === 0);
    const allowed: string[] = ['manifest.json', 'manifest.pending'].concat(
      flatEntries.map((item: ArtifactManifestEntry): string => item.id),
      this.manifest.nativeDirectories.map((item: NativeDirectoryManifest): string => 'native-' + item.id));
    if (roots.some((name: string): boolean => allowed.indexOf(name) < 0)) { result.invalidBatches++; return result; }
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
        if (nativeAllowed.indexOf(parts[0] + '/partial') < 0) { nativeAllowed.push(parts[0] + '/partial'); }
      }
      validateNativeTreeListing(nativeRoot, '', nativeAllowed);
    }
    const paths: string[] = []; const snapshots: fileIo.Stat[] = []; const entries: ArtifactManifestEntry[] = [];
    for (const entry of this.manifest.artifacts) {
      if (entry.directory || entry.state === 'removed') { continue; }
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
      this.assertPath(); checkedTransferPath(this.directory, paths[i].substring(this.directory.length + 1), false);
      const info: fileIo.Stat = fileIo.lstatSync(paths[i]); const before: fileIo.Stat = snapshots[i];
      if (!info.isFile() || info.isSymbolicLink() || info.size !== before.size || info.ino !== before.ino ||
        info.mtime !== before.mtime || info.ctime !== before.ctime) { result.invalidBatches++; break; }
      await fileIo.unlink(paths[i]); result.removedFiles++; result.removedBytes += before.size; entries[i].state = 'removed';
    }
    // Keep all directory topology and the ownership manifest; never use recursive rmdir.
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

function validateNativeTreeListing(root: string, relative: string, allowed: string[]): void {
  const path: string = relative.length === 0 ? root : checkedTransferPath(root, relative, true);
  const children: string[] = fileIo.listFileSync(path, { recursion: false });
  for (let i: number = 0; i < children.length; i++) {
    const name: string = relative.length === 0 ? children[i] : relative + '/' + children[i];
    if (allowed.indexOf(name) < 0) { throw new Error('transfer_received_tree_unexpected_entry'); }
    const info: fileIo.Stat = fileIo.lstatSync(root + '/' + name);
    if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory()) ||
      (name.split('/').length === 2 && name.endsWith('/partial') && !info.isDirectory())) { throw new Error('transfer_received_tree_invalid'); }
    if (info.isDirectory()) { validateNativeTreeListing(root, name, allowed); }
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

/** Picker owns destination authorization. No source deletion and no atomic-export claim. */
export async function exportTransferArtifact(artifact: TransferArtifact, pickerUri: string,
  isCurrent: () => boolean, progress: (written: number, total: number) => void,
  allowOverwrite: boolean = false): Promise<TransferArtifactExportResult> {
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
    destination = await fileIo.open(pickerUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    const targetInfo: fileIo.Stat = await fileIo.stat(destination.fd);
    if (!targetInfo.isFile() || targetInfo.ino === sourceInfo.ino || (targetInfo.size > 0 && !allowOverwrite)) {
      throw new Error('transfer_export_target_unavailable');
    }
    checkCurrent(isCurrent);
    if (allowOverwrite) { destinationTouched = true; await fileIo.truncate(destination.fd, 0); }
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
        const count: number = await fileIo.write(destination.fd, buffer.slice(written, read));
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
    checkCurrent(isCurrent); await fileIo.fsync(destination.fd);
    if ((await fileIo.stat(destination.fd)).size !== artifact.size) { throw new Error('transfer_export_size_mismatch'); }
    await fileIo.close(destination); destination = null;
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
