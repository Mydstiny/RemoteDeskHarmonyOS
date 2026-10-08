import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

/**
 * Security a user may lower for one host: legacy TLS (1.0/1.1, security level
 * 0), or signing in over TLS without Network Level Authentication.
 */
export type RdpSecurityDowngrade = 'legacy-tls' | 'tls-without-nla';

/** rdp_security_choice codes (see the AI event glossary). */
const CHOICE_ALLOW_LEGACY_TLS: number = 1;
const CHOICE_ALLOW_TLS_SIGN_IN: number = 2;
const CHOICE_REVOKE_TLS_SIGN_IN: number = 3;
const CHOICE_REVOKE_LEGACY_TLS: number = 4;
const CHOICE_REVOKE_HOST: number = 5;
const CHOICE_REVOKE_ALL: number = 6;

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
      // The first version kept legacy-TLS consents unscoped in another file; they are not read any more.
      preferences.deletePreferences(context, { name: 'RdpLegacyTlsConsent' }).catch((): void => {});
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
      this.recordChoice(context, kind === 'legacy-tls' ? CHOICE_ALLOW_LEGACY_TLS : CHOICE_ALLOW_TLS_SIGN_IN, 'succeeded');
      return true;
    } catch (_error) {
      this.recordChoice(context, kind === 'legacy-tls' ? CHOICE_ALLOW_LEGACY_TLS : CHOICE_ALLOW_TLS_SIGN_IN, 'failed');
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
    this.recordChoice(context, kind === 'legacy-tls' ? CHOICE_REVOKE_LEGACY_TLS : CHOICE_REVOKE_TLS_SIGN_IN, 'succeeded');
  }

  /** Every choice for a host (all routes), e.g. when the host is deleted. */
  revokeHost(context: common.Context, hostId: string): void {
    if (this.removeMatching(context, (key: string): boolean => key.startsWith(this.hostPrefix(hostId))) > 0) {
      this.recordChoice(context, CHOICE_REVOKE_HOST, 'succeeded');
    }
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
    this.recordChoice(context, CHOICE_REVOKE_ALL, 'succeeded');
  }

  /** How many stored choices were removed. */
  private removeMatching(context: common.Context, matches: (key: string) => boolean): number {
    const store: preferences.Preferences | null = this.prefs(context);
    if (store === null) { return 0; }
    let removed: number = 0;
    try {
      const all: Object = store.getAllSync();
      Object.keys(all).forEach((key: string): void => {
        if (matches(key)) { store.deleteSync(key); removed++; }
      });
      store.flush().catch((): void => {});
    } catch (_error) { /* nothing to remove */ }
    return removed;
  }

  /** A lowered or restored security choice for the AI's log reading: no host, only what changed and how many remain. */
  private recordChoice(context: common.Context, choice: number, outcome: 'succeeded' | 'failed'): void {
    try {
      recordDiagnosticEvent('connection.rdp', 'rdp_security_choice', outcome, 0, 0, choice, 0, this.hostCount(context));
    } catch (_error) { /* diagnostics never block the choice */ }
  }

  allowed(context: common.Context, hostId: string, routeIdentity: string): boolean {
    return this.allowedKind(context, 'legacy-tls', hostId, routeIdentity);
  }

  allow(context: common.Context, hostId: string, routeIdentity: string): boolean {
    return this.allowKind(context, 'legacy-tls', hostId, routeIdentity);
  }
}
