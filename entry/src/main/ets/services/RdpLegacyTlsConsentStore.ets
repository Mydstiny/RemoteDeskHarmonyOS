import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Hosts whose user agreed to lower RDP security for them (legacy TLS, or TLS
 * sign-in without NLA), by route identity so a changed address or port asks
 * again. Kept on this device only; a local security decision, never synced.
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
      this.store = preferences.getPreferencesSync(context, { name: 'RdpLegacyTlsConsent' });
    } catch (error) {
      hilog.warn(0x0001, 'RdpLegacyTls', 'consent store unavailable: ' + JSON.stringify(error));
      this.store = null;
    }
    return this.store;
  }

  private key(kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): string {
    // Legacy TLS keeps its original key form so earlier consents stay valid.
    return (kind === 'legacy-tls' ? '' : kind + '|') + hostId + '|' + routeIdentity;
  }

  allowedKind(context: common.Context, kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): boolean {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null || hostId === '' || routeIdentity === '') { return false; }
    return store.getSync(this.key(kind, hostId, routeIdentity), false) === true;
  }

  allowKind(context: common.Context, kind: RdpSecurityDowngrade, hostId: string, routeIdentity: string): void {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null || hostId === '' || routeIdentity === '') { return; }
    store.putSync(this.key(kind, hostId, routeIdentity), true);
    store.flush().catch((): void => {});
  }

  allowed(context: common.Context, hostId: string, routeIdentity: string): boolean {
    return this.allowedKind(context, 'legacy-tls', hostId, routeIdentity);
  }

  allow(context: common.Context, hostId: string, routeIdentity: string): void {
    this.allowKind(context, 'legacy-tls', hostId, routeIdentity);
  }
}

/**
 * Security a user may lower for one host: legacy TLS (1.0/1.1, security level
 * 0), or signing in over TLS without Network Level Authentication.
 */
export type RdpSecurityDowngrade = 'legacy-tls' | 'tls-without-nla';
