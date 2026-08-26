import { AccountSessionLease } from './AccountScopePolicy';
import { CloudStore } from './CloudStore';
import {
  MoonlightDeletionCommandResult,
  MoonlightDeletionCommandService,
  MoonlightDeletionPreview
} from './MoonlightDeletionCommandService';
import {
  MoonlightDeletionCommandType
} from './MoonlightDeletionPolicy';
import {
  MoonlightHostUnpairRuntime
} from './MoonlightHostUnpairRuntime';
import {
  MoonlightIdentityDeletionRuntime
} from './MoonlightIdentityDeletionRuntime';

/**
 * The sole production composition for user-initiated Moonlight data removal.
 * Keeping every caller on this object prevents a page from bypassing account
 * fencing, cloud tombstones, trust revocation, or secure-identity cleanup.
 */
export class MoonlightDeletionRuntime {
  private static instance: MoonlightDeletionRuntime | null = null;
  private readonly store: CloudStore;
  private readonly commands: MoonlightDeletionCommandService;

  private constructor() {
    this.store = CloudStore.getInstance();
    this.commands = new MoonlightDeletionCommandService(
      this.store,
      this.store,
      MoonlightHostUnpairRuntime.getInstance(),
      MoonlightIdentityDeletionRuntime.getInstance());
  }

  static getInstance(): MoonlightDeletionRuntime {
    if (MoonlightDeletionRuntime.instance === null) {
      MoonlightDeletionRuntime.instance = new MoonlightDeletionRuntime();
    }
    return MoonlightDeletionRuntime.instance;
  }

  currentLease(): AccountSessionLease | null {
    return this.store.currentAccountLease();
  }

  isLeaseCurrent(lease: AccountSessionLease): boolean {
    return this.store.isLeaseCurrent(lease);
  }

  preview(lease: AccountSessionLease,
    command: MoonlightDeletionCommandType,
    hostId: string = '', profileId: string = ''): MoonlightDeletionPreview {
    return this.commands.preview(lease, command, hostId, profileId);
  }

  async execute(lease: AccountSessionLease,
    preview: MoonlightDeletionPreview,
    nowMs: number = Date.now()): Promise<MoonlightDeletionCommandResult> {
    return await this.commands.execute(lease, preview, nowMs);
  }
}
