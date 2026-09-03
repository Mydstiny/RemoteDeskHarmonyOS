import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { ActiveRemoteSessionRegistry } from './ActiveRemoteSessionRegistry';
import { DataCrypto } from './DataCrypto';
import { ExtensionLoader } from './ExtensionLoader';
import { RemoteSessionBackgroundTaskService } from './RemoteSessionBackgroundTaskService';
import { RemoteSessionLiveViewService } from './RemoteSessionLiveViewService';
import { RemoteSessionPipService } from './RemoteSessionPipService';
import { RustDeskProSyncService } from './RustDeskProSyncService';
import { RustDeskHostAddHandoff } from './RustDeskHostAddHandoff';
import { SshPreflightService } from './SshPreflightService';
import { SshOperationRouteSecretService } from './SshOperationRouteSecretService';
import { VncSessionCredentialHandoff } from './VncSessionCredentialHandoff';
import { RdpSessionCredentialHandoff } from './RdpSessionCredentialHandoff';
import { VncPlaintextDecisionHandoff } from './VncPlaintextDecisionHandoff';
import { MoonlightDataLifecycleBarrier } from './MoonlightDataLifecycleBarrier';

/**
 * One transition boundary shared by login, logout, account switch and restore.
 * New scope data must not be opened until every old-scope session and plaintext
 * handoff has been drained.
 */
export class SensitiveDataBarrier {
  private static instance: SensitiveDataBarrier;
  private context: common.UIAbilityContext | null = null;

  static getInstance(): SensitiveDataBarrier {
    if (!SensitiveDataBarrier.instance) {
      SensitiveDataBarrier.instance = new SensitiveDataBarrier();
    }
    return SensitiveDataBarrier.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async drain(reason: string): Promise<boolean> {
    // Invalidate the ArkTS handoff before the first await. Native route probes
    // may already own a synchronous copy, so cancel and drain those workers
    // before the account/store scope is allowed to change.
    RdpSessionCredentialHandoff.getInstance().clearAll();
    if (!(await ExtensionLoader.getInstance()
      .prepareRdpPreflightScopeTransition(10000))) {
      hilog.error(0x0001, 'AccountSession',
        'RDP preflight operations did not reach a terminal state');
      return false;
    }
    if (this.context === null) {
      hilog.error(0x0001, 'AccountSession',
        'sensitive data barrier has no UIAbilityContext');
      return false;
    }
    let pipStopped: boolean = false;
    for (let attempt: number = 0; attempt < 2 && !pipStopped; attempt++) {
      try {
        pipStopped = await RemoteSessionPipService.getInstance().stop();
      } catch (err) {
        hilog.warn(0x0001, 'AccountSession',
          'PIP drain failed: ' + JSON.stringify(err));
      }
    }
    if (!pipStopped) {
      hilog.error(0x0001, 'AccountSession',
        'PIP did not reach a terminal state; account transition blocked');
      return false;
    }
    await RemoteSessionLiveViewService.getInstance().stop(this.context);
    await RemoteSessionBackgroundTaskService.getInstance()
      .stopSessionTask(this.context);
    try {
      ExtensionLoader.getInstance().disconnectAll();
    } catch (err) {
      hilog.warn(0x0001, 'AccountSession', 'native session drain failed: ' + JSON.stringify(err));
      return false;
    }
    const nativeStopped: boolean =
      await ExtensionLoader.getInstance().waitForPendingTeardown(10000);
    if (!nativeStopped) {
      hilog.error(0x0001, 'AccountSession',
        'native teardown did not reach a terminal state; account transition blocked');
      return false;
    }
    if (!(await RustDeskProSyncService.getInstance()
      .prepareScopeTransition(10000))) {
      hilog.error(0x0001, 'AccountSession',
        'RustDesk Pro operations did not reach a terminal state');
      return false;
    }
    if (!(await MoonlightDataLifecycleBarrier.getInstance()
      .drain(reason, 10000))) {
      hilog.error(0x0001, 'AccountSession',
        'Moonlight operations did not reach a terminal state');
      return false;
    }
    ActiveRemoteSessionRegistry.getInstance().clear(reason);
    RustDeskHostAddHandoff.getInstance().clearAll();
    VncSessionCredentialHandoff.getInstance().clearAll();
    VncPlaintextDecisionHandoff.getInstance().clearAll();
    SshPreflightService.getInstance().clearAll();
    SshOperationRouteSecretService.getInstance().clearAll();
    if (!(await DataCrypto.getInstance().prepareScopeTransition(10000))) {
      hilog.error(0x0001, 'AccountSession',
        'crypto tasks did not reach a terminal state; account transition blocked');
      return false;
    }
    return true;
  }
}
