import { describe, it, expect } from '@ohos/hypium';
import {
  defaultRemoteDisplayProfile,
  isRdpDeviceScalePercent,
  migrateLegacyRdpDisplayProfile,
  normalizeRdpDesktopScalePercent,
  normalizeRemoteDisplayGeometry,
  remoteDisplayProfileRequiresPro,
  resolveRdpScaleProfile,
  rustDeskCustomResolutionDecision,
  validateRemoteDisplayGeometry
} from '../main/ets/services/RemoteDisplayProfilePolicy';

export default function remoteDisplayProfilePolicyTest(): void {
  describe('RemoteDisplayProfilePolicy', (): void => {
    it('keeps_remote_geometry_separate_from_local_or_rdp_scale', 0, (): void => {
      const profile = defaultRemoteDisplayProfile('host-1', 'rdp', 'p1', 10);
      expect(profile.resolution.mode).assertEqual('auto');
      expect(profile.rdpScale.desktopPercent).assertEqual(100);
      expect(profile.localViewMode).assertEqual('fit');
      expect(remoteDisplayProfileRequiresPro(profile)).assertFalse();
    });

    it('accepts_even_custom_geometry_and_rejects_odd_width', 0, (): void => {
      expect(validateRemoteDisplayGeometry(3440, 1440).accepted).assertTrue();
      expect(validateRemoteDisplayGeometry(3441, 1440).accepted).assertFalse();
      expect(validateRemoteDisplayGeometry(3441, 1440).width).assertEqual(3440);
      expect(validateRemoteDisplayGeometry(199, 900).accepted).assertFalse();
      expect(validateRemoteDisplayGeometry(9000, 900).accepted).assertFalse();
    });

    it('normalizes_only_the_local_input_when_a_draft_is_out_of_range', 0, (): void => {
      const normalized = normalizeRemoteDisplayGeometry(3441, 901);
      expect(normalized.width).assertEqual(3440);
      expect(normalized.height).assertEqual(901);
      expect(normalized.accepted).assertTrue();
    });

    it('allows_rdp_desktop_scale_100_to_500_but_keeps_device_scale_fixed', 0, (): void => {
      expect(normalizeRdpDesktopScalePercent(125)).assertEqual(125);
      expect(normalizeRdpDesktopScalePercent(501)).assertEqual(500);
      expect(normalizeRdpDesktopScalePercent(99)).assertEqual(100);
      expect(isRdpDeviceScalePercent(140)).assertTrue();
      expect(isRdpDeviceScalePercent(125)).assertFalse();
      const scale = resolveRdpScaleProfile('custom', 175, 'fixed', 140);
      expect(scale.desktopPercent).assertEqual(175);
      expect(scale.devicePercent).assertEqual(140);
    });

    it('migrates_released_rdp_fields_without_creating_a_custom_request', 0, (): void => {
      const profile = migrateLegacyRdpDisplayProfile('host-1', '1920x1080', 1, '140', 'pc');
      expect(profile.schemaVersion).assertEqual(1);
      expect(profile.resolution.mode).assertEqual('preset');
      expect(profile.resolution.width).assertEqual(1920);
      expect(profile.rdpScale.desktopPercent).assertEqual(140);
      expect(profile.rdpScale.devicePercent).assertEqual(140);
      expect(remoteDisplayProfileRequiresPro(profile)).assertFalse();
    });

    it('requires_pro_for_custom_geometry_or_desktop_scale', 0, (): void => {
      const profile = defaultRemoteDisplayProfile('host-1', 'rdp');
      profile.resolution.mode = 'custom';
      profile.resolution.width = 2560;
      profile.resolution.height = 1080;
      expect(remoteDisplayProfileRequiresPro(profile)).assertTrue();
      profile.resolution.mode = 'preset';
      profile.rdpScale.desktopMode = 'custom';
      profile.rdpScale.desktopPercent = 125;
      expect(remoteDisplayProfileRequiresPro(profile)).assertTrue();
    });

    it('fails_closed_for_unknown_or_unsupported_rustdesk_peers', 0, (): void => {
      expect(rustDeskCustomResolutionDecision({
        peerVersion: '', platform: 'windows', hasDisplayIndex: true,
        hasPermission: true, hasVirtualDisplay: true
      }).allowed).assertFalse();
      expect(rustDeskCustomResolutionDecision({
        peerVersion: '1.2.3', platform: 'windows', hasDisplayIndex: true,
        hasPermission: true, hasVirtualDisplay: true
      }).allowed).assertFalse();
      expect(rustDeskCustomResolutionDecision({
        peerVersion: '1.2.4', platform: 'linux_wayland', hasDisplayIndex: true,
        hasPermission: true, hasVirtualDisplay: true
      }).allowed).assertFalse();
    });

    it('allows_verified_windows_and_x11_custom_requests', 0, (): void => {
      const windows = rustDeskCustomResolutionDecision({
        peerVersion: '1.2.4', platform: 'windows', hasDisplayIndex: true,
        hasPermission: true, hasVirtualDisplay: false
      });
      const x11 = rustDeskCustomResolutionDecision({
        peerVersion: '1.3.0', platform: 'linux_x11', hasDisplayIndex: true,
        hasPermission: true, hasVirtualDisplay: true
      });
      expect(windows.allowed).assertTrue();
      expect(x11.allowed).assertTrue();
    });
  });
}
