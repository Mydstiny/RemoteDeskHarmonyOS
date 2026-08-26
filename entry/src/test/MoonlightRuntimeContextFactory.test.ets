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
  moonlightNetworkSafeBitrateKbps,
  moonlightRuntimeContext,
  moonlightSelectedHostAddress,
  moonlightWifiReceiveLinkSpeedMbps
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

    it('preserves_device_aspect_ratio_inside_the_stable_long_edge_budget', 0,
      (): void => {
        const settings = defaultMoonlightSettings();
        settings.video.resolutionMode = 'custom';
        settings.video.adaptiveResolution = 'device';
        settings.video.customWidth = 1920;
        settings.video.customHeight = 1080;
        const launch = moonlightLaunchConfiguration(settings, 2560, 1600, 4096, 2160);
        expect(launch.width).assertEqual(1920);
        expect(launch.height).assertEqual(1200);
      });

    it('caps_video_bitrate_to_sixty_percent_of_the_receive_link_budget', 0, (): void => {
      expect(moonlightWifiReceiveLinkSpeedMbps(25, 0)).assertEqual(25);
      expect(moonlightWifiReceiveLinkSpeedMbps(300, 25)).assertEqual(25);
      expect(moonlightNetworkSafeBitrateKbps(20000, 25)).assertEqual(15000);
      expect(moonlightNetworkSafeBitrateKbps(12000, 25)).assertEqual(12000);
      expect(moonlightNetworkSafeBitrateKbps(20000, 0)).assertEqual(20000);
    });

    it('fits_device_aspect_ratio_inside_the_selected_decoder_bounds', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.video.resolutionMode = 'custom';
      settings.video.adaptiveResolution = 'device';
      settings.video.customWidth = 3840;
      settings.video.customHeight = 2160;
      const launch = moonlightLaunchConfiguration(settings, 2560, 1600, 1920, 1080);
      expect(launch.width).assertEqual(1728);
      expect(launch.height).assertEqual(1080);
    });

    it('fits_host_capability_to_the_current_device_aspect_ratio', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.video.resolutionMode = 'host';
      settings.video.adaptiveResolution = 'host';
      settings.video.customWidth = 1920;
      settings.video.customHeight = 1080;
      const launch = moonlightLaunchConfiguration(settings, 2560, 1600, 1920, 1080);
      expect(launch.width).assertEqual(1728);
      expect(launch.height).assertEqual(1080);
      expect(launch.resolutionPolicy).assertEqual('hostCapability');
    });

    it('keeps_legacy_host_capability_pixels_when_display_probe_is_unavailable', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.video.resolutionMode = 'host';
      settings.video.adaptiveResolution = 'host';
      settings.video.customWidth = 1920;
      settings.video.customHeight = 1080;
      const launch = moonlightLaunchConfiguration(settings, 0, 0, 1920, 1080);
      expect(launch.width).assertEqual(1920);
      expect(launch.height).assertEqual(1080);
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
