import { common } from '@kit.AbilityKit';
import { RemoteHost } from '../../model/RemoteHost';
import { AiAccess } from './AiAccess';
import { AiLocalStore } from './AiLocalStore';
import { AiHost, aiBackendName } from './AiModels';

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
  static getInstance(): AiHostService {
    if (!AiHostService.instance) { AiHostService.instance = new AiHostService(); }
    return AiHostService.instance;
  }
  clear(): void { this.revision++; this.hosts = []; }
  async refresh(context: common.Context): Promise<void> {
    const revision = ++this.revision;
    if (!AiAccess.getInstance().proVisible()) { this.hosts = []; return; }
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
