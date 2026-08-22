import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { MoonlightHost, defaultMoonlightSettings } from '../main/ets/model/MoonlightModels';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import { MoonlightHostContext } from '../main/ets/services/MoonlightHostService';
import {
  MoonlightRuntimeOwnerTokenAllocator,
  moonlightLaunchConfiguration,
  moonlightRuntimeContext,
  moonlightSelectedHostAddress
} from '../main/ets/services/MoonlightRuntimeContextFactory';

function host(): MoonlightHost {
  return {
    id: 'host-record-1', serverUuid: 'server-1', displayName: 'Sunshine',
    addresses: [
      { host: 'sunshine.local', family: 'hostname', port: 47989 },
      { host: '2001:db8::1', family: 'ipv6', port: 47989 }
    ],
    preferredAddressKey: 'hostname|sunshine.local|47989', httpsPort: 48084,
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  };
}

function lease(): AccountSessionLease {
  return {
    ownerScopeId: 'owner-1', generation: 1,
    storeIdentity: 'store-1', storeInstanceId: 1
  };
}

export default function moonlightRuntimeContextFactoryTest(): void {
  describe('MoonlightRuntimeContextFactory', (): void => {
    it('selects_and_brackets_the_preferred_address', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.network.preferredAddressFamily = 'ipv6';
      expect(moonlightSelectedHostAddress(host(), settings))
        .assertEqual('[2001:db8::1]:47989');
    });

    it('builds_one_safe_host_context_and_slot_zero_launch_contract', 0, (): void => {
      const settings = defaultMoonlightSettings();
      const context = moonlightRuntimeContext(host(), lease(), 11, 2,
        'a'.repeat(64), settings, 5000);
      expect(context !== null).assertTrue();
      expect((context as MoonlightHostContext).timeoutMs).assertEqual(5000);
      expect((context as MoonlightHostContext).hostId).assertEqual('server-1');
      expect((context as MoonlightHostContext).localHostId).assertEqual('host-record-1');
      expect((context as MoonlightHostContext).endpoint.httpsPort).assertEqual(48084);
      const launch = moonlightLaunchConfiguration(settings);
      expect(launch.remoteControllersBitmap).assertEqual(1);
      expect(launch.gamepadMask).assertEqual(1);
      expect(launch.persistGamepads).assertTrue();
    });

    it('falls_back_to_the_official_https_port_for_legacy_host_rows', 0, (): void => {
      const legacyHost: MoonlightHost = host();
      legacyHost.httpsPort = undefined;
      const context = moonlightRuntimeContext(legacyHost, lease(), 11, 2,
        'a'.repeat(64), defaultMoonlightSettings(), 5000);
      expect(context !== null).assertTrue();
      expect((context as MoonlightHostContext).endpoint.httpsPort).assertEqual(47984);
    });

    it('never_advertises_an_unowned_controller_slot_to_sunshine', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.input.controllerSlot = 3;
      const launch = moonlightLaunchConfiguration(settings);
      expect(launch.remoteControllersBitmap).assertEqual(1);
      expect(launch.gamepadMask).assertEqual(1);
      expect(launch.persistGamepads).assertTrue();
    });

    it('allocates_strictly_monotonic_process_owner_tokens', 0, (): void => {
      const allocator = MoonlightRuntimeOwnerTokenAllocator.getInstance();
      allocator.resetForTest();
      const first: number = allocator.next(1000);
      const second: number = allocator.next(1000);
      const third: number = allocator.next(999);
      expect(second > first).assertTrue();
      expect(third > second).assertTrue();
    });
  });
}
