import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightSettings,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  moonlightAddressKey,
  moonlightHostIsValid,
  moonlightSettingsAreValid
} from '../model/MoonlightModels';
import { AccountSessionLease } from './AccountScopePolicy';
import {
  MoonlightHostContext,
  MoonlightNativeLaunchConfiguration
} from './MoonlightHostService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint
} from './MoonlightRuntimeSupport';

const MAX_SAFE_INTEGER: number = 9007199254740991;

export function moonlightSelectedAddress(host: MoonlightHost,
  settings: MoonlightSettings): MoonlightAddress | null {
  if (!moonlightHostIsValid(host) || !moonlightSettingsAreValid(settings) ||
      host.addresses.length === 0) {
    return null;
  }
  const family: string = settings.network.preferredAddressFamily;
  if (family === 'ipv4' || family === 'ipv6') {
    for (let index: number = 0; index < host.addresses.length; index++) {
      if (host.addresses[index].family === family) { return host.addresses[index]; }
    }
  }
  for (let index: number = 0; index < host.addresses.length; index++) {
    if (moonlightAddressKey(host.addresses[index]) === host.preferredAddressKey) {
      return host.addresses[index];
    }
  }
  return host.addresses[0];
}

export function moonlightSelectedHostAddress(host: MoonlightHost,
  settings: MoonlightSettings): string {
  const selected: MoonlightAddress | null = moonlightSelectedAddress(host, settings);
  if (selected === null) { return ''; }
  const address: string = selected.family === 'ipv6'
    ? '[' + selected.host + ']' : selected.host;
  return address + ':' + selected.port.toString();
}

export function moonlightRuntimeContext(host: MoonlightHost, lease: AccountSessionLease,
  ownerToken: number, generation: number, certificateSha256: string,
  settings: MoonlightSettings, timeoutMs: number = 30000): MoonlightHostContext | null {
  const selected: MoonlightAddress | null = moonlightSelectedAddress(host, settings);
  if (selected === null || !/^[0-9a-f]{64}$/.test(certificateSha256) ||
      lease.ownerScopeId.trim() === '' || !Number.isSafeInteger(ownerToken) ||
      ownerToken <= 0 || !Number.isSafeInteger(generation) || generation <= 0 ||
      !Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 120000) {
    return null;
  }
  return {
    lease: lease,
    ownerScopeFingerprint: moonlightOwnerScopeFingerprint(lease.ownerScopeId),
    ownerToken: ownerToken,
    generation: generation,
    localHostId: host.id,
    hostId: host.serverUuid,
    serverUuid: host.serverUuid,
    installationId: moonlightInstallationId(lease.storeIdentity),
    pinnedCertificateSha256: certificateSha256,
    endpoint: {
      serverName: selected.family === 'hostname' ? selected.host : host.displayName,
      addresses: [{
        value: selected.host,
        family: selected.family === 'ipv4' ? 'ipv4' :
          selected.family === 'ipv6' ? 'ipv6' : 'unspecified'
      }],
      httpPort: selected.port,
      httpsPort: host.httpsPort === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
        host.httpsPort,
      pinnedTrustAvailable: true,
      allowHttpPairingCandidate: false
    },
    timeoutMs: timeoutMs
  };
}

