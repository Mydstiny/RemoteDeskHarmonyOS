import { common } from '@kit.AbilityKit';
import { RemoteHost } from '../../model/RemoteHost';
import { AiAccess, AiAccountLease } from './AiAccess';
import { AiLocalStore } from './AiLocalStore';
import { AiBackend, AiHost, AiSettings, aiBackendName, aiRemoteSettingChanged, aiRemoteSettingValue } from './AiModels';

export function projectAiHost(ai: AiHost): RemoteHost {
  const host = new RemoteHost();
  host.id = 'ai:' + ai.id; host.label = ai.label; host.protocol = 'ai';
  host.host = ai.address; host.port = ai.port; host.username = aiBackendName(ai.backend);
  host.groupId = ai.groupId; host.sortOrder = ai.sortOrder; host.lastConnected = ai.lastConnected;
  return host;
}
export function aiHostId(host: RemoteHost): string {
  return host.protocol === 'ai' && host.id.startsWith('ai:') ? host.id.slice(3) : '';
}
export class AiHostService {
  private static instance: AiHostService;
  private hosts: AiHost[] = [];
  private revision: number = 0;
  /** 远程 AI 设置 as last read, and whose they are (the AI 助理 reads and changes a few of them). */
  private settings: AiSettings | null = null;
  private settingsOwner: string = '';
  private context: common.Context | null = null;
  static getInstance(): AiHostService {
    if (!AiHostService.instance) { AiHostService.instance = new AiHostService(); }
    return AiHostService.instance;
  }
  clear(): void { this.revision++; this.hosts = []; this.settings = null; this.settingsOwner = ''; }
  async refresh(context: common.Context): Promise<void> {
    const revision = ++this.revision;
    this.context = context;
    if (!AiAccess.getInstance().proVisible()) { this.hosts = []; this.settings = null; return; }
    try {
      const account = AiAccess.getInstance().capture();
      await AiLocalStore.getInstance().initialize(context);
      const hosts = await AiLocalStore.getInstance().hosts(account);
      if (revision === this.revision && AiAccess.getInstance().proVisible() && AiAccess.getInstance().current(account)) {
        this.hosts = hosts;
      } else if (revision === this.revision && !AiAccess.getInstance().proVisible()) {
        this.hosts = [];
      }
    } catch (_error) { if (revision === this.revision) { this.hosts = []; } }
    // Apart from the hosts: unreadable settings must not empty the host list.
    try {
      const account = AiAccess.getInstance().capture();
      const settings = await AiLocalStore.getInstance().settings(account);
      if (revision === this.revision && AiAccess.getInstance().current(account)) {
        this.settings = settings; this.settingsOwner = account.owner;
      }
    } catch (_error) { if (revision === this.revision) { this.settings = null; } }
  }
  /** A 远程 AI setting of the current account as the AI 助理's catalog value, or null before it was read. */
  remoteSetting(id: string): string | null {
    const settings: AiSettings | null = this.ownSettings();
    return settings === null ? null : aiRemoteSettingValue(settings, id);
  }
  /**
   * The AI 助理 changes a 远程 AI setting (界面风格, 显示工具执行过程, 回到前台后恢复查看, 默认 AI, 文字大小) for the current account, as
   * 设置 → 远程 AI saves it: only that field, on what is stored at that moment (another change made meanwhile stays).
   * False when it cannot be changed now (no access, not read yet, or not one of those); `onFailed` when the save fails.
   */
  applyRemoteSetting(id: string, value: string, onFailed: () => void = (): void => {}): boolean {
    const settings: AiSettings | null = this.ownSettings();
    if (settings === null || aiRemoteSettingChanged(settings, id, value) === null) { return false; }
    // Like the cards in 设置 → 远程 AI: a default AI the account cannot use is not offered.
    if (id === 'remoteAi.defaultBackend' && !AiAccess.getInstance().executable(value as AiBackend)) { return false; }
    let account: AiAccountLease;
    try { account = AiAccess.getInstance().capture(); } catch (_error) { return false; }
    // Shown at once; what the store keeps replaces it.
    this.settings = aiRemoteSettingChanged(settings, id, value); this.settingsOwner = account.owner;
    AiLocalStore.getInstance().updateSettings(account, (stored: AiSettings): AiSettings | null =>
      aiRemoteSettingChanged(stored, id, value)).then((saved: AiSettings): void => {
      if (AiAccess.getInstance().current(account)) { this.settings = saved; this.settingsOwner = account.owner; }
    }).catch((): void => {
      // Not saved: show what is stored again, and say so.
      const context: common.Context | null = this.context;
      if (context !== null) { void this.refresh(context); }
      onFailed();
    });
    return true;
  }
  private ownSettings(): AiSettings | null {
    try {
      if (!AiAccess.getInstance().proVisible() || this.settings === null) { return null; }
      return AiAccess.getInstance().capture().owner === this.settingsOwner ?
        JSON.parse(JSON.stringify(this.settings)) as AiSettings : null;
    } catch (_error) { return null; }
  }
  list(): AiHost[] {
    try {
      if (!AiAccess.getInstance().proVisible()) { return []; }
      const owner = AiAccess.getInstance().capture().owner;
      return this.hosts.filter((host: AiHost): boolean => host.owner === owner)
        .map((host: AiHost): AiHost => JSON.parse(JSON.stringify(host)) as AiHost);
    } catch (_error) { return []; }
  }
  find(id: string): AiHost | null { return this.list().find((host: AiHost): boolean => host.id === id) ?? null; }
}
