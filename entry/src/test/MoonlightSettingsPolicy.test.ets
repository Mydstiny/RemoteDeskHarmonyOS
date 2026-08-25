import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { defaultMoonlightSettings, MoonlightSettings } from '../main/ets/model/MoonlightModels';
import {
  MoonlightEffectiveCapabilities
} from '../main/ets/services/MoonlightCapabilityPolicy';
import {
  decodeMoonlightEffectiveSettings,
  encodeMoonlightEffectiveSettings,
  MoonlightSettingsLayer,
  resolveEffectiveMoonlightSettings,
  resolveMoonlightProductSettings
} from '../main/ets/services/MoonlightSettingsPolicy';

function mvpCapabilities(): MoonlightEffectiveCapabilities {
  return {
    codecs: ['h264'], resolutions: ['host', '720p', '1080p', 'custom'],
    audioChannels: ['stereo'], hdr: false, yuv444: false,
    relativePointer: false, gameControllerInput: false, controllerRumble: false, pip: false,
    maxWidth: 1920, maxHeight: 1080, maxFps: 60,
    hostControlReady: true, streamingTransportReady: true, reasons: []
  };
}

function layer(scope: 'host' | 'profile' | 'session', values: MoonlightSettings,
  paths: string[]): MoonlightSettingsLayer {
  return { scope: scope, values: values, overriddenPaths: paths };
}

