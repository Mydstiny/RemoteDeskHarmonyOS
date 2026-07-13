import { describe, it, expect } from '@ohos/hypium';
import {
  avSessionTypeForRemoteMedia,
  backgroundModesForRemoteMedia,
  RemoteSessionMediaKind,
  resolveRemoteSessionMediaKind,
  shouldRestartLiveViewForMediaChange,
  shouldUseAvSessionForMedia
} from '../main/ets/services/RemoteSessionMediaStatePolicy';
import { LiveViewMode, resolveLiveViewMode } from '../main/ets/services/LiveViewTypes';

export default function remoteSessionMediaStatePolicyTest(): void {
  describe('RemoteSessionMediaStatePolicy', (): void => {
    it('audio_takes_precedence_over_video_for_media_kind', 0, (): void => {
      expect(resolveRemoteSessionMediaKind({ hasAudio: true, hasVideo: true }))
        .assertEqual(RemoteSessionMediaKind.AUDIO);
      expect(resolveRemoteSessionMediaKind({ hasAudio: false, hasVideo: true }))
        .assertEqual(RemoteSessionMediaKind.VIDEO);
      expect(resolveRemoteSessionMediaKind({ hasAudio: false, hasVideo: false }))
        .assertEqual(RemoteSessionMediaKind.NONE);
    });

    it('adds_audio_playback_for_actual_audio_or_video_media', 0, (): void => {
      expect(backgroundModesForRemoteMedia({ hasAudio: false, hasVideo: false }).join(','))
        .assertEqual('multiDeviceConnection');
      expect(backgroundModesForRemoteMedia({ hasAudio: false, hasVideo: true }).join(','))
        .assertEqual('multiDeviceConnection,audioPlayback');
      expect(backgroundModesForRemoteMedia({ hasAudio: true, hasVideo: false }).join(','))
        .assertEqual('multiDeviceConnection,audioPlayback');
    });

    it('uses_avsession_only_when_preferred_and_media_exists', 0, (): void => {
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: false, hasVideo: true }))
        .assertTrue();
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: true, hasVideo: false }))
        .assertTrue();
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: false, hasVideo: false }))
        .assertFalse();
      expect(shouldUseAvSessionForMedia(LiveViewMode.NOTIFICATION, { hasAudio: true, hasVideo: true }))
        .assertFalse();
    });

    it('live_view_mode_uses_avsession_for_audio_or_video_media', 0, (): void => {
      expect(resolveLiveViewMode(LiveViewMode.AVSESSION, true, false))
        .assertEqual(LiveViewMode.AVSESSION);
      expect(resolveLiveViewMode(LiveViewMode.AVSESSION, false, true))
        .assertEqual(LiveViewMode.AVSESSION);
      expect(resolveLiveViewMode(LiveViewMode.AVSESSION, false, false))
        .assertEqual(LiveViewMode.NOTIFICATION);
    });

    it('uses_one_video_avsession_type_for_audio_and_video_media', 0, (): void => {
      expect(avSessionTypeForRemoteMedia({ hasAudio: true, hasVideo: false }))
        .assertEqual('video');
      expect(avSessionTypeForRemoteMedia({ hasAudio: false, hasVideo: true }))
        .assertEqual('video');
      expect(avSessionTypeForRemoteMedia({ hasAudio: false, hasVideo: false }))
        .assertEqual('');
    });

    it('does_not_restart_avsession_when_video_session_gains_audio', 0, (): void => {
      expect(shouldRestartLiveViewForMediaChange(
        LiveViewMode.AVSESSION,
        RemoteSessionMediaKind.VIDEO,
        LiveViewMode.AVSESSION,
        RemoteSessionMediaKind.AUDIO
      )).assertFalse();
      expect(shouldRestartLiveViewForMediaChange(
        LiveViewMode.NOTIFICATION,
        RemoteSessionMediaKind.VIDEO,
        LiveViewMode.AVSESSION,
        RemoteSessionMediaKind.VIDEO
      )).assertTrue();
    });
  });
}
