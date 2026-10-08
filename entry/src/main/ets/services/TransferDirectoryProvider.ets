import { fileIo, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  exportTransferArtifactToFd, TransferArtifact, TransferArtifactBatch, TransferArtifactExportResult,
  TRANSFER_FILE_LIMIT_BYTES
} from './TransferArtifactStore';
import { ExtensionLoader } from './ExtensionLoader';

export const TRANSFER_TREE_MAX_DEPTH: number = 32;
export const TRANSFER_TREE_MAX_ITEMS: number = 1024;
export interface TransferDirectorySourceEntry {
  relativePath: string;
  uri: string;
  name: string;
  directory: boolean;
  size: number;
  mtime: number;
}
export interface TransferDirectorySourceTree {
  status: 'ready' | 'cancelled' | 'unavailable' | 'failed';
  rootName: string;
  entries: TransferDirectorySourceEntry[];
  totalBytes: number;
  diagnosticCode: string;
}
export interface TransferDirectoryExportEntry {
  relativePath: string;
  destinationUri: string;
  directory: boolean;
  status: 'saved' | 'cancelled' | 'failed' | 'commitUnknown' | 'skipped';
  writtenBytes: number;
  evidence: 'none' | 'directoryCreated' | 'writtenAndSynced';
  diagnosticCode: string;
}
export interface TransferDirectoryExportResult {
  status: 'saved' | 'partial' | 'cancelled' | 'unavailable' | 'failed' | 'commitUnknown';
  rootName: string;
  destinationUri: string;
  entries: TransferDirectoryExportEntry[];
  writtenBytes: number;
  evidence: 'none' | 'directoriesCreated' | 'writtenAndSynced' | 'partial';
  diagnosticCode: string;
}
interface SelectedDirectory {
  uri: string;
  path: string;
  name: string;
}
interface TreeExportPlan {
  rootName: string;
  directories: string[];
  files: TransferArtifact[];
  totalBytes: number;
}
interface DirectoryIdentity {
  path: string;
  ino: bigint;
}

