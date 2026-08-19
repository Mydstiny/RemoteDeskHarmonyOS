import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import {
  planSshSftpExternalDrop,
  sshSftpDropRecordCountAllowed,
  SshSftpDropItem,
  SshSftpDropLimits,
  SshSftpDropRejectReason
} from './SshSftpWorkspacePolicy';
import { SshSftpTreeItem } from '../../SshSftpBatchPolicy';

const COPY_CHUNK_BYTES: number = 64 * 1024;

export interface SshSftpStagedDropResult {
  accepted: boolean;
  reason: SshSftpDropRejectReason;
  stagedFiles: Array<SshSftpTreeItem>;
  copiedBytes: number;
}

interface SshSftpDropSource {
  item: SshSftpDropItem;
  mode: number;
  mtime: number;
}

function rejected(reason: SshSftpDropRejectReason): SshSftpStagedDropResult {
  return { accepted: false, reason, stagedFiles: [], copiedBytes: 0 };
}

function safeName(value: string, index: number): string {
  const normalized: string = value.replace(/\\/g, '/');
  const slash: number = normalized.lastIndexOf('/');
  const base: string = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  const cleaned: string = base.replace(/[\\/:*?"<>|]/g, '_').trim();
  const fallback: string = 'drop-' + (index + 1).toString() + '.bin';
  return (cleaned.length > 0 ? cleaned : fallback).substring(0, 220);
}

function statNumber(info: Object, key: string, fallback: number): number {
  const raw: Record<string, Object> = info as Record<string, Object>;
  const value: Object = raw[key];
  return typeof value === 'number' && Number.isFinite(value as number)
    ? value as number : fallback;
}

/**
 * UDMF-to-Core-File-Kit bridge. URI grants live only for this call; files are
 * copied into a provider-owned staging directory before durable tasks exist.
 */
export class SshSftpDropAdapter {
  private async yieldTurn(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
  }

  private sources(records: Array<unifiedDataChannel.UnifiedRecord>): Array<SshSftpDropSource> {
    const result: Array<SshSftpDropSource> = [];
    for (let index: number = 0; index < records.length; index++) {
      const entry: uniformDataStruct.FileUri = records[index].getEntry(
        uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
      const uri: string = entry && entry.oriUri ? entry.oriUri.trim() : '';
      if (uri.length === 0) {
        result.push({
          item: { uri: '', name: '', size: -1, isDirectory: false,
            isSymbolicLink: false, isSpecialFile: false, readable: false },
          mode: 0, mtime: -1
        });
        continue;
      }
      let file: fileIo.File | null = null;
      try {
        file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        const info: Object = fileIo.statSync(file.fd) as Object;
        const mode: number = statNumber(info, 'mode', 0);
        const typeBits: number = mode & 0xF000;
        const isDirectory: boolean = typeBits === 0x4000;
        const isSymbolicLink: boolean = typeBits === 0xA000;
        const isSpecialFile: boolean = typeBits !== 0 && typeBits !== 0x8000 &&
          !isDirectory && !isSymbolicLink;
        result.push({
          item: {
            uri,
            name: safeName(uri, index),
            size: statNumber(info, 'size', -1),
            isDirectory,
            isSymbolicLink,
            isSpecialFile,
            readable: true
          },
          mode,
          mtime: statNumber(info, 'mtime', -1)
        });
      } catch (_err) {
        result.push({
          item: { uri, name: safeName(uri, index), size: -1, isDirectory: false,
            isSymbolicLink: false, isSpecialFile: false, readable: false },
          mode: 0, mtime: -1
        });
      } finally {
        if (file !== null) {
          try { fileIo.closeSync(file); } catch (_err) { /* best effort */ }
        }
      }
    }
    return result;
  }

  private uniqueName(base: string, used: Array<string>): string {
    let candidate: string = base;
    let suffix: number = 1;
    while (used.indexOf(candidate) >= 0) {
      const dot: number = base.lastIndexOf('.');
      const stem: string = dot > 0 ? base.substring(0, dot) : base;
      const extension: string = dot > 0 ? base.substring(dot) : '';
      candidate = stem.substring(0, 200) + ' (' + suffix.toString() + ')' + extension;
      suffix++;
    }
    used.push(candidate);
    return candidate;
  }

  private async copy(sourceUri: string, targetPath: string, expectedSize: number): Promise<boolean> {
    let source: fileIo.File | null = null;
    let target: fileIo.File | null = null;
    let copied: number = 0;
    try {
      source = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      target = fileIo.openSync(targetPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      while (copied < expectedSize) {
        const blockSize: number = Math.min(COPY_CHUNK_BYTES, expectedSize - copied);
        const block: ArrayBuffer = new ArrayBuffer(blockSize);
        const read: number = fileIo.readSync(source.fd, block);
        if (read <= 0) { return false; }
        const payload: ArrayBuffer = read === blockSize ? block : block.slice(0, read);
        if (fileIo.writeSync(target.fd, payload) !== read) { return false; }
        copied += read;
        await this.yieldTurn();
      }
      return copied === expectedSize;
    } catch (_err) {
      return false;
    } finally {
      if (source !== null) { try { fileIo.closeSync(source); } catch (_err) { /* best effort */ } }
      if (target !== null) { try { fileIo.closeSync(target); } catch (_err) { /* best effort */ } }
    }
  }

  async stage(data: unifiedDataChannel.UnifiedData, destinationDirectory: string,
    limits: SshSftpDropLimits): Promise<SshSftpStagedDropResult> {
    const destination: string = destinationDirectory.trim().replace(/\/+$/g, '');
    if (destination.length === 0) { return rejected('target-unavailable'); }
    const records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
    // Bound work before getEntry/open/stat touches any external URI.
    if (!sshSftpDropRecordCountAllowed(records.length, limits.maxItems)) {
      return rejected('too-many-items');
    }
    const sources: Array<SshSftpDropSource> = this.sources(records);
    const items: Array<SshSftpDropItem> = sources.map(
      (source: SshSftpDropSource): SshSftpDropItem => source.item);
    const plan = planSshSftpExternalDrop(items, 'ssh', true, false, limits);
    if (!plan.accepted) { return rejected(plan.reason); }
    // Directory grants require recursive token handling; fail closed until the
    // provider can prove every descendant belongs to the same grant.
    if (plan.containsDirectory) { return rejected('unsupported-file-type'); }
    const staged: Array<SshSftpTreeItem> = [];
    const createdPaths: Array<string> = [];
    const usedNames: Array<string> = [];
    let copiedBytes: number = 0;
    for (let index: number = 0; index < sources.length; index++) {
      const source: SshSftpDropSource = sources[index];
      const name: string = this.uniqueName(source.item.name, usedNames);
      const target: string = destination + '/' + name;
      if (!await this.copy(source.item.uri, target, source.item.size)) {
        for (let cleanupIndex: number = 0; cleanupIndex < createdPaths.length; cleanupIndex++) {
          try { await fileIo.unlink(createdPaths[cleanupIndex]); } catch (_err) { /* best effort */ }
        }
        try { await fileIo.unlink(target); } catch (_err) { /* best effort */ }
        return rejected('permission-denied');
      }
      createdPaths.push(target);
      copiedBytes += source.item.size;
      staged.push({
        relativePath: name,
        name,
        isDirectory: false,
        isSymbolicLink: false,
        isSpecialFile: false,
        size: source.item.size,
        mtime: source.mtime,
        mode: source.mode,
        uid: -1,
        gid: -1
      });
    }
    return { accepted: true, reason: '', stagedFiles: staged, copiedBytes };
  }
}
