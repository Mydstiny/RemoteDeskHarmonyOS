import { describe, it, expect } from '@ohos/hypium';
import { LiveViewMode } from '../../../main/ets/services/LiveViewTypes';
import {
  BackgroundVideoPrewarmInput,
  BackgroundVideoPrewarmMode,
  backgroundVideoPrewarmIntervalMs,
  resolveBackgroundVideoPrewarmMode
} from '../../../main/ets/services/BackgroundVideoPrewarmPolicy';

function baseInput(): BackgroundVideoPrewarmInput {
  return {
    liveViewEnabled: true,
    liveViewMode: LiveViewMode.AVSESSION,
    appBackgrounded: true,
    protocolConnected: true,
    protocol: 'rustdesk',
    hasAudio: false,
    hasVideo: true
  };
}

export default function backgroundVideoPrewarmPolicyTest(): void {
  describe('BackgroundVideoPrewarmPolicy', (): void => {
    it('enables_low_fps_prewarm_only_for_background_live_view_video', 0, (): void => {
      expect(resolveBackgroundVideoPrewarmMode(baseInput()))
        .assertEqual(BackgroundVideoPrewarmMode.LOW_FPS_PREWARM);
    });

    it('disables_when_live_view_is_off_or_app_is_foreground', 0, (): void => {
      const disabled: BackgroundVideoPrewarmInput = baseInput();
      disabled.liveViewEnabled = false;
      expect(resolveBackgroundVideoPrewarmMode(disabled)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const offMode: BackgroundVideoPrewarmInput = baseInput();
      offMode.liveViewMode = LiveViewMode.OFF;
      expect(resolveBackgroundVideoPrewarmMode(offMode)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const foreground: BackgroundVideoPrewarmInput = baseInput();
      foreground.appBackgrounded = false;
      expect(resolveBackgroundVideoPrewarmMode(foreground)).assertEqual(BackgroundVideoPrewarmMode.OFF);
    });

    it('uses_audio_only_when_audio_has_no_video', 0, (): void => {
      const audioOnly: BackgroundVideoPrewarmInput = baseInput();
      audioOnly.hasVideo = false;
      audioOnly.hasAudio = true;
      expect(resolveBackgroundVideoPrewarmMode(audioOnly)).assertEqual(BackgroundVideoPrewarmMode.AUDIO_ONLY);
    });

    it('requires_connected_supported_remote_protocol', 0, (): void => {
      const disconnected: BackgroundVideoPrewarmInput = baseInput();
      disconnected.protocolConnected = false;
      expect(resolveBackgroundVideoPrewarmMode(disconnected)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const ssh: BackgroundVideoPrewarmInput = baseInput();
      ssh.protocol = 'ssh';
      expect(resolveBackgroundVideoPrewarmMode(ssh)).assertEqual(BackgroundVideoPrewarmMode.OFF);
    });

    it('uses_safe_low_power_interval', 0, (): void => {
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.LOW_FPS_PREWARM)).assertEqual(1000);
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.AUDIO_ONLY)).assertEqual(0);
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.OFF)).assertEqual(0);
    });
  });
}
