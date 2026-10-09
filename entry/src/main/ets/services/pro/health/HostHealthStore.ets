import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { ProEntries } from '../ProEntries';
import {
  appendHostHealthObservation,
  HostHealthObservation,
  normalizeHostHealthObservation
} from './HostHealthPolicy';

export const PRO_HOST_HEALTH_FEATURE: string = 'pro.hostHealth';
/** A local file of its own: health history never joins cloud sync, backups or exports of host settings. */
export const HOST_HEALTH_PREFERENCES_NAME: string = 'ProHostHealth';

export interface HostHealthPersistence {
  load(key: string): string;
  save(key: string, value: string): boolean;
  remove(key: string): void;
}

class PreferencesHostHealthPersistence implements HostHealthPersistence {
  private context: common.Context | null = null;
  bind(context: common.Context): void { this.context = context; }
  private prefs(): preferences.Preferences | null {
    if (this.context === null) { return null; }
    try {
      return preferences.getPreferencesSync(this.context, { name: HOST_HEALTH_PREFERENCES_NAME });
    } catch (_error) {
      return null;
    }
  }
  load(key: string): string {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return ''; }
    try {
      const value: preferences.ValueType = prefs.getSync(key, '');
      return typeof value === 'string' ? value : '';
    } catch (_error) {
      return '';
    }
  }
  save(key: string, value: string): boolean {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return false; }
    try {
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }
  remove(key: string): void {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return; }
    try {
      prefs.deleteSync(key);
      prefs.flushSync();
    } catch (_error) {
      // A row that cannot be removed now is still unreadable under another account.
    }
  }
}

/**
 * 主机健康中心 history: the last observations per host, for the signed-in account only (keys carry the account
 * scope, so another account never reads them). Records only while the Pro feature is available; free users keep
 * the plain online dot of the host card.
 */
export class HostHealthStore {
  private static instance: HostHealthStore | null = null;
  private readonly preferencesPersistence: PreferencesHostHealthPersistence = new PreferencesHostHealthPersistence();
  private persistence: HostHealthPersistence = this.preferencesPersistence;
  private scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
  private cache: Map<string, HostHealthObservation[]> = new Map<string, HostHealthObservation[]>();
  private listeners: Array<() => void> = [];
  private revision: number = 0;

  private constructor() {
    AccountSessionCoordinator.getInstance().onChange((scope: AccountScopeToken): void => {
      if (scope.ownerScopeId === this.scope.ownerScopeId && scope.generation === this.scope.generation) { return; }
      this.scope = scope;
      this.cache.clear();
      this.publish();
    });
  }

  static getInstance(): HostHealthStore {
    if (HostHealthStore.instance === null) { HostHealthStore.instance = new HostHealthStore(); }
    return HostHealthStore.instance;
  }

  init(context: common.Context): void { this.preferencesPersistence.bind(context); }

  /** Test/embedding seam. */
  bindPersistence(persistence: HostHealthPersistence): void {
    this.persistence = persistence;
    this.cache.clear();
  }

  enabled(): boolean { return ProEntries.visible(PRO_HOST_HEALTH_FEATURE); }

  /** Changes on every record or account switch; pages pass it to builders so they re-render. */
  currentRevision(): number { return this.revision; }

  private key(hostId: string): string {
    const owner: string = this.scope.ownerScopeId.length > 0 ? this.scope.ownerScopeId : 'local';
    return 'v1|' + owner + '|' + hostId;
  }

  /** Newest first; empty when nothing was observed yet. */
  history(hostId: string): HostHealthObservation[] {
    if (hostId.length === 0) { return []; }
    const key: string = this.key(hostId);
    const cached: HostHealthObservation[] | undefined = this.cache.get(key);
    if (cached !== undefined) { return cached; }
    const loaded: HostHealthObservation[] = [];
    const raw: string = this.persistence.load(key);
    if (raw.length > 0) {
      try {
        const rows: Object = JSON.parse(raw) as Object;
        if (Array.isArray(rows)) {
          for (const row of rows as Object[]) {
            const observation: HostHealthObservation | null = normalizeHostHealthObservation(row);
            if (observation !== null && observation.hostId === hostId) { loaded.push(observation); }
          }
        }
      } catch (_error) {
        // A damaged row reads as no history; the next record replaces it.
      }
    }
    loaded.sort((a: HostHealthObservation, b: HostHealthObservation): number => b.observedAt - a.observedAt);
    this.cache.set(key, loaded);
    return loaded;
  }

  latest(hostId: string): HostHealthObservation | null {
    const rows: HostHealthObservation[] = this.history(hostId);
    return rows.length > 0 ? rows[0] : null;
  }

  /**
   * Adds an observation for the account that was signed in when the check started (`scopeId`); one finishing
   * after an account switch is dropped. Nothing is kept while the feature is unavailable.
   */
  record(observation: HostHealthObservation, scopeId: string): boolean {
    if (!this.enabled() || scopeId !== this.scope.ownerScopeId) { return false; }
    const key: string = this.key(observation.hostId);
    const next: HostHealthObservation[] = appendHostHealthObservation(this.history(observation.hostId), observation);
    if (!this.persistence.save(key, JSON.stringify(next))) { return false; }
    this.cache.set(key, next);
    this.publish();
    return true;
  }

  /** A deleted host takes its history with it. */
  removeHost(hostId: string): void {
    const key: string = this.key(hostId);
    this.cache.delete(key);
    this.persistence.remove(key);
    this.publish();
  }

  currentScopeId(): string { return this.scope.ownerScopeId; }

  onChange(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
    };
  }

  private publish(): void {
    this.revision = this.revision + 1;
    for (const listener of this.listeners.slice()) {
      try { listener(); } catch (_error) { /* one listener cannot stop the others */ }
    }
  }
}
