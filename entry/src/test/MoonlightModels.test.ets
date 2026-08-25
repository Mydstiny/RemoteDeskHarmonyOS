import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  defaultMoonlightSettings,
  MoonlightAddress,
  MoonlightCodecPreference,
  MoonlightHost,
  MoonlightIdentityMetadata,
  MoonlightInputControlMode,
  MoonlightProfile,
  MoonlightTrustCandidate,
  moonlightAddressKey,
  moonlightHostIsValid,
  moonlightIdentityMetadataIsValid,
  moonlightInputControlMode,
  normalizeMoonlightSettingsForLocalStorage,
  moonlightProfileIsValid,
  moonlightSettingsAreValid,
  moonlightTrustCandidateIsValid
} from '../main/ets/model/MoonlightModels';

function validHost(): MoonlightHost {
  const address: MoonlightAddress = { host: '192.0.2.10', family: 'ipv4', port: 47989 };
  return {
    id: 'moonlight-host-1',
    serverUuid: 'server-uuid-1',
    displayName: 'Living Room PC',
    addresses: [address],
    preferredAddressKey: moonlightAddressKey(address),
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  };
}

export default function moonlightModelsTest(): void {
  describe('MoonlightModels', (): void => {
    it('uses_fail_closed_safe_defaults', 0, (): void => {
      const settings = defaultMoonlightSettings();
      expect(settings.video.codecPreference).assertEqual('auto');
      expect(settings.video.hdr).assertFalse();
      expect(settings.video.yuv444).assertFalse();
      expect(settings.video.adaptiveResolution).assertEqual('host');
      expect(settings.audio.channels).assertEqual('stereo');
      expect(settings.input.enableRumble).assertFalse();
      expect(settings.input.captureKeyboard).assertFalse();
      expect(settings.input.controlMode).assertEqual('adaptive');
      expect(settings.network.allowLegacySha1).assertFalse();
      expect(settings.network.meteredNetwork).assertEqual('ask');
      expect(settings.security.blockCertificateChanges).assertTrue();
      expect(settings.security.identityStorage).assertEqual('localSecure');
      expect(moonlightSettingsAreValid(settings)).assertTrue();
    });

    it('maps_legacy_input_records_without_rejecting_old_local_or_cloud_data', 0,
      (): void => {
        const legacyTouch = defaultMoonlightSettings();
        legacyTouch.input.controlMode = undefined;
        legacyTouch.input.touchMode = 'touch';
        expect(moonlightSettingsAreValid(legacyTouch)).assertTrue();
        expect(normalizeMoonlightSettingsForLocalStorage(
          legacyTouch).input.controlMode).assertEqual('adaptive');

        const legacyPointer = defaultMoonlightSettings();
        legacyPointer.input.controlMode = undefined;
        legacyPointer.input.touchMode = 'relativeMouse';
        expect(moonlightSettingsAreValid(legacyPointer)).assertTrue();
        expect(normalizeMoonlightSettingsForLocalStorage(
          legacyPointer).input.controlMode).assertEqual('trackpad');
        expect(moonlightInputControlMode(undefined, 'absoluteMouse')).assertEqual('trackpad');
        expect(moonlightInputControlMode('keyboardMouse', 'touch')).assertEqual('keyboardMouse');

        legacyPointer.input.controlMode = 'unsupported' as MoonlightInputControlMode;
        expect(moonlightSettingsAreValid(legacyPointer)).assertFalse();
      });

    it('keeps_legacy_resolution_records_valid_and_accepts_additive_adaptive_intent', 0,
      (): void => {
        const settings = defaultMoonlightSettings();
        settings.video.adaptiveResolution = undefined;
        expect(moonlightSettingsAreValid(settings)).assertTrue();
        settings.video.adaptiveResolution = 'device';
        settings.video.resolutionMode = 'custom';
        expect(moonlightSettingsAreValid(settings)).assertTrue();
      });

    it('keeps_common_display_and_pip_ownership_out_of_new_local_settings', 0, (): void => {
      const settings = defaultMoonlightSettings();
      expect(settings.video.scalingMode === undefined).assertTrue();
      expect(settings.background.allowPip === undefined).assertTrue();
      settings.video.scalingMode = 'fill';
      settings.background.allowPip = true;
      expect(moonlightSettingsAreValid(settings)).assertTrue();
      const normalized = normalizeMoonlightSettingsForLocalStorage(settings);
      expect(normalized.video.scalingMode === undefined).assertTrue();
      expect(normalized.background.allowPip === undefined).assertTrue();
    });

    it('accepts_a_bounded_host_and_rejects_duplicate_or_missing_addresses', 0, (): void => {
      const host = validHost();
      expect(moonlightHostIsValid(host)).assertTrue();
      host.addresses.push({ host: '192.0.2.10', family: 'ipv4', port: 47989 });
      expect(moonlightHostIsValid(host)).assertFalse();
      host.addresses = [];
      expect(moonlightHostIsValid(host)).assertFalse();
    });

    it('accepts_legacy_or_custom_https_ports_and_rejects_invalid_values', 0, (): void => {
      const host = validHost();
      expect(moonlightHostIsValid(host)).assertTrue();
      host.httpsPort = 48084;
      expect(moonlightHostIsValid(host)).assertTrue();
      host.httpsPort = 0;
      expect(moonlightHostIsValid(host)).assertFalse();
      host.httpsPort = 65536;
      expect(moonlightHostIsValid(host)).assertFalse();
    });

    it('rejects_unknown_enums_and_out_of_range_stream_values', 0, (): void => {
      const settings = defaultMoonlightSettings();
      settings.video.codecPreference = 'vp9' as MoonlightCodecPreference;
      expect(moonlightSettingsAreValid(settings)).assertFalse();
      settings.video.codecPreference = 'h264';
      settings.video.fps = 241;
      expect(moonlightSettingsAreValid(settings)).assertFalse();
      settings.video.fps = 60;
      settings.audio.volume = 1.01;
      expect(moonlightSettingsAreValid(settings)).assertFalse();
    });

    it('keeps_profiles_bounded_and_free_of_runtime_session_fields', 0, (): void => {
      const profile: MoonlightProfile = {
        id: 'profile-1', hostId: 'moonlight-host-1', appId: 'app-1', titleSnapshot: 'Game',
        streamOverrides: { codecPreference: 'h264', fps: 60, bitrateKbps: 25000 },
        inputOverrides: { touchMode: 'relativeMouse', controllerSlot: 0 },
        favorite: true, userOrder: 0, lastUsedAt: 0
      };
      expect(moonlightProfileIsValid(profile)).assertTrue();
      profile.streamOverrides.bitrateKbps = 999;
      expect(moonlightProfileIsValid(profile)).assertFalse();
      profile.streamOverrides.bitrateKbps = 25000;
      profile.titleSnapshot = 'x'.repeat(257);
      expect(moonlightProfileIsValid(profile)).assertFalse();
    });

    it('validates_trust_candidates_without_treating_them_as_trust_receipts', 0, (): void => {
      const candidate: MoonlightTrustCandidate = {
        hostId: 'host-1', serverUuid: 'server-1',
        serverCertificateSha256: 'a'.repeat(64), pairingGeneration: 1, candidateObservedAt: 10
      };
      expect(moonlightTrustCandidateIsValid(candidate)).assertTrue();
      candidate.serverCertificateSha256 = 'not-a-fingerprint';
      expect(moonlightTrustCandidateIsValid(candidate)).assertFalse();
    });

    it('binds_identity_metadata_to_an_owner_and_local_secure_reference', 0, (): void => {
      const metadata: MoonlightIdentityMetadata = {
        identityVersion: 1,
        certificateSha256: 'b'.repeat(64),
        ownerScopeFingerprint: 'c'.repeat(64),
        storageMode: 'localSecure',
        localSecureStoreRef: 'moonlight-owner-key-alias',
        createdAt: 100,
        rotatedAt: 0
      };
      expect(moonlightIdentityMetadataIsValid(metadata)).assertTrue();
      metadata.ownerScopeFingerprint = '';
      expect(moonlightIdentityMetadataIsValid(metadata)).assertFalse();
      metadata.ownerScopeFingerprint = 'c'.repeat(64);
      metadata.rotatedAt = 99;
      expect(moonlightIdentityMetadataIsValid(metadata)).assertFalse();
    });
  });
}
