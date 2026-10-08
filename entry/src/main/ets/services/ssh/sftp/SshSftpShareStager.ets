import { fileIo, fileUri, statfs } from '@kit.CoreFileKit';
import { SshSftpTreeItem } from '../../SshSftpBatchPolicy';
import { KNOCK_MAX_FILES, KNOCK_SPACE_RESERVE, knockFileSizeAllowed,
  knockRelativePath } from '../../pro/ProKnockPolicy';

interface ShareSource { path: string; name: string; size: number; mtime: number; mode: number; }

/** Copies completed Share Kit files into a durable, batch-owned sandbox source.
 * All paths are inspected before opening any source; every chunk rechecks its
 * session lease. The destination is a newly created private batch directory. */
export class SshSftpShareStager {
  private async source(root: string, uri: string): Promise<ShareSource> {
    const path: string = uri.indexOf('://') < 0 ? uri : new fileUri.FileUri(uri).path;
    const relative: string | null = knockRelativePath(root, path);
    if (relative === null) { throw new Error('接收文件路径无效'); }
    const parts: string[] = relative.split('/');
    let current: string = root;
    let info: fileIo.Stat = await fileIo.lstat(root);
    if (!info.isDirectory() || info.isSymbolicLink()) { throw new Error('接收目录无效'); }
    for (let index: number = 0; index < parts.length; index++) {
      current += '/' + parts[index];
      info = await fileIo.lstat(current);
      if (info.isSymbolicLink() || (index < parts.length - 1 && !info.isDirectory())) {
        throw new Error('不支持链接或特殊文件');
      }
    }
    if (!info.isFile() || !knockFileSizeAllowed(info.size, 0)) {
      throw new Error('文件类型或大小不受支持');
    }
    return { path, name: parts[parts.length - 1], size: info.size, mtime: info.mtime, mode: info.mode };
  }
  private uniqueName(name: string, used: string[]): string {
    // SFTP's local provider normalizes each path segment with trim(). Use the
    // same normalized name before both writing and enqueuing the file.
    const normalized: string = name.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').trim().substring(0, 180).trim();
    const base: string = normalized.length > 0 ? normalized : 'received-file';
    let candidate: string = base;
    let sequence: number = 1;
    while (used.indexOf(candidate) >= 0) { candidate = base + ' (' + (sequence++).toString() + ')'; }
    used.push(candidate);
    return candidate;
  }
  async stage(uris: string[], sourceRoot: string, destination: string,
    isCurrent: () => boolean): Promise<SshSftpTreeItem[]> {
    if (uris.length === 0 || uris.length > KNOCK_MAX_FILES || !isCurrent()) {
      throw new Error('接收已取消或文件数量超限');
    }
    const destinationInfo: fileIo.Stat = await fileIo.lstat(destination);
    if (!destinationInfo.isDirectory() || destinationInfo.isSymbolicLink() ||
      (await fileIo.listFile(destination)).length !== 0) { throw new Error('上传暂存目录无效'); }
    const sources: ShareSource[] = [];
    let total: number = 0;
    for (let index: number = 0; index < uris.length; index++) {
      if (!isCurrent()) { throw new Error('接收已取消'); }
      const source: ShareSource = await this.source(sourceRoot, uris[index]);
      if (!knockFileSizeAllowed(source.size, total)) { throw new Error('单批文件总量不能超过 512 MB'); }
      total += source.size;
      sources.push(source);
    }
    if (await statfs.getFreeSize(destination) < total + KNOCK_SPACE_RESERVE) {
      throw new Error('本机暂存空间不足');
    }
    const items: SshSftpTreeItem[] = [];
    const used: string[] = [];
    for (let index: number = 0; index < sources.length; index++) {
      if (!isCurrent()) { throw new Error('接收已取消'); }
      const source: ShareSource = sources[index];
      const name: string = this.uniqueName(source.name, used);
      let input: fileIo.File | null = null;
      let output: fileIo.File | null = null;
      try {
        // Revalidate every path component after asynchronous inspection.
        const current: ShareSource = await this.source(sourceRoot, source.path);
        if (current.size !== source.size || current.mtime !== source.mtime || !isCurrent()) {
          throw new Error('接收文件已变化');
        }
        input = fileIo.openSync(source.path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
        const opened: fileIo.Stat = fileIo.statSync(input.fd);
        if (!opened.isFile() || opened.size !== source.size || opened.mtime !== source.mtime) {
          throw new Error('接收文件已变化');
        }
        output = fileIo.openSync(destination + '/' + name,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
        let copied: number = 0;
        while (copied < source.size) {
          if (!isCurrent()) { throw new Error('接收已取消'); }
          const block: ArrayBuffer = new ArrayBuffer(Math.min(64 * 1024, source.size - copied));
          const read: number = await fileIo.read(input.fd, block);
          if (read <= 0) { throw new Error('接收文件不完整'); }
          let written: number = 0;
          while (written < read) {
            if (!isCurrent()) { throw new Error('接收已取消'); }
            const count: number = await fileIo.write(output.fd, block.slice(written, read));
            if (count <= 0) { throw new Error('本机暂存写入失败'); }
            written += count;
          }
          copied += read;
        }
        const finalSource: fileIo.Stat = fileIo.statSync(input.fd);
        if (finalSource.size !== source.size || finalSource.mtime !== source.mtime || !isCurrent()) {
          throw new Error('接收文件已变化');
        }
        fileIo.fsyncSync(output.fd);
        const finalFile: fileIo.Stat = fileIo.statSync(output.fd);
        if (finalFile.size !== source.size) { throw new Error('本机暂存校验失败'); }
        items.push({ relativePath: name, name, isDirectory: false, isSymbolicLink: false,
          isSpecialFile: false, size: finalFile.size, mtime: finalFile.mtime, mode: finalFile.mode,
          uid: -1, gid: -1 });
      } finally {
        if (input !== null) { try { fileIo.closeSync(input); } catch (_err) { /* close best effort */ } }
        if (output !== null) { try { fileIo.closeSync(output); } catch (_err) { /* close best effort */ } }
      }
    }
    return items;
  }
}
