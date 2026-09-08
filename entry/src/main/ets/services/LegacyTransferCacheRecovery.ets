import { fileIo, fileUri } from '@kit.CoreFileKit';
import { TransferArtifact, TransferArtifactBatch } from './TransferArtifactStore';
import { scanAuthorizedTransferDirectory, TransferDirectorySourceEntry, TransferDirectorySourceTree,
  TRANSFER_TREE_MAX_ITEMS } from './TransferDirectoryProvider';

export interface LegacyTransferCacheSummary {
  key: string;
  name: string;
  fileCount: number;
  totalBytes: number;
  available: boolean;
  diagnosticCode: string;
}
interface LegacyDirectoryIdentity { path: string; ino: bigint; }

function current(guard: () => boolean): boolean { try { return guard(); } catch (_error) { return false; } }
function check(guard: () => boolean): void { if (!current(guard)) { throw new Error('legacy_cache_cancelled'); } }
function legacyName(name: string): boolean { return /^rdp_transfer(?:_[A-Za-z0-9_]{1,20})?$/.test(name); }
function sandboxPath(filesDir: string): string {
  const root: string = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
  if (!root.startsWith('/') || root.length > 4096 || root.indexOf('\u0000') >= 0 || root.indexOf('\\') >= 0 ||
    root.split('/').slice(1).some((part: string): boolean => part.length === 0 || part === '.' || part === '..')) {
    throw new Error('legacy_cache_invalid_sandbox');
  }
  return root;
}
function directory(path: string): LegacyDirectoryIdentity {
  const info: fileIo.Stat = fileIo.lstatSync(path);
  if (info.isSymbolicLink() || !info.isDirectory()) { throw new Error('legacy_cache_unsafe_type'); }
  return { path, ino: info.ino };
}
function sameDirectory(identity: LegacyDirectoryIdentity): boolean {
  try {
    const info: fileIo.Stat = fileIo.lstatSync(identity.path);
    return !info.isSymbolicLink() && info.isDirectory() && info.ino === identity.ino;
  } catch (_error) { return false; }
}
function diagnostic(error: Error): string {
  return error.message.startsWith('legacy_cache_') ? error.message : 'legacy_cache_unavailable';
}

/** Only call from the explicit recovery entrance. No module/init/startup scan,
 * ownership inference, persistence, automatic import, or cleanup occurs here.
 * The name is the entire key; it never contains a path or an account identity.
 */
export async function listLegacyTransferCaches(filesDir: string,
  guard: () => boolean = (): boolean => true): Promise<LegacyTransferCacheSummary[]> {
  check(guard);
  const base: LegacyDirectoryIdentity = directory(sandboxPath(filesDir));
  const active: () => boolean = (): boolean => current(guard) && sameDirectory(base);
  check(active);
  const names: string[] = await fileIo.listFile(base.path,
    { recursion: false, listNum: TRANSFER_TREE_MAX_ITEMS + 1 });
  check(active);
  if (names.length > TRANSFER_TREE_MAX_ITEMS) { throw new Error('legacy_cache_directory_limit'); }
  const matches: string[] = names.filter((name: string): boolean => legacyName(name)).sort();
  const summaries: LegacyTransferCacheSummary[] = [];
  for (const name of matches) {
    check(active);
    const summary: LegacyTransferCacheSummary = { key: name, name, fileCount: 0, totalBytes: 0,
      available: false, diagnosticCode: '' };
    try {
      const candidate: LegacyDirectoryIdentity = directory(base.path + '/' + name);
      const unchanged: () => boolean = (): boolean => active() && sameDirectory(candidate);
      check(unchanged);
      // Only sandbox paths are converted; no synthetic document-provider grant.
      const tree: TransferDirectorySourceTree = await scanAuthorizedTransferDirectory(
        fileUri.getUriFromPath(candidate.path), unchanged);
      check(active);
      if (!sameDirectory(candidate)) { throw new Error('legacy_cache_changed'); }
      if (tree.status === 'ready') {
        summary.fileCount = tree.entries.filter((entry: TransferDirectorySourceEntry): boolean => !entry.directory).length;
        summary.totalBytes = tree.totalBytes;
        summary.available = true;
      } else {
        summary.diagnosticCode = tree.diagnosticCode.length > 0 ? tree.diagnosticCode : 'legacy_cache_unavailable';
      }
    } catch (error) {
      check(active);
      summary.diagnosticCode = diagnostic(error as Error);
    }
    summaries.push(summary);
  }
  check(active);
  return summaries;
}

/** The user selects exactly one old root and the caller creates the current
 * account's target batch. Rescan before copying; never trust preview counts.
 * Both the scanner and stageLocalDirectoryTree enforce depth/item/byte limits
 * and source identity checks. The legacy source is never removed or published.
 */
export async function importLegacyTransferCache(filesDir: string, key: string,
  targetBatch: TransferArtifactBatch, guard: () => boolean,
  progress: (copied: number, total: number) => void): Promise<TransferArtifact[]> {
  check(guard);
  if (!legacyName(key)) { throw new Error('legacy_cache_invalid_key'); }
  const base: LegacyDirectoryIdentity = directory(sandboxPath(filesDir));
  check(guard);
  const selected: LegacyDirectoryIdentity = directory(base.path + '/' + key);
  const active: () => boolean = (): boolean => current(guard) && sameDirectory(base) && sameDirectory(selected);
  check(active);
  const tree: TransferDirectorySourceTree = await scanAuthorizedTransferDirectory(
    fileUri.getUriFromPath(selected.path), active);
  check(active);
  if (tree.status !== 'ready' || tree.rootName !== key) {
    throw new Error(tree.diagnosticCode.length > 0 ? tree.diagnosticCode : 'legacy_cache_unavailable');
  }
  const artifacts: TransferArtifact[] = await targetBatch.stageLocalDirectoryTree(tree.entries, active,
    (copied: number, total: number): void => {
      if (active()) { try { progress(copied, total); } catch (_error) { /* Observer failure does not alter copied bytes. */ } }
    });
  check(active);
  return artifacts;
}
