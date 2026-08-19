/**
 * Device-only Sunshine interoperability fixture.
 *
 * The suite is registered only for the exact focused class and receives its
 * endpoint and one-time PIN through `aa test -s ...` parameters. It exercises
 * the production Moonlight NAPI and writes host/trust/catalog state through
 * the same local services as the add-host flow; it never edits the RDB
 * directly and is not packaged in the production HAP.
 */
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { expect } from '@ohos/hypium';
import { CloudStore } from '../../../main/ets/services/CloudStore';
import {
  MoonlightHostAddOperationKey,
  MoonlightHostAddState
} from '../../../main/ets/services/MoonlightHostAddFlowPolicy';
import {
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightNativeApp,
  MoonlightNativeEndpoint,
  MoonlightNativeLaunchConfiguration
} from '../../../main/ets/services/MoonlightHostService';
import {
  MoonlightLocalHostSaveResult,
  MoonlightLocalHostService
} from '../../../main/ets/services/MoonlightLocalHostService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint
} from '../../../main/ets/services/MoonlightRuntimeSupport';
import { AccountSessionLease, cloneAccountSessionLease } from
  '../../../main/ets/services/AccountScopePolicy';
import { auditedDescribe, auditedIt } from
  '../../../main/ets/services/FocusedTestRegistrationAudit';

function parameter(name: string, fallback: string = ''): string {
  try {
    const args = abilityDelegatorRegistry.getArguments();
    return args.parameters['-s ' + name] || args.parameters[name] || fallback;
  } catch (_error) {
    return fallback;
  }
}

function positivePort(value: string, fallback: number): number {
  const parsed: number = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= 65535
    ? parsed : fallback;
}

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index++) {
    result += bytes[index].toString(16).padStart(2, '0');
  }
  return result;
}

function stableHostId(ownerScopeId: string, serverUuid: string): string {
  return 'moonlight-host|' + sha256Hex(
    'RemoteDeskHarmonyOS:moonlight-host:v1:' + ownerScopeId + ':' + serverUuid);
}

function testContext(): common.Context | undefined {
  try {
    return getContext() as common.Context;
  } catch (_error) {
    return undefined;
  }
}

function appForLaunch(apps: MoonlightNativeApp[]): MoonlightNativeApp | null {
  for (let index: number = 0; index < apps.length; index++) {
    if (apps[index].title.trim().toLowerCase() === 'desktop') {
      return apps[index];
    }
  }
  return apps.length > 0 ? apps[0] : null;
}

