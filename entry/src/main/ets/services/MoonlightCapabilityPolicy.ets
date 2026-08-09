import {
  MoonlightAudioChannels,
  MoonlightCodecPreference,
  MoonlightResolutionMode
} from '../model/MoonlightModels';

export type MoonlightCapabilityStatus = 'supported' | 'unsupported' | 'pending';
export type MoonlightCapabilitySource = 'sdk' | 'deviceProbe' | 'host' | 'network' | 'release';

export interface MoonlightCapabilityEvidence {
  status: MoonlightCapabilityStatus;
  source: MoonlightCapabilitySource;
  version: string;
  reason: string;
  expiresAt: number;
}

export interface MoonlightPlatformCapabilities {
  h264: MoonlightCapabilityEvidence;
  hevc: MoonlightCapabilityEvidence;
  av1: MoonlightCapabilityEvidence;
  hdr: MoonlightCapabilityEvidence;
  yuv444: MoonlightCapabilityEvidence;
  opusStereo: MoonlightCapabilityEvidence;
  surround51: MoonlightCapabilityEvidence;
  surround71: MoonlightCapabilityEvidence;
  relativePointer: MoonlightCapabilityEvidence;
  gameControllerInput: MoonlightCapabilityEvidence;
  controllerRumble: MoonlightCapabilityEvidence;
  pip: MoonlightCapabilityEvidence;
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
}

export interface MoonlightHostCapabilities {
  h264: boolean;
  hevc: boolean;
  av1: boolean;
  hdr: boolean;
  yuv444: boolean;
  opusStereo: boolean;
  surround51: boolean;
  surround71: boolean;
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  sunshineVersionSafe: boolean;
}

export interface MoonlightNetworkCapabilities {
  controlReachable: boolean;
  udpReachable: boolean;
  metered: boolean;
  userApprovedMetered: boolean;
}

export interface MoonlightEffectiveCapabilities {
  codecs: MoonlightCodecPreference[];
  resolutions: MoonlightResolutionMode[];
  audioChannels: MoonlightAudioChannels[];
  hdr: boolean;
  yuv444: boolean;
  relativePointer: boolean;
  gameControllerInput: boolean;
  controllerRumble: boolean;
  pip: boolean;
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  hostControlReady: boolean;
  streamingTransportReady: boolean;
  reasons: string[];
}

export function pendingMoonlightCapability(reason: string): MoonlightCapabilityEvidence {
  return { status: 'pending', source: 'sdk', version: '', reason: reason, expiresAt: 0 };
}

export function defaultMoonlightPlatformCapabilities(): MoonlightPlatformCapabilities {
  const pending: string = '尚未在当前应用身份和目标实机完成能力探针';
  const unavailable: MoonlightCapabilityEvidence = {
    status: 'unsupported', source: 'sdk', version: 'API 23',
    reason: 'API 23 Game Controller Kit 未提供该反馈能力', expiresAt: 0
  };
  return {
    h264: pendingMoonlightCapability(pending),
    hevc: pendingMoonlightCapability(pending),
    av1: pendingMoonlightCapability(pending),
    hdr: pendingMoonlightCapability(pending),
    yuv444: pendingMoonlightCapability(pending),
    opusStereo: pendingMoonlightCapability(pending),
    surround51: pendingMoonlightCapability(pending),
    surround71: pendingMoonlightCapability(pending),
    relativePointer: pendingMoonlightCapability(pending),
    gameControllerInput: pendingMoonlightCapability(pending),
    controllerRumble: unavailable,
    pip: pendingMoonlightCapability(pending),
    maxWidth: 0,
    maxHeight: 0,
    maxFps: 0
  };
}

function supported(evidence: MoonlightCapabilityEvidence): boolean {
  return evidence.status === 'supported';
}

function boundedMinimum(first: number, second: number): number {
  if (!Number.isFinite(first) || !Number.isFinite(second) || first <= 0 || second <= 0) { return 0; }
  return Math.min(first, second);
}

export function resolveMoonlightCapabilities(
  platform: MoonlightPlatformCapabilities,
  host: MoonlightHostCapabilities,
  network: MoonlightNetworkCapabilities
): MoonlightEffectiveCapabilities {
  const codecs: MoonlightCodecPreference[] = [];
  if (supported(platform.h264) && host.h264) { codecs.push('h264'); }
  if (supported(platform.hevc) && host.hevc) { codecs.push('hevc'); }
  if (supported(platform.av1) && host.av1) { codecs.push('av1'); }

  const maxWidth: number = boundedMinimum(platform.maxWidth, host.maxWidth);
  const maxHeight: number = boundedMinimum(platform.maxHeight, host.maxHeight);
  const maxFps: number = boundedMinimum(platform.maxFps, host.maxFps);
  const resolutions: MoonlightResolutionMode[] = ['host'];
  if (maxWidth >= 1280 && maxHeight >= 720) { resolutions.push('720p'); }
  if (maxWidth >= 1920 && maxHeight >= 1080) { resolutions.push('1080p'); }
  if (maxWidth >= 2560 && maxHeight >= 1440) { resolutions.push('1440p'); }
  if (maxWidth >= 3840 && maxHeight >= 2160) { resolutions.push('2160p'); }
  if (maxWidth > 0 && maxHeight > 0) { resolutions.push('custom'); }

  const channels: MoonlightAudioChannels[] = [];
  if (supported(platform.opusStereo) && host.opusStereo) { channels.push('stereo'); }
  if (supported(platform.surround51) && host.surround51) { channels.push('surround51'); }
  if (supported(platform.surround71) && host.surround71) { channels.push('surround71'); }

  const reasons: string[] = [];
  if (!host.sunshineVersionSafe) { reasons.push('sunshine_version_unsafe'); }
  if (!network.controlReachable) { reasons.push('control_unreachable'); }
  if (!network.udpReachable) { reasons.push('udp_unverified_or_unreachable'); }
  if (network.metered && !network.userApprovedMetered) { reasons.push('metered_network_confirmation_required'); }
  if (codecs.indexOf('h264') < 0) { reasons.push('h264_mvp_unavailable'); }
  if (channels.indexOf('stereo') < 0) { reasons.push('opus_stereo_mvp_unavailable'); }

  const hostControlReady: boolean = host.sunshineVersionSafe && network.controlReachable;
  const streamingTransportReady: boolean = hostControlReady && network.udpReachable &&
    (!network.metered || network.userApprovedMetered) &&
    codecs.indexOf('h264') >= 0 && channels.indexOf('stereo') >= 0;
  return {
    codecs: codecs,
    resolutions: resolutions,
    audioChannels: channels,
    hdr: supported(platform.hdr) && host.hdr,
    yuv444: supported(platform.yuv444) && host.yuv444,
    relativePointer: supported(platform.relativePointer),
    gameControllerInput: supported(platform.gameControllerInput),
    controllerRumble: supported(platform.controllerRumble),
    pip: supported(platform.pip),
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    maxFps: maxFps,
    hostControlReady: hostControlReady,
    streamingTransportReady: streamingTransportReady,
    reasons: reasons
  };
}
