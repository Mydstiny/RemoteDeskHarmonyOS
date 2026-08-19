import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  defaultMoonlightPlatformCapabilities,
  MoonlightCapabilityEvidence,
  MoonlightHostCapabilities,
  MoonlightNetworkCapabilities,
  resolveMoonlightCapabilities
} from '../main/ets/services/MoonlightCapabilityPolicy';
import {
  defaultMoonlightFeatureInputs,
  resolveMoonlightFeatureSnapshot
} from '../main/ets/services/MoonlightFeaturePolicy';

function supported(version: string = 'probe-1'): MoonlightCapabilityEvidence {
  return { status: 'supported', source: 'deviceProbe', version: version, reason: '', expiresAt: 0 };
}

function mvpHost(): MoonlightHostCapabilities {
  return {
    h264: true, hevc: true, av1: false, hdr: false, yuv444: false,
    opusStereo: true, surround51: false, surround71: false,
    maxWidth: 3840, maxHeight: 2160, maxFps: 120, sunshineVersionSafe: true
  };
}

function lan(): MoonlightNetworkCapabilities {
  return { controlReachable: true, udpReachable: true, metered: false, userApprovedMetered: false };
}

export default function moonlightCapabilityPolicyTest(): void {
  describe('MoonlightCapabilityPolicy', (): void => {
    it('defaults_every_unproven_runtime_capability_closed', 0, (): void => {
      const platform = defaultMoonlightPlatformCapabilities();
      expect(platform.h264.status).assertEqual('pending');
      expect(platform.opusStereo.status).assertEqual('pending');
      expect(platform.controllerRumble.status).assertEqual('unsupported');
      const effective = resolveMoonlightCapabilities(platform, mvpHost(), lan());
      expect(effective.streamingTransportReady).assertFalse();
      expect(effective.codecs.length).assertEqual(0);
    });

    it('intersects_device_host_and_network_for_the_mvp', 0, (): void => {
      const platform = defaultMoonlightPlatformCapabilities();
      platform.h264 = supported();
      platform.hevc = supported();
      platform.opusStereo = supported();
      platform.maxWidth = 2560;
      platform.maxHeight = 1440;
      platform.maxFps = 60;
      const effective = resolveMoonlightCapabilities(platform, mvpHost(), lan());
      expect(effective.streamingTransportReady).assertTrue();
      expect(effective.codecs.indexOf('h264') >= 0).assertTrue();
      expect(effective.codecs.indexOf('hevc') >= 0).assertTrue();
      expect(effective.resolutions.indexOf('1440p') >= 0).assertTrue();
      expect(effective.resolutions.indexOf('2160p')).assertEqual(-1);
      expect(effective.maxFps).assertEqual(60);
    });

    it('requires_explicit_metered_network_approval', 0, (): void => {
      const platform = defaultMoonlightPlatformCapabilities();
      platform.h264 = supported();
      platform.opusStereo = supported();
      platform.maxWidth = 1920;
      platform.maxHeight = 1080;
      platform.maxFps = 60;
      const network = lan();
      network.metered = true;
      expect(resolveMoonlightCapabilities(platform, mvpHost(), network).streamingTransportReady)
        .assertFalse();
      network.userApprovedMetered = true;
      expect(resolveMoonlightCapabilities(platform, mvpHost(), network).streamingTransportReady)
        .assertTrue();
    });

    it('prevents_any_child_flag_from_overriding_a_missing_parent_gate', 0, (): void => {
      const inputs = defaultMoonlightFeatureInputs();
      inputs.streamingImplementationReady = true;
      inputs.streamingCapabilityReady = true;
      inputs.sessionLifecycleReady = true;
      inputs.releaseGateReady = true;
      expect(resolveMoonlightFeatureSnapshot(inputs).moonlightProtocolAvailable).assertFalse();

      inputs.hostControlImplementationReady = true;
      inputs.hostControlCapabilityReady = true;
      inputs.dataLifecycleReady = true;
      expect(resolveMoonlightFeatureSnapshot(inputs).moonlightProtocolAvailable).assertTrue();
    });

    it('keeps_cloud_identity_stricter_than_plain_schema_readiness', 0, (): void => {
      const inputs = defaultMoonlightFeatureInputs();
      inputs.cloudSchemaDeployedAllEnvironments = true;
      expect(resolveMoonlightFeatureSnapshot(inputs).moonlightCloudSchemaReady).assertTrue();
      expect(resolveMoonlightFeatureSnapshot(inputs).moonlightCloudIdentityReady).assertFalse();
      inputs.remoteCryptoLifecycleReady = true;
      inputs.identityThreatModelApproved = true;
      inputs.dataLifecycleReady = true;
      expect(resolveMoonlightFeatureSnapshot(inputs).moonlightCloudIdentityReady).assertTrue();
    });
  });
}
