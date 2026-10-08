import { util } from '@kit.ArkTS';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { ExtensionLoader } from '../../ExtensionLoader';
import { RemoteHost } from '../../../model/RemoteHost';
import { SshProxyRuntimePlan } from '../../SshProxyRuntimePolicy';
import { sshHostKeyRouteBinding } from '../../SshHostKeyTrustPolicy';

interface AuthenticatedSshReceipt {
  hostId: string;
  username: string;
  hostOwnerId: string;
  routeIdentity: string;
  scope: AccountScopeToken;
  sessionId: number;
  generation: number;
  timer: number;
  ownsSession: boolean;
}

/** One-shot ownership transfer; router parameters never contain credentials. */
export class SshAuthenticatedHandoff {
  private static instance: SshAuthenticatedHandoff = new SshAuthenticatedHandoff();
  private receipts: Map<string, AuthenticatedSshReceipt> = new Map();
  private retained: Map<number, AuthenticatedSshReceipt> = new Map();

  static getInstance(): SshAuthenticatedHandoff { return SshAuthenticatedHandoff.instance; }

  stage(host: RemoteHost, plan: SshProxyRuntimePlan, scope: AccountScopeToken,
    sessionId: number, generation: number): string {
    const loader = ExtensionLoader.getInstance();
    const binding = sshHostKeyRouteBinding(host, plan);
    if (!binding.ok || sessionId <= 0 || generation <= 0 ||
      loader.getConnectionState(sessionId) !== 2 ||
      loader.getSshTerminalDiagnostics(sessionId).sessionGeneration !== generation ||
      !loader.detachSshSession(sessionId, host.id)) { return ''; }
    const token: string = util.generateRandomUUID(true);
    const timer: number = setTimeout((): void => { this.discard(token); }, 30000);
    this.receipts.set(token, {
      hostId: host.id, username: host.username, hostOwnerId: host.userId,
      routeIdentity: binding.identity, scope, sessionId, generation, timer, ownsSession: true
    });
    return token;
  }

  /** Record the account and route of a session while its terminal still owns it. */
  remember(host: RemoteHost, plan: SshProxyRuntimePlan, sessionId: number, generation: number): void {
    const loader = ExtensionLoader.getInstance();
    this.retained.forEach((record: AuthenticatedSshReceipt, id: number): void => {
      if (loader.getConnectionState(id) <= 0 ||
        loader.getSshTerminalDiagnostics(id).sessionGeneration !== record.generation) {
        this.retained.delete(id);
      }
    });
    const binding = sshHostKeyRouteBinding(host, plan);
    if (!binding.ok || sessionId <= 0 || generation <= 0) { return; }
    this.retained.set(sessionId, {
      hostId: host.id, username: host.username, hostOwnerId: host.userId,
      routeIdentity: binding.identity, scope: AccountSessionCoordinator.getInstance().currentScope(),
      sessionId, generation, timer: -1, ownsSession: false
    });
  }

  resume(host: RemoteHost, plan: SshProxyRuntimePlan): string {
    const loader = ExtensionLoader.getInstance();
    const sessionId: number = loader.peekDetachedSshSession(host.id);
    if (sessionId <= 0) { return ''; }
    const record: AuthenticatedSshReceipt | undefined = this.retained.get(sessionId);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const binding = sshHostKeyRouteBinding(host, plan);
    if (record === undefined || !binding.ok || record.routeIdentity !== binding.identity ||
      record.username !== host.username || record.hostOwnerId !== host.userId ||
      record.scope.ownerScopeId !== scope.ownerScopeId || record.scope.storeIdentity !== scope.storeIdentity ||
      record.scope.generation !== scope.generation) {
      throw new Error('此主机仍有其他配置的保留会话，请先关闭原会话后重试');
    }
    const token: string = this.stage(host, plan, scope, sessionId, record.generation);
    if (token.length === 0) { throw new Error('保留的 SSH 会话暂时无法恢复，请稍后重试'); }
    const receipt: AuthenticatedSshReceipt | undefined = this.receipts.get(token);
    if (receipt !== undefined) { receipt.ownsSession = false; }
    return token;
  }

  consume(token: string, host: RemoteHost, plan: SshProxyRuntimePlan): number {
    const receipt: AuthenticatedSshReceipt | undefined = this.receipts.get(token);
    if (receipt === undefined) { return -1; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const binding = sshHostKeyRouteBinding(host, plan);
    if (receipt.hostId !== host.id || receipt.username !== host.username || receipt.hostOwnerId !== host.userId ||
      !binding.ok || binding.identity !== receipt.routeIdentity ||
      scope.ownerScopeId !== receipt.scope.ownerScopeId ||
      scope.storeIdentity !== receipt.scope.storeIdentity || scope.generation !== receipt.scope.generation) {
      this.discard(token);
      return -1;
    }
    const adopted: number = ExtensionLoader.getInstance().adoptDetachedSshSession(
      host.id, receipt.sessionId, receipt.generation);
    if (adopted !== receipt.sessionId) { this.discard(token); return -1; }
    clearTimeout(receipt.timer);
    this.receipts.delete(token);
    return adopted;
  }

  discard(token: string): void {
    const receipt: AuthenticatedSshReceipt | undefined = this.receipts.get(token);
    if (receipt === undefined) { return; }
    clearTimeout(receipt.timer);
    this.receipts.delete(token);
    const loader = ExtensionLoader.getInstance();
    if (receipt.ownsSession &&
      loader.getSshTerminalDiagnostics(receipt.sessionId).sessionGeneration === receipt.generation) {
      loader.disconnectSshSession(receipt.sessionId);
    }
  }
}
