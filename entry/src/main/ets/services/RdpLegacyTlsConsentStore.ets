import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';

/**
 * Security a user may lower for one host: legacy TLS (1.0/1.1, security level
 * 0), or signing in over TLS without Network Level Authentication.
 */
export type RdpSecurityDowngrade = 'legacy-tls' | 'tls-without-nla';

/**
 * Hosts whose user agreed to lower RDP security for them, per signed-in
 * account and by route identity so a changed address or port asks again. Kept
 * on this device only (a local security decision, never synced); every choice
 * can be withdrawn, and a deleted host's choices go with it.
 */
export class RdpLegacyTlsConsentStore {
  private static instance: RdpLegacyTlsConsentStore | null = null;
  private store: preferences.Preferences | null = null;

  static getInstance(): RdpLegacyTlsConsentStore {
    if (RdpLegacyTlsConsentStore.instance === null) {
      RdpLegacyTlsConsentStore.instance = new RdpLegacyTlsConsentStore();
    }
    return RdpLegacyTlsConsentStore.instance;
  }

  private prefs(context: common.Context): preferences.Preferences | null {
    if (this.store !== null) { return this.store; }
    try {
      this.store = preferences.getPreferencesSync(context, { name: 'RdpSecurityDowngrades' });
    } catch (error) {
      hilog.warn(0x0001, 'RdpDowngrade', 'consent store unavailable: ' + JSON.stringify(error));
      this.store = null;
    }
    return this.store;
  }

  private scope(): string {
    const owner: string = AccountSessionCoordinator.getInstance().currentScope().ownerScopeId.trim();
    return owner === '' ? 'device-local' : owner;
  }

  private hostPrefix(hostId: string): string {
    return this.scope() + '|' + hostId + '|';
  }

  private key(kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): string {
    return this.hostPrefix(hostId) + kind + '|' + routeIdentity;
  }

  allowedKind(context: common.Context, kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): boolean {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null || hostId === '' || routeIdentity === '') { return false; }
    return store.getSync(this.key(kind, hostId, routeIdentity), false) === true;
  }

  /** Remember the choice; false when it could not be stored (the caller must not claim it took effect). */
  allowKind(context: common.Context, kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): boolean {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null || hostId === '' || routeIdentity === '') { return false; }
    try {
      store.putSync(this.key(kind, hostId, routeIdentity), true);
      store.flush().catch((): void => {});
      return true;
    } catch (_error) {
      return false;
    }
  }

  revokeKind(context: common.Context, kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): void {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null) { return; }
    try {
      store.deleteSync(this.key(kind, hostId, routeIdentity));
      store.flush().catch((): void => {});
    } catch (_error) { /* nothing stored */ }
  }

  /** Every choice for a host (all routes), e.g. when the host is deleted. */
  revokeHost(context: common.Context, hostId: string): void {
    this.removeMatching(context, (key: string): boolean => key.startsWith(this.hostPrefix(hostId)));
  }

  /** How many hosts of the signed-in account have a lowered security choice. */
  hostCount(context: common.Context): number {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null) { return 0; }
    const prefix: string = this.scope() + '|';
    const hosts: string[] = [];
    try {
      const all: Object = store.getAllSync();
      Object.keys(all).forEach((key: string): void => {
        if (!key.startsWith(prefix)) { return; }
        const host: string = key.substring(prefix.length).split('|')[0];
        if (hosts.indexOf(host) < 0) { hosts.push(host); }
      });
    } catch (_error) {
      return 0;
    }
    return hosts.length;
  }

  /** Withdraw every choice of the signed-in account. */
  revokeAll(context: common.Context): void {
    const prefix: string = this.scope() + '|';
    this.removeMatching(context, (key: string): boolean => key.startsWith(prefix));
  }

  private removeMatching(context: common.Context, matches: (key: string) => boolean): void {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null) { return; }
    try {
      const all: Object = store.getAllSync();
      Object.keys(all).forEach((key: string): void => {
        if (matches(key)) { store.deleteSync(key); }
      });
      store.flush().catch((): void => {});
    } catch (_error) { /* nothing to remove */ }
  }

  allowed(context: common.Context, hostId: string, routeIdentity: string): boolean {
    return this.allowedKind(context, 'legacy-tls', hostId, routeIdentity);
  }

  allow(context: common.Context, hostId: string, routeIdentity: string): boolean {
    return this.allowKind(context, 'legacy-tls', hostId, routeIdentity);
  }
}