export function moonlightLaunchConfiguration(
  settings: MoonlightSettings, deviceWidth: number = 0,
  deviceHeight: number = 0, decoderMaxWidth: number = 1920,
  decoderMaxHeight: number = 1080): MoonlightNativeLaunchConfiguration {
  const video = settings.video;
  const audio = settings.audio;
  let width: number = 1920;
  let height: number = 1080;
  const adaptive: string = video.adaptiveResolution === undefined ?
    (video.resolutionMode === 'host' ? 'host' : 'off') : video.adaptiveResolution;
  if (adaptive === 'host' && video.adaptiveResolution === 'host') {
    width = video.customWidth;
    height = video.customHeight;
  } else if (adaptive === 'device' && Number.isFinite(deviceWidth) && Number.isFinite(deviceHeight) &&
      deviceWidth >= 320 && deviceHeight >= 240) {
    // Device-adaptive resolution is a runtime property, not a durable custom
    // resolution. Reusing customWidth/customHeight here lets a phone's stale
    // 1920x1080 (or a cloud-synced value from another device) force a 16:9
    // stream onto a 16:10 Pad and leaves contain bars on every edge.
    const landscapeWidth: number = Math.max(deviceWidth, deviceHeight);
    const landscapeHeight: number = Math.min(deviceWidth, deviceHeight);
    const boundedDecoderWidth: number = Number.isSafeInteger(decoderMaxWidth) &&
      decoderMaxWidth >= 320 ? Math.min(7680, decoderMaxWidth) : 1920;
    const boundedDecoderHeight: number = Number.isSafeInteger(decoderMaxHeight) &&
      decoderMaxHeight >= 240 ? Math.min(4320, decoderMaxHeight) : 1080;
    const scale: number = Math.min(1, boundedDecoderWidth / landscapeWidth,
      boundedDecoderHeight / landscapeHeight);
    width = landscapeWidth * scale;
    height = landscapeHeight * scale;
    width = Math.floor(width / 2) * 2;
    height = Math.floor(height / 2) * 2;
  } else if (video.resolutionMode === '720p') { width = 1280; height = 720; }
  else if (video.resolutionMode === '1440p') { width = 2560; height = 1440; }
  else if (video.resolutionMode === '2160p') { width = 3840; height = 2160; }
  else if (video.resolutionMode === 'custom') {
    width = video.customWidth;
    height = video.customHeight;
  }
  let surroundAudioInfo: number = 196610;
  if (audio.channels === 'surround51') { surroundAudioInfo = 393279; }
  else if (audio.channels === 'surround71') { surroundAudioInfo = 525887; }
  // The product input runtime owns one stable Sunshine controller slot. Keep
  // the ArkTS launch request identical to the native enforcement so host
  // launch, stream admission and physical/virtual hot handoff cannot observe
  // contradictory controller topology.
  const controllerBitmap: number = 1;
  return {
    width: width,
    height: height,
    refreshRate: video.fps,
    additionalStates: true,
    sops: true,
    hdr: video.hdr,
    playAudioOnHost: audio.playOnHost,
    surroundAudioInfo: surroundAudioInfo,
    remoteControllersBitmap: controllerBitmap,
    gamepadMask: controllerBitmap,
    persistGamepads: true,
    videoCodec: video.codecPreference === 'hevc' ? 'hevc' :
      video.codecPreference === 'av1' ? 'av1' : 'h264',
    resolutionPolicy: adaptive === 'host' ? 'hostCapability' : 'exact'
  };
}

export class MoonlightRuntimeOwnerTokenAllocator {
  private static instance: MoonlightRuntimeOwnerTokenAllocator | null = null;
  private lastToken: number = 0;
  private sequence: number = 0;

  static getInstance(): MoonlightRuntimeOwnerTokenAllocator {
    if (MoonlightRuntimeOwnerTokenAllocator.instance === null) {
      MoonlightRuntimeOwnerTokenAllocator.instance = new MoonlightRuntimeOwnerTokenAllocator();
    }
    return MoonlightRuntimeOwnerTokenAllocator.instance;
  }

  next(nowMs: number = Date.now()): number {
    const safeNow: number = Number.isSafeInteger(nowMs) && nowMs > 0 ? nowMs : Date.now();
    this.sequence = this.sequence >= 999 ? 1 : this.sequence + 1;
    let candidate: number = Math.min(MAX_SAFE_INTEGER, safeNow * 1000 + this.sequence);
    if (candidate <= this.lastToken) {
      candidate = Math.min(MAX_SAFE_INTEGER, this.lastToken + 1);
    }
    if (candidate <= this.lastToken || candidate <= 0) { return 0; }
    this.lastToken = candidate;
    return candidate;
  }

  resetForTest(): void {
    this.lastToken = 0;
    this.sequence = 0;
  }
}
