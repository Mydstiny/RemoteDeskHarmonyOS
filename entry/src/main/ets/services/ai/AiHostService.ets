import { common } from '@kit.AbilityKit';
import { RemoteHost } from '../../model/RemoteHost';
import { AiAccess, AiAccountLease } from './AiAccess';
import { AiLocalStore } from './AiLocalStore';
import { AiHost, AiSettings, aiBackendName, aiRemoteSettingChanged, aiRemoteSettingValue } from './AiModels';

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
   * The AI 助理 changes a 远程 AI setting (界面风格, 显示工具执行过程, 回到前台后恢复查看): saved for the current account
   * as 设置 → 远程 AI saves it. False when it cannot be saved now (no access, not read yet, or not one of those).
   */
  applyRemoteSetting(id: string, value: string): boolean {
    const settings: AiSettings | null = this.ownSettings();
    if (settings === null) { return false; }
    const next: AiSettings | null = aiRemoteSettingChanged(settings, id, value);
    if (next === null) { return false; }
    let account: AiAccountLease;
    try { account = AiAccess.getInstance().capture(); } catch (_error) { return false; }
    this.settings = next; this.settingsOwner = account.owner;
    AiLocalStore.getInstance().saveSettings(account, next).catch((): void => {
      // Not saved: read back what is stored.
      const context: common.Context | null = this.context;
      if (context !== null) { void this.refresh(context); }
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
