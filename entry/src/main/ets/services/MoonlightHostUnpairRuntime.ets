import {
  MoonlightHost,
  MoonlightSettings
} from '../model/MoonlightModels';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import { CloudStore } from './CloudStore';
import {
  MoonlightHostUnpairPort
} from './MoonlightDeletionCommandService';
import {
  MoonlightBridgeCapabilities,
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightHostServiceResult
} from './MoonlightHostService';
import {
  MoonlightHostLocalView,
  MoonlightLocalViewService
} from './MoonlightLocalViewService';
import {
  moonlightRuntimeContext,
  MoonlightRuntimeOwnerTokenAllocator
} from './MoonlightRuntimeContextFactory';
import {
  MoonlightLocalSettingsResult,
  MoonlightSettingsLocalService
} from './MoonlightSettingsLocalService';

interface PreparedHostUnpair {
  lease: AccountSessionLease;
  hostId: string;
  host: MoonlightHost;
  settings: MoonlightSettings;
  certificateSha256: string;
}

export interface MoonlightHostUnpairLeasePort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
}

export interface MoonlightHostUnpairViewPort {
  loadHost(hostId: string, nowMs: number): MoonlightHostLocalView;
}

export interface MoonlightHostUnpairSettingsPort {
  load(): MoonlightLocalSettingsResult;
}

export interface MoonlightHostUnpairControlPort {
  capabilities(): MoonlightBridgeCapabilities;
  unpair(context: MoonlightHostContext): Promise<MoonlightHostServiceResult>;
  disposeOwner(ownerToken: number): number;
}

function cloneSettings(value: MoonlightSettings): MoonlightSettings {
  return JSON.parse(JSON.stringify(value)) as MoonlightSettings;
}

function cloneHost(value: MoonlightHost): MoonlightHost {
  return JSON.parse(JSON.stringify(value)) as MoonlightHost;
}

/**
 * Captures the local trust fingerprint before the deletion transaction, then
 * performs Sunshine /unpair after local revocation. A failed remote request is
 * intentionally only a warning: local trust rejection remains authoritative.
 */
export class MoonlightHostUnpairRuntime implements MoonlightHostUnpairPort {
  private static instance: MoonlightHostUnpairRuntime | null = null;
  private readonly leases: MoonlightHostUnpairLeasePort;
  private readonly views: MoonlightHostUnpairViewPort;
  private readonly settings: MoonlightHostUnpairSettingsPort;
  private readonly control: MoonlightHostUnpairControlPort;
  private prepared: PreparedHostUnpair | null = null;

  constructor(
    leases: MoonlightHostUnpairLeasePort = CloudStore.getInstance(),
    views: MoonlightHostUnpairViewPort =
      new MoonlightLocalViewService(CloudStore.getInstance()),
    settings: MoonlightHostUnpairSettingsPort =
      new MoonlightSettingsLocalService(CloudStore.getInstance()),
    control: MoonlightHostUnpairControlPort = new MoonlightHostService()
  ) {
    this.leases = leases;
    this.views = views;
    this.settings = settings;
    this.control = control;
  }

  static getInstance(): MoonlightHostUnpairRuntime {
    if (MoonlightHostUnpairRuntime.instance === null) {
      MoonlightHostUnpairRuntime.instance =
        new MoonlightHostUnpairRuntime();
    }
    return MoonlightHostUnpairRuntime.instance;
  }

  isHostUnpairReady(
    lease: AccountSessionLease, hostId: string
  ): boolean {
    this.prepared = null;
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId === '' || !this.leaseIsCurrent(lease)) {
      return false;
    }
    let capabilities: MoonlightBridgeCapabilities;
    try {
      capabilities = this.control.capabilities();
    } catch (_error) {
      return false;
    }
    if (!capabilities.bridgeCompiled || !capabilities.transportReady) {
      return false;
    }
    const view: MoonlightHostLocalView =
      this.views.loadHost(normalizedHostId, Date.now());
    const loaded: MoonlightLocalSettingsResult = this.settings.load();
    if (!this.leaseIsCurrent(lease) || !view.ok || view.host === null ||
        !view.paired || !/^[0-9a-f]{64}$/.test(
          view.serverCertificateSha256) ||
        view.lease === null || !accountSessionLeaseEquals(view.lease, lease) ||
        (!loaded.ok && loaded.code !== 'default')) {
      return false;
    }
    this.prepared = {
      lease: cloneAccountSessionLease(lease),
      hostId: normalizedHostId,
      host: cloneHost(view.host),
      settings: cloneSettings(loaded.settings),
      certificateSha256: view.serverCertificateSha256
    };
    return true;
  }

  async requestHostUnpair(
    lease: AccountSessionLease, hostId: string
  ): Promise<boolean> {
    const prepared: PreparedHostUnpair | null = this.prepared;
    this.prepared = null;
    if (prepared === null || prepared.hostId !== hostId.trim() ||
        !accountSessionLeaseEquals(prepared.lease, lease) ||
        !this.leaseIsCurrent(lease)) {
      return false;
    }
    const ownerToken: number =
      MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const context: MoonlightHostContext | null = moonlightRuntimeContext(
      prepared.host, prepared.lease, ownerToken, prepared.lease.generation,
      prepared.certificateSha256, prepared.settings, 7000);
    if (context === null) { return false; }
    try {
      const result: MoonlightHostServiceResult =
        await this.control.unpair(context);
      return this.leaseIsCurrent(lease) && result.ok &&
        result.nativeResult !== null &&
        result.nativeResult.operation === 'unpair' &&
        result.nativeResult.code === 'ok' &&
        result.nativeResult.actionTruth === 'confirmed' &&
        result.nativeResult.postconditionTruth === 'confirmed';
    } catch (_error) {
      return false;
    } finally {
      this.control.disposeOwner(ownerToken);
    }
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.leases.currentAccountLease(), lease) &&
      this.leases.isLeaseCurrent(lease);
  }
}
