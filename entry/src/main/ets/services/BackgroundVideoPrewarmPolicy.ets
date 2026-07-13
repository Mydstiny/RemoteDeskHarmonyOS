import { LiveViewMode } from './LiveViewTypes';

export enum BackgroundVideoPrewarmMode {
  OFF = 0,
  LOW_FPS_PREWARM = 1,
  AUDIO_ONLY = 2
}

export interface BackgroundVideoPrewarmInput {
  liveViewEnabled: boolean;
  liveViewMode: number;
  appBackgrounded: boolean;
  protocolConnected: boolean;
  protocol: string;
  hasAudio: boolean;
  hasVideo: boolean;
}

export function resolveBackgroundVideoPrewarmMode(input: BackgroundVideoPrewarmInput):
  BackgroundVideoPrewarmMode {
  if (!input.liveViewEnabled || input.liveViewMode === LiveViewMode.OFF) {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (!input.appBackgrounded || !input.protocolConnected) {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (input.protocol !== 'rdp' && input.protocol !== 'rustdesk') {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (input.hasVideo) {
    return BackgroundVideoPrewarmMode.LOW_FPS_PREWARM;
  }
  if (input.hasAudio) {
    return BackgroundVideoPrewarmMode.AUDIO_ONLY;
  }
  return BackgroundVideoPrewarmMode.OFF;
}

export function backgroundVideoPrewarmIntervalMs(mode: BackgroundVideoPrewarmMode): number {
  if (mode === BackgroundVideoPrewarmMode.LOW_FPS_PREWARM) {
    return 1000;
  }
  return 0;
}