function current(guard: () => boolean): boolean { try { return guard(); } catch (_error) { return false; } }
function check(guard: () => boolean): void { if (!current(guard)) { throw new Error('transfer_directory_cancelled'); } }
async function checked<T>(guard: () => boolean, action: () => Promise<T>): Promise<T> {
  check(guard); const result: T = await action(); check(guard); return result;
}
function key(value: string): string { return value.normalize('NFC').toLowerCase(); }
function validName(value: string): boolean {
  return value.length > 0 && value !== '.' && value !== '..' && value.length <= 255 &&
    !/[\\/:*?"<>|\u0000-\u001f\u007f]/.test(value) && value.trim() === value && !value.endsWith('.');
}
function pathParts(value: string): string[] {
  const parts: string[] = value.split('/');
  if (parts.length > TRANSFER_TREE_MAX_DEPTH || parts.some((part: string): boolean => !validName(part))) {
    throw new Error('transfer_directory_invalid_path');
  }
  return parts;
}
function selectedDirectory(uri: string): SelectedDirectory {
  // Preserve the Picker authority (for example file://docs). getUriFromPath is
  // documented only for sandbox paths and must not manufacture document grants.
  if (!uri.startsWith('file://') || uri.indexOf('?') >= 0 || uri.indexOf('#') >= 0) {
    throw new Error('transfer_directory_unsupported_uri');
  }
  const baseUri: string = uri.replace(/\/+$/, '');
  const path: string = new fileUri.FileUri(baseUri).path.replace(/\/+$/, '');
  if (!path.startsWith('/') || path.length > 4096 || path.indexOf('\u0000') >= 0 ||
    path.split('/').slice(1).some((part: string): boolean => part.length === 0 || part === '.' || part === '..')) {
    throw new Error('transfer_directory_invalid_uri');
  }
  const name: string = path.substring(path.lastIndexOf('/') + 1);
  if (!validName(name)) { throw new Error('transfer_directory_invalid_name'); }
  return { uri: baseUri, path, name };
}
function childUri(base: string, relative: string): string {
  return base + '/' + relative.split('/').map((part: string): string => encodeURIComponent(part)).join('/');
}
function codeOf(error: Error): number {
  return Number((error as BusinessError).code);
}
function unavailable(error: Error): boolean {
  const code: number = codeOf(error);
  return code === 201 || code === 801 || code === 13900001 || code === 13900012 ||
    code === 13900031 || error.message === 'transfer_directory_unsupported_uri' ||
    error.message === 'transfer_directory_authorization_unavailable' ||
    error.message === 'transfer_directory_exclusive_create_unavailable';
}
function diagnostic(error: Error): string {
  if (error.message.startsWith('transfer_directory_')) { return error.message; }
  return unavailable(error) ? 'transfer_directory_authorization_unavailable' : 'transfer_directory_io_failed';
}
function ensureDirectory(info: fileIo.Stat): void {
  if (info.isSymbolicLink() || !info.isDirectory()) { throw new Error('transfer_directory_unsafe_type'); }
}
async function assertDirectories(identities: DirectoryIdentity[], guard: () => boolean): Promise<void> {
  for (const identity of identities) {
    const info: fileIo.Stat = await checked(guard, (): Promise<fileIo.Stat> => fileIo.lstat(identity.path));
    ensureDirectory(info);
    if (info.ino !== identity.ino) { throw new Error('transfer_directory_changed'); }
  }
}

/** Uses only the current Picker grant. No persistence, activation, or permission widening.
 * API 23/26 fileShare.activatePermission requires an already persistent grant;
 * fileIo.lstat/listFile operate on FileUri.path and surface actual access denial.
 * Scan metadata is advisory: stage/opened-FD identity checks remain mandatory.
 */
export async function scanAuthorizedTransferDirectory(uri: string,
  guard: () => boolean): Promise<TransferDirectorySourceTree> {
  const result: TransferDirectorySourceTree = { status: 'failed', rootName: '', entries: [], totalBytes: 0, diagnosticCode: '' };
  try {
    check(guard); const root: SelectedDirectory = selectedDirectory(uri); result.rootName = root.name;
    const rootStat: fileIo.Stat = await checked(guard, (): Promise<fileIo.Stat> => fileIo.lstat(root.path));
    ensureDirectory(rootStat);
    const identities: DirectoryIdentity[] = [{ path: root.path, ino: rootStat.ino }];
    const rootEntry: TransferDirectorySourceEntry = { relativePath: root.name, uri: root.uri,
      name: root.name, directory: true, size: 0, mtime: rootStat.mtime };
    result.entries.push(rootEntry);
    await checked(guard, (): Promise<void> => scanDirectory(root, '', identities, result, guard));
    check(guard); result.status = 'ready'; return result;
  } catch (error) {
    result.status = !current(guard) ? 'cancelled' : unavailable(error as Error) ? 'unavailable' : 'failed';
    result.diagnosticCode = diagnostic(error as Error);
    // An incomplete tree must never be submitted as a complete clipboard offer.
    result.entries = []; result.totalBytes = 0; return result;
  }
}
async function scanDirectory(root: SelectedDirectory, relative: string, ancestors: DirectoryIdentity[],
  result: TransferDirectorySourceTree, guard: () => boolean): Promise<void> {
  await checked(guard, (): Promise<void> => assertDirectories(ancestors, guard));
  const path: string = relative.length === 0 ? root.path : root.path + '/' + relative;
  const names: string[] = await checked(guard, (): Promise<string[]> =>
    fileIo.listFile(path, { recursion: false, listNum: TRANSFER_TREE_MAX_ITEMS + 1 }));
  if (names.length + result.entries.length > TRANSFER_TREE_MAX_ITEMS) { throw new Error('transfer_directory_item_limit'); }
  const keys: Set<string> = new Set<string>();
  for (const name of names) {
    if (!validName(name) || keys.has(key(name))) { throw new Error('transfer_directory_name_collision'); }
    keys.add(key(name));
    const child: string = relative.length === 0 ? name : relative + '/' + name;
    const entryPath: string = root.name + '/' + child; pathParts(entryPath);
    await checked(guard, (): Promise<void> => assertDirectories(ancestors, guard));
    const info: fileIo.Stat = await checked(guard, (): Promise<fileIo.Stat> => fileIo.lstat(root.path + '/' + child));
    if (info.isSymbolicLink() || (!info.isDirectory() && !info.isFile())) { throw new Error('transfer_directory_unsafe_type'); }
    if (!Number.isSafeInteger(info.size) || info.size < 0 || !Number.isFinite(info.mtime)) {
      throw new Error('transfer_directory_invalid_metadata');
    }
    const directory: boolean = info.isDirectory();
    const size: number = directory ? 0 : info.size;
    if (result.totalBytes + size > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_directory_byte_limit'); }
    if (result.entries.length >= TRANSFER_TREE_MAX_ITEMS) { throw new Error('transfer_directory_item_limit'); }
    result.totalBytes += size;
    result.entries.push({ relativePath: entryPath, uri: childUri(root.uri, child), name, directory, size, mtime: info.mtime });
    if (directory) {
      const children: DirectoryIdentity[] = ancestors.concat([{ path: root.path + '/' + child, ino: info.ino }]);
      await checked(guard, (): Promise<void> => scanDirectory(root, child, children, result, guard));
    }
  }
  // Catch a renamed/replaced parent during the last child's asynchronous read.
  await checked(guard, (): Promise<void> => assertDirectories(ancestors, guard));
}

function exportPlan(artifacts: TransferArtifact[]): TreeExportPlan {
  if (artifacts.length === 0 || artifacts.length > TRANSFER_TREE_MAX_ITEMS) { throw new Error('transfer_directory_item_limit'); }
  const plan: TreeExportPlan = { rootName: '', directories: [], files: [], totalBytes: 0 };
  const paths: Map<string, string> = new Map<string, string>();
  const types: Map<string, boolean> = new Map<string, boolean>();
  const explicit: Set<string> = new Set<string>();
  for (const artifact of artifacts) {
    const relative: string = artifact.relativePath ?? artifact.name;
    const parts: string[] = pathParts(relative);
    if (plan.rootName.length === 0) { plan.rootName = parts[0]; }
    if (parts[0] !== plan.rootName || (parts.length === 1 && artifact.directory !== true)) {
      throw new Error('transfer_directory_multiple_roots');
    }
    if (explicit.has(key(relative))) { throw new Error('transfer_directory_name_collision'); }
    explicit.add(key(relative));
    for (let index: number = 1; index <= parts.length; index++) {
      const item: string = parts.slice(0, index).join('/'); const normalized: string = key(item);
      const directory: boolean = index < parts.length || artifact.directory === true;
      if (paths.has(normalized) && (paths.get(normalized) !== item || types.get(normalized) !== directory)) {
        throw new Error('transfer_directory_name_collision');
      }
      paths.set(normalized, item); types.set(normalized, directory);
    }
    if (artifact.directory !== true) {
      if (!Number.isSafeInteger(artifact.size) || artifact.size < 0) { throw new Error('transfer_directory_invalid_metadata'); }
      plan.totalBytes += artifact.size; plan.files.push(artifact);
      if (plan.totalBytes > TRANSFER_FILE_LIMIT_BYTES) { throw new Error('transfer_directory_byte_limit'); }
    }
  }
  if (paths.size > TRANSFER_TREE_MAX_ITEMS) { throw new Error('transfer_directory_item_limit'); }
  paths.forEach((path: string, normalized: string): void => { if (types.get(normalized) === true) { plan.directories.push(path); } });
  plan.directories.sort((left: string, right: string): number => left.split('/').length - right.split('/').length);
  return plan;
}
/** Creates a separate root via native mkdirat/openat. All descendant creation
 * stays anchored to that owned FD with NOFOLLOW and exclusive file creation.
 * Picker paths/URIs are used for display and location checks, never reopened as
 * destination files. A moved destination retains its bytes but loses a known URI.
 */
export async function exportTransferArtifactTree(artifacts: TransferArtifact[], selectedFolderUri: string,
  guard: () => boolean, progress: (written: number, total: number) => void): Promise<TransferDirectoryExportResult> {
  const result: TransferDirectoryExportResult = { status: 'failed', rootName: '', destinationUri: '', entries: [],
    writtenBytes: 0, evidence: 'none', diagnosticCode: '' };
  const holders: TransferArtifactBatch[] = [];
  const holder: string = 'tree-export:' + Date.now().toString() + ':' + Math.random().toString();
  const identities: DirectoryIdentity[] = [];
  let selectedFile: fileIo.File | null = null;
  let rootFd: number = -1;
  let created: boolean = false;
  let planReady: boolean = false;
  let addressUnknown: boolean = false;
  let activeRelative: string = '';
  const observeLocations = (): void => {
    for (const identity of identities) {
      try {
        const info: fileIo.Stat = fileIo.lstatSync(identity.path);
        if (info.isSymbolicLink() || !info.isDirectory() || info.ino !== identity.ino) { addressUnknown = true; }
      } catch (_error) { addressUnknown = true; }
    }
  };
  try {
    check(guard); const plan: TreeExportPlan = exportPlan(artifacts); planReady = true;
    // Keep the complete source tree alive throughout all per-file exports.
    for (const artifact of artifacts) {
      const owner: TransferArtifactBatch | null = TransferArtifactBatch.owner(artifact);
      if (owner === null) { throw new Error('transfer_directory_unowned_source'); }
      if (holders.indexOf(owner) < 0) { owner.retain(holder); holders.push(owner); }
    }
    const selected: SelectedDirectory = selectedDirectory(selectedFolderUri);
    check(guard);
    // Capture the handle before the post-await guard, including cancellation.
    selectedFile = await fileIo.open(selectedFolderUri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    check(guard);
    const selectedFd: number = selectedFile.fd;
    const selectedStat: fileIo.Stat = await checked(guard, (): Promise<fileIo.Stat> => fileIo.stat(selectedFd));
    ensureDirectory(selectedStat); identities.push({ path: selected.path, ino: selectedStat.ino });
    const existing: string[] = await checked(guard, (): Promise<string[]> =>
      fileIo.listFile(selected.path, { recursion: false, listNum: 10001 }));
    if (existing.length > 10000) { throw new Error('transfer_directory_destination_too_large'); }
    const occupied: Set<string> = new Set<string>(existing.map((name: string): string => key(name)));
    const loader: ExtensionLoader = ExtensionLoader.getInstance();
    for (let suffix: number = 0; suffix < TRANSFER_TREE_MAX_ITEMS; suffix++) {
      check(guard);
      const candidate: string = suffix === 0 ? plan.rootName : plan.rootName + ' (' + suffix.toString() + ')';
      if (!validName(candidate) || occupied.has(key(candidate))) { continue; }
      rootFd = loader.openExclusiveTransferDirectory(selectedFd, candidate);
      if (rootFd < 0) {
        check(guard);
        // A concurrent name collision is safe to skip. A missing candidate after
        // a rejected native create proves this grant cannot create the root.
        try {
          fileIo.lstatSync(selected.path + '/' + candidate); occupied.add(key(candidate)); continue;
        } catch (_error) { throw new Error('transfer_directory_exclusive_create_unavailable'); }
      }
      created = true; result.rootName = candidate; result.destinationUri = childUri(selected.uri, candidate);
      check(guard); break;
    }
    if (!created) { throw new Error('transfer_directory_name_exhausted'); }
    const outputRoot: string = selected.path + '/' + result.rootName;
    const rootInfo: fileIo.Stat = fileIo.statSync(rootFd); ensureDirectory(rootInfo);
    identities.push({ path: outputRoot, ino: rootInfo.ino }); observeLocations();
    for (const directory of plan.directories) {
      activeRelative = directory;
      const suffix: string = directory.substring(plan.rootName.length + 1);
      if (suffix.length > 0) {
        check(guard);
        if (!loader.ensureTransferExportDirectory(rootFd, suffix)) { throw new Error('transfer_directory_exclusive_create_failed'); }
        check(guard);
        try {
          const info: fileIo.Stat = fileIo.lstatSync(outputRoot + '/' + suffix); ensureDirectory(info);
          identities.push({ path: outputRoot + '/' + suffix, ino: info.ino });
        } catch (_error) { addressUnknown = true; }
      }
      result.entries.push({ relativePath: directory, destinationUri: suffix.length > 0 ? childUri(result.destinationUri, suffix) : result.destinationUri,
        directory: true, status: 'saved', writtenBytes: 0, evidence: 'directoryCreated', diagnosticCode: '' });
      result.evidence = 'directoriesCreated';
    }
    for (const artifact of plan.files) {
      const relative: string = artifact.relativePath ?? artifact.name; activeRelative = relative;
      const suffix: string = relative.substring(plan.rootName.length + 1);
      const uri: string = childUri(result.destinationUri, suffix);
      check(guard); observeLocations();
      let targetFd: number = -1;
      let fileResult: TransferArtifactExportResult | null = null;
      try {
        targetFd = loader.openExclusiveTransferFile(rootFd, suffix);
        if (targetFd < 0) { throw new Error('transfer_directory_exclusive_file_unavailable'); }
        check(guard);
        fileResult = await exportTransferArtifactToFd(artifact, targetFd, guard,
          (written: number, _total: number): void => { if (current(guard)) { try { progress(result.writtenBytes + written, plan.totalBytes); } catch (_error) {} } });
        // Preserve the result before observing a cancelled lease after await.
        result.entries.push({ relativePath: relative, destinationUri: uri, directory: false,
          status: !current(guard) && fileResult.status === 'saved' ? 'commitUnknown' : fileResult.status,
          writtenBytes: fileResult.writtenBytes, evidence: fileResult.evidence, diagnosticCode: fileResult.diagnosticCode });
        result.writtenBytes += fileResult.writtenBytes;
      } finally {
        if (targetFd >= 0) {
          try { fileIo.closeSync(targetFd); } catch (_error) {
            addressUnknown = true;
            if (fileResult !== null) { fileResult.status = 'commitUnknown'; fileResult.diagnosticCode = 'transfer_directory_close_unknown'; }
          }
        }
      }
      check(guard); observeLocations();
      if (fileResult === null || fileResult.status !== 'saved') {
        result.status = fileResult !== null && fileResult.status === 'commitUnknown' ? 'commitUnknown' : 'partial';
        result.diagnosticCode = fileResult === null ? 'transfer_directory_export_failed' : fileResult.diagnosticCode;
        result.evidence = 'partial'; return result;
      }
    }
    check(guard); observeLocations();
    result.status = 'saved'; result.evidence = plan.files.length > 0 ? 'writtenAndSynced' : 'directoriesCreated'; return result;
  } catch (error) {
    result.status = created ? (!current(guard) ? 'cancelled' : 'partial') :
      !current(guard) ? 'cancelled' : unavailable(error as Error) ? 'unavailable' : 'failed';
    if (result.entries.some((entry: TransferDirectoryExportEntry): boolean => entry.status === 'commitUnknown')) {
      result.status = 'commitUnknown';
    }
    result.evidence = created ? 'partial' : 'none'; result.diagnosticCode = diagnostic(error as Error); return result;
  } finally {
    if (rootFd >= 0) { try { fileIo.closeSync(rootFd); } catch (_error) { addressUnknown = true; } }
    if (selectedFile !== null) { try { fileIo.closeSync(selectedFile); } catch (_error) { /* Read-only grant FD already handed to native only synchronously. */ } }
    if (created) { observeLocations(); }
    if (planReady) {
      for (const artifact of artifacts) {
        const relative: string = artifact.relativePath ?? artifact.name;
        if (!result.entries.some((entry: TransferDirectoryExportEntry): boolean => entry.relativePath === relative)) {
          const active: boolean = relative === activeRelative;
          result.entries.push({ relativePath: relative, destinationUri: '', directory: artifact.directory === true,
            status: active ? (!current(guard) ? 'cancelled' : 'failed') : 'skipped', writtenBytes: 0, evidence: 'none',
            diagnosticCode: active ? result.diagnosticCode : 'transfer_directory_not_attempted' });
        }
      }
    }
    if (created && addressUnknown) {
      result.status = 'commitUnknown'; result.destinationUri = '';
      result.diagnosticCode = 'transfer_directory_destination_location_unknown';
      for (const entry of result.entries) {
        entry.destinationUri = '';
        if (entry.status === 'saved') { entry.status = 'commitUnknown'; }
      }
    }
    for (const owner of holders) { try { owner.release(holder); } catch (_error) { /* Keep a failed durable release conservative. */ } }
  }
}
