import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AiAccess } from './AiAccess';
import { AiHost, AiSettings, aiHostError, aiSettingsValid } from './AiModels';
import { AiLocalStore } from './AiLocalStore';
import { AiLifecycle } from './AiLifecycle';
import { AiTransport, aiRandomId } from './AiTransport';

interface AiPortableConfig { version: number; hosts: AiHost[]; settings: AiSettings; }
/** Explicit metadata transfer. Always creates new unpaired records on import. */
export class AiDataTransfer {
  static async exportConfig(): Promise<boolean> {
    const account = AiAccess.getInstance().capture(); const store = AiLocalStore.getInstance();
    const document: AiPortableConfig = { version: 1, hosts: await store.hosts(account), settings: await store.settings(account) };
    // Strip account identity from the portable view; no certificate/key query occurs.
    document.hosts.forEach((host: AiHost): void => { host.owner = ''; host.revision = 0; host.lastConnected = 0; });
    const data = new util.TextEncoder().encodeInto(JSON.stringify(document, null, 2));
    const paths = await new picker.DocumentViewPicker().save({ newFileNames: ['RemoteDesk-AI.json'] });
    AiAccess.getInstance().assertCurrent(account);
    if (paths.length !== 1) { return false; }
    const file = fileIo.openSync(paths[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { if (fileIo.writeSync(file.fd, data.buffer) !== data.length) { throw new Error('AI_EXPORT_FAILED'); } }
    finally { fileIo.closeSync(file); }
    return true;
  }
  static async importConfig(): Promise<number> {
    const access = AiAccess.getInstance(); const account = access.capture();
    const paths = await new picker.DocumentViewPicker().select({ maxSelectNumber: 1, fileSuffixFilters: ['AI 配置|.json'] });
    access.assertCurrent(account); if (paths.length !== 1) { return 0; }
    const file = fileIo.openSync(paths[0], fileIo.OpenMode.READ_ONLY); let text = '';
    try {
      const size = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > 1024 * 1024) { throw new Error('AI_IMPORT_INVALID'); }
      const data = new Uint8Array(size);
      if (fileIo.readSync(file.fd, data.buffer) !== size) { throw new Error('AI_IMPORT_INVALID'); }
      text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(data);
    } finally { fileIo.closeSync(file); }
    const document = JSON.parse(text) as AiPortableConfig;
    if (document.version !== 1 || !Array.isArray(document.hosts) || document.hosts.length > 256 ||
      !aiSettingsValid(document.settings)) { throw new Error('AI_IMPORT_INVALID'); }
    const hosts: AiHost[] = [];
    for (const row of document.hosts) {
      // Explicit fields: imported properties can never reach the private identity column.
      const host: AiHost = { id: aiRandomId(), owner: account.owner, revision: 0, label: row.label,
        backend: row.backend, address: row.address, port: row.port, serverName: row.serverName,
        groupId: row.groupId, sortOrder: row.sortOrder, lastConnected: 0, createdAt: Date.now(),
        transport: row.transport, relayHostId: '', projectId: '' };
      if (aiHostError(host) !== '') { throw new Error('AI_IMPORT_INVALID'); } hosts.push(host);
    }
    access.assertCurrent(account);
    const finish = AiLifecycle.beginRestore();
    const restoreEpoch = AiLifecycle.generation();
    try {
      if (!(await AiTransport.drain())) { throw new Error('AI_RESTORE_DRAIN_FAILED'); }
      if (AiLifecycle.generation() !== restoreEpoch) { throw new Error('AI_ACCOUNT_CHANGED'); }
    } finally { finish(); }
    const fresh = access.capture();
    if (fresh.owner !== account.owner || fresh.generation !== account.generation) { throw new Error('AI_ACCOUNT_CHANGED'); }
    await AiLocalStore.getInstance().importHosts(fresh, hosts, document.settings);
    return hosts.length;
  }
}