export default function moonlightSunshineInteropIntegrationTest(): void {
  let cloud: CloudStore;

  auditedDescribe('MoonlightSunshineInteropIntegration', (): void => {
    auditedIt('pairs_catalogs_launches_quits_and_materializes_local_host', 0,
      async (): Promise<void> => {
        const host: string = parameter('moonlightHost');
        const serverUuid: string = parameter('moonlightServerUuid');
        const pin: string = parameter('moonlightPin');
        const displayName: string = parameter(
          'moonlightDisplayName', 'RemoteDesk Sunshine Integration');
        const httpPort: number = positivePort(parameter('moonlightHttpPort'), 47989);
        const httpsPort: number = positivePort(parameter('moonlightHttpsPort'), 47984);
        expect(/^(?:\d{1,3}\.){3}\d{1,3}$/.test(host)).assertTrue();
        expect(serverUuid.trim().length > 0 && serverUuid.length <= 256).assertTrue();
        expect(/^\d{4}$/.test(pin)).assertTrue();

        const ctx: common.Context | undefined = testContext();
        expect(ctx !== undefined).assertTrue();
        cloud = CloudStore.getInstance();
        if (ctx !== undefined && !cloud.isReady()) {
          await cloud.init(ctx);
        }
        expect(cloud.isReady()).assertTrue();
        const activeLease: AccountSessionLease | null = cloud.currentAccountLease();
        expect(activeLease !== null).assertTrue();
        if (activeLease === null) { return; }
        const lease: AccountSessionLease = cloneAccountSessionLease(activeLease);
        const hostId: string = stableHostId(lease.ownerScopeId, serverUuid);
        const installationId: string = moonlightInstallationId(lease.storeIdentity);
        const ownerScopeFingerprint: string =
          moonlightOwnerScopeFingerprint(lease.ownerScopeId);
        const ownerToken: number = 91001;
        const generation: number = 1;
        const endpoint: MoonlightNativeEndpoint = {
          serverName: host,
          addresses: [{ value: host, family: 'ipv4' }],
          httpPort: httpPort,
          httpsPort: httpsPort,
          pinnedTrustAvailable: false,
          allowHttpPairingCandidate: true
        };
        const context: MoonlightHostContext = {
          lease: lease,
          ownerScopeFingerprint: ownerScopeFingerprint,
          ownerToken: ownerToken,
          generation: generation,
          hostId: hostId,
          serverUuid: serverUuid,
          installationId: installationId,
          endpoint: endpoint,
          timeoutMs: 120000
        };
        const service: MoonlightHostService = new MoonlightHostService();
        const capabilities = service.capabilities();
        expect(capabilities.bridgeCompiled).assertTrue();
        expect(capabilities.identityReady).assertTrue();
        expect(capabilities.transportReady).assertTrue();
        expect(capabilities.pairingReady).assertTrue();
        expect(capabilities.hostControlReady).assertTrue();

        const pinBytes: Uint8Array = new util.TextEncoder().encode(pin);
        const paired = await service.pair(context, installationId, pinBytes, false);
        pinBytes.fill(0);
        console.info('moonlight_sunshine_interop pair=' + paired.code);
        expect(paired.ok).assertTrue();
        expect(paired.nativeResult !== null).assertTrue();
        const certificateSha256: string = paired.nativeResult === null ||
          paired.nativeResult.certificateSha256 === undefined
          ? '' : paired.nativeResult.certificateSha256.toLowerCase();
        expect(/^[0-9a-f]{64}$/.test(certificateSha256)).assertTrue();

        const state: MoonlightHostAddState = new MoonlightHostAddState();
        state.ownerToken = ownerToken;
        state.generation = generation;
        state.step = 4;
        state.mode = 'manual';
        state.manualAddress = host;
        state.displayName = displayName;
        state.activeOperation = 'save';
        state.paired = true;
        state.trustState = 'trusted';
        state.verification = {
          serverUuid: serverUuid,
          serverName: displayName,
          hostType: 'sunshine',
          version: '7.1',
          address: { host: host, family: 'ipv4', port: httpPort },
          paired: true,
          fingerprintSha256: certificateSha256,
          certificateChanged: false,
          udpVerified: true,
          duplicateHostId: ''
        };
        state.selectedAddress = state.verification.address;
        const saveKey: MoonlightHostAddOperationKey = new MoonlightHostAddOperationKey();
        saveKey.ownerToken = ownerToken;
        saveKey.generation = generation;
        saveKey.operation = 'save';
        const saved: MoonlightLocalHostSaveResult =
          new MoonlightLocalHostService(cloud, cloud).save(state, saveKey, Date.now());
        console.info('moonlight_sunshine_interop save=' + saved.code);
        expect(saved.ok).assertTrue();
        expect(saved.localCommitted).assertTrue();
        expect(saved.hostId).assertEqual(hostId);

        context.pinnedCertificateSha256 = certificateSha256;
        context.endpoint.pinnedTrustAvailable = true;
        const catalog = await service.catalog(context);
        console.info('moonlight_sunshine_interop catalog=' + catalog.code +
          ' apps=' + catalog.visibleApps.length.toString());
        expect(catalog.ok).assertTrue();
        expect(catalog.nativeResult !== null).assertTrue();
        const apps: MoonlightNativeApp[] = catalog.nativeResult === null
          ? [] : catalog.nativeResult.apps;
        expect(apps.length > 0).assertTrue();
        const launchApp: MoonlightNativeApp | null = appForLaunch(apps);
        expect(launchApp !== null).assertTrue();
        if (launchApp === null) { return; }

        const launchConfiguration: MoonlightNativeLaunchConfiguration = {
          width: 1280,
          height: 720,
          refreshRate: 60,
          additionalStates: true,
          sops: true,
          hdr: false,
          playAudioOnHost: false,
          remoteControllersBitmap: 1,
          gamepadMask: 1,
          persistGamepads: true
        };
        const launched = await service.launch(context, launchApp.id, launchConfiguration);
        console.info('moonlight_sunshine_interop launch=' + launched.code);
        expect(launched.ok).assertTrue();
        expect(launched.nativeResult !== null).assertTrue();
        expect(launched.nativeResult !== null &&
          (launched.nativeResult.rtspSessionUrl || '').length > 0).assertTrue();

        const quit = await service.quit(context, launchApp.id, true);
        console.info('moonlight_sunshine_interop quit=' + quit.code);
        expect(quit.ok).assertTrue();
        expect(service.staleCompletions()).assertEqual(0);
        expect(service.staleEvents()).assertEqual(0);
      });
  });
}
