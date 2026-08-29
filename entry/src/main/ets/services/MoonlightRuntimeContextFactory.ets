import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightSettings,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  canonicalMoonlightAddress,
  moonlightAddressMatchesKey,
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
const MOONLIGHT_STABLE_DEVICE_WIDTH: number = 1920;
const MOONLIGHT_WIFI_VIDEO_BUDGET_RATIO: number = 0.6;
const MOONLIGHT_BITRATE_STEP_KBPS: number = 500;

export function moonlightWifiReceiveLinkSpeedMbps(linkSpeedMbps: number,
  receiveLinkSpeedMbps: number): number {
  const linkValid: boolean = Number.isFinite(linkSpeedMbps) && linkSpeedMbps > 0;
  const receiveValid: boolean = Number.isFinite(receiveLinkSpeedMbps) &&
    receiveLinkSpeedMbps > 0;
  if (linkValid && receiveValid) {
    return Math.min(linkSpeedMbps, receiveLinkSpeedMbps);
  }
  if (receiveValid) { return receiveLinkSpeedMbps; }
  return linkValid ? linkSpeedMbps : 0;
}

export function moonlightNetworkSafeBitrateKbps(requestedBitrateKbps: number,
  linkSpeedMbps: number): number {
  const requested: number = Number.isSafeInteger(requestedBitrateKbps) &&
    requestedBitrateKbps >= 1000 && requestedBitrateKbps <= 200000 ?
    requestedBitrateKbps : 20000;
  if (!Number.isFinite(linkSpeedMbps) || linkSpeedMbps <= 0) { return requested; }
  const unroundedBudget: number = linkSpeedMbps * 1000 *
    MOONLIGHT_WIFI_VIDEO_BUDGET_RATIO;
  const roundedBudget: number = Math.floor(unroundedBudget /
    MOONLIGHT_BITRATE_STEP_KBPS) * MOONLIGHT_BITRATE_STEP_KBPS;
  return Math.min(requested, Math.max(1000, roundedBudget));
}

export function moonlightSelectedAddress(host: MoonlightHost,
  settings: MoonlightSettings): MoonlightAddress | null {
  if (!moonlightHostIsValid(host) || !moonlightSettingsAreValid(settings) ||
      host.addresses.length === 0) {
    return null;
  }
  const family: string = settings.network.preferredAddressFamily;
  if (family === 'ipv4' || family === 'ipv6') {
    for (let index: number = 0; index < host.addresses.length; index++) {
      if (host.addresses[index].family === family) {
        return canonicalMoonlightAddress(host.addresses[index]);
      }
    }
  }
  for (let index: number = 0; index < host.addresses.length; index++) {
    if (moonlightAddressMatchesKey(host.addresses[index], host.preferredAddressKey)) {
      return canonicalMoonlightAddress(host.addresses[index]);
    }
  }
  return canonicalMoonlightAddress(host.addresses[0]);
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
      // Display labels are not TLS identities. Bind certificate verification
      // to the selected canonical DNS/IP endpoint until a separately verified
      // advertised server name is persisted.
      serverName: selected.host,
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
  const validDevicePixels: boolean = Number.isFinite(deviceWidth) &&
    Number.isFinite(deviceHeight) && deviceWidth >= 320 && deviceHeight >= 240;
  if ((adaptive === 'device' || adaptive === 'host') && validDevicePixels) {
    // Adaptive resolution is a runtime property, not a durable 16:9 custom
    // size. Both policies preserve the current device aspect ratio. The host
    // policy additionally treats its stored capability size as a ceiling, so
    // a 16:10 Pad does not request a 16:9 encoder surface and receive a second
    // set of bars from Sunshine inside the renderer's own contain viewport.
    const landscapeWidth: number = Math.max(deviceWidth, deviceHeight);
    const landscapeHeight: number = Math.min(deviceWidth, deviceHeight);
    const boundedDecoderWidth: number = Number.isSafeInteger(decoderMaxWidth) &&
      decoderMaxWidth >= 320 ? Math.min(7680, decoderMaxWidth) : 1920;
    const boundedDecoderHeight: number = Number.isSafeInteger(decoderMaxHeight) &&
      decoderMaxHeight >= 240 ? Math.min(4320, decoderMaxHeight) : 1080;
    // Native Pad pixels are not a useful stability target on a constrained
    // wireless path. Preserve the display aspect ratio but cap the long edge
    // to 1920 for the device-adaptive policy. This keeps a 16:10 Pad at
    // 1920x1200 instead of forcing 4.1 million pixels through the decoder and
    // network for every frame.
    const hostWidthCeiling: number = adaptive === 'host' ?
      Math.max(320, video.customWidth) : MOONLIGHT_STABLE_DEVICE_WIDTH;
    const hostHeightCeiling: number = adaptive === 'host' ?
      Math.max(240, video.customHeight) : 4320;
    const scale: number = Math.min(1,
      boundedDecoderWidth / landscapeWidth,
      boundedDecoderHeight / landscapeHeight,
      hostWidthCeiling / landscapeWidth,
      hostHeightCeiling / landscapeHeight);
    width = landscapeWidth * scale;
    height = landscapeHeight * scale;
    width = Math.floor(width / 2) * 2;
    height = Math.floor(height / 2) * 2;
  } else if (adaptive === 'host') {
    // Display probing can be unavailable during recovery or unit execution.
    // Preserve the compatible persisted host-capability request in that case.
    width = video.customWidth;
    height = video.customHeight;
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