export default function moonlightSettingsPolicyTest(): void {
  describe('MoonlightSettingsPolicy', (): void => {
    it('applies_global_host_profile_session_precedence', 0, (): void => {
      const global = defaultMoonlightSettings();
      const host = defaultMoonlightSettings();
      const profile = defaultMoonlightSettings();
      const session = defaultMoonlightSettings();
      host.video.bitrateKbps = 30000;
      profile.video.bitrateKbps = 40000;
      session.video.bitrateKbps = 50000;
      const result = resolveEffectiveMoonlightSettings(global,
        layer('host', host, ['video.bitrateKbps']),
        layer('profile', profile, ['video.bitrateKbps']),
        layer('session', session, ['video.bitrateKbps']), mvpCapabilities());
      expect(result.requested.video.bitrateKbps).assertEqual(50000);
      expect(global.video.bitrateKbps).assertEqual(20000);
    });

    it('resets_to_inheritance_when_a_path_is_removed', 0, (): void => {
      const global = defaultMoonlightSettings();
      global.video.fps = 30;
      const host = defaultMoonlightSettings();
      host.video.fps = 60;
      expect(resolveEffectiveMoonlightSettings(global,
        layer('host', host, ['video.fps']), null, null, mvpCapabilities())
        .requested.video.fps).assertEqual(60);
      expect(resolveEffectiveMoonlightSettings(global,
        layer('host', host, []), null, null, mvpCapabilities())
        .requested.video.fps).assertEqual(30);
    });

    it('clips_unavailable_codec_hdr_audio_input_and_rumble', 0, (): void => {
      const global = defaultMoonlightSettings();
      global.video.codecPreference = 'av1';
      global.video.resolutionMode = '2160p';
      global.video.hdr = true;
      global.video.yuv444 = true;
      global.audio.channels = 'surround71';
      global.input.touchMode = 'relativeMouse';
      global.input.enableRumble = true;
      const result = resolveEffectiveMoonlightSettings(global, null, null, null, mvpCapabilities());
      expect(result.effective.video.codecPreference).assertEqual('h264');
      expect(result.effective.video.resolutionMode).assertEqual('1080p');
      expect(result.effective.video.hdr).assertFalse();
      expect(result.effective.video.yuv444).assertFalse();
      expect(result.effective.audio.channels).assertEqual('stereo');
      expect(result.requested.input.touchMode).assertEqual('relativeMouse');
      expect(result.effective.input.touchMode).assertEqual('absoluteMouse');
      expect(result.effective.input.enableRumble).assertFalse();
      expect(result.adjustments.length >= 7).assertTrue();
    });

    it('does_not_allow_profile_or_session_to_override_security_identity', 0, (): void => {
      const global = defaultMoonlightSettings();
      const profile = defaultMoonlightSettings();
      profile.security.identityStorage = 'cloudEncryptedPending';
      const session = defaultMoonlightSettings();
      session.network.allowLegacySha1 = true;
      const result = resolveEffectiveMoonlightSettings(global, null,
        layer('profile', profile, ['security.identityStorage']),
        layer('session', session, ['network.allowLegacySha1']), mvpCapabilities());
      expect(result.requested.security.identityStorage).assertEqual('localSecure');
      expect(result.requested.network.allowLegacySha1).assertFalse();
      expect(result.adjustments.length >= 2).assertTrue();
    });

    it('keeps_session_overrides_ephemeral_and_does_not_mutate_inputs', 0, (): void => {
      const global = defaultMoonlightSettings();
      const session = defaultMoonlightSettings();
      session.audio.enabled = false;
      const result = resolveEffectiveMoonlightSettings(global, null, null,
        layer('session', session, ['audio.enabled']), mvpCapabilities());
      expect(result.requested.audio.enabled).assertFalse();
      expect(global.audio.enabled).assertTrue();
      expect(session.audio.enabled).assertFalse();
    });

    it('creates_one_bounded_product_snapshot_and_fences_controller_slot_zero', 0, (): void => {
      const requested = defaultMoonlightSettings();
      requested.video.codecPreference = 'av1';
      requested.video.hdr = true;
      requested.video.yuv444 = true;
      requested.audio.channels = 'surround71';
      requested.input.controllerSlot = 3;
      requested.video.resolutionMode = '2160p';
      requested.video.fps = 120;
      requested.video.latencyMode = 'smooth';
      requested.network.streamEncryption = 'required';
      requested.input.forwardSystemShortcuts = true;
      requested.input.controlMode = 'keyboardMouse';
      requested.background.noSurfaceVideo = 'pause';
      requested.diagnostics.logLevel = 'debug';
      const resolved = resolveMoonlightProductSettings(requested);
      expect(resolved.requested.video.codecPreference).assertEqual('av1');
      expect(resolved.effective.video.codecPreference).assertEqual('h264');
      expect(resolved.effective.video.hdr).assertFalse();
      expect(resolved.effective.video.yuv444).assertFalse();
      expect(resolved.effective.audio.channels).assertEqual('stereo');
      expect(resolved.effective.input.controllerSlot).assertEqual(0);
      expect(resolved.effective.video.resolutionMode).assertEqual('1080p');
      expect(resolved.effective.video.fps).assertEqual(60);
      expect(resolved.requested.video.latencyMode).assertEqual('smooth');
      expect(resolved.effective.video.latencyMode).assertEqual('lowLatency');
      expect(resolved.effective.network.streamEncryption).assertEqual('auto');
      expect(resolved.requested.input.forwardSystemShortcuts).assertTrue();
      expect(resolved.effective.input.forwardSystemShortcuts).assertFalse();
      expect(resolved.requested.input.controlMode).assertEqual('keyboardMouse');
      expect(resolved.effective.input.controlMode).assertEqual('keyboardMouse');
      expect(resolved.requested.background.noSurfaceVideo).assertEqual('pause');
      expect(resolved.effective.background.noSurfaceVideo).assertEqual('drop');
      expect(resolved.requested.diagnostics.logLevel).assertEqual('debug');
      expect(resolved.effective.diagnostics.logLevel).assertEqual('error');
      const encoded: string = encodeMoonlightEffectiveSettings(resolved);
      expect(encoded.length > 0).assertTrue();
      const decoded = decodeMoonlightEffectiveSettings(encoded);
      expect((decoded as Object) !== null).assertTrue();
      expect(decoded?.effective.input.controlMode).assertEqual('keyboardMouse');
      expect(decodeMoonlightEffectiveSettings(encoded + 'x')).assertNull();
    });

    it('maps_verified_hardware_codecs_and_continuous_frame_rate_into_product_settings', 0,
      (): void => {
        const requested = defaultMoonlightSettings();
        requested.video.codecPreference = 'hevc';
        requested.video.resolutionMode = '2160p';
        requested.video.adaptiveResolution = 'off';
        requested.video.fps = 117;
        const resolved = resolveMoonlightProductSettings(requested, {
          h264: { available: true, maxWidth: 4096, maxHeight: 2160, maxFps: 120 },
          hevc: { available: true, maxWidth: 7680, maxHeight: 4320, maxFps: 240 },
          av1: { available: true, maxWidth: 7680, maxHeight: 4320, maxFps: 180 }
        });
        expect(resolved.effective.video.codecPreference).assertEqual('hevc');
        expect(resolved.effective.video.resolutionMode).assertEqual('2160p');
        expect(resolved.effective.video.fps).assertEqual(117);
      });
  });
}
