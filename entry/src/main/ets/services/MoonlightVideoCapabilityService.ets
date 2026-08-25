import rdpnapi from 'librdpnapi.so';
import { MoonlightCodecPreference } from '../model/MoonlightModels';
import {
  MoonlightProductDecoderCapabilities,
  MoonlightProductDecoderCapability
} from './MoonlightSettingsPolicy';

export interface MoonlightHardwareDecoderCapability extends MoonlightProductDecoderCapability {
  name: string;
  minWidth: number;
  minHeight: number;
  minFps: number;
  widthAlignment: number;
  heightAlignment: number;
  lowLatency: boolean;
}

export interface MoonlightHardwareDecoderCapabilities extends MoonlightProductDecoderCapabilities {
  h264: MoonlightHardwareDecoderCapability;
  hevc: MoonlightHardwareDecoderCapability;
  av1: MoonlightHardwareDecoderCapability;
  probeSucceeded: boolean;
}

function unavailable(): MoonlightHardwareDecoderCapability {
  return {
    available: false, name: '', minWidth: 0, maxWidth: 0,
    minHeight: 0, maxHeight: 0, minFps: 0, maxFps: 0,
    widthAlignment: 0, heightAlignment: 0, lowLatency: false
  };
}

function safeFallback(): MoonlightHardwareDecoderCapabilities {
  return {
    h264: {
      available: true, name: 'HarmonyOS H.264 hardware decoder',
      minWidth: 320, maxWidth: 1920, minHeight: 240, maxHeight: 1080,
      minFps: 30, maxFps: 60, widthAlignment: 2, heightAlignment: 2,
      lowLatency: false
    },
    hevc: unavailable(), av1: unavailable(), probeSucceeded: false
  };
}

function boundedInteger(value: number, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value)) { return 0; }
  return Math.max(minimum, Math.min(maximum, value));
}

function normalize(source: MoonlightHardwareDecoderCapability): MoonlightHardwareDecoderCapability {
  if (source === undefined || source === null || typeof source !== 'object' ||
      typeof source.available !== 'boolean') { return unavailable(); }
  const available: boolean = source.available;
  return {
    available: available,
    name: available && typeof source.name === 'string' ? source.name.substring(0, 128) : '',
    minWidth: boundedInteger(source.minWidth, 0, 16384),
    maxWidth: boundedInteger(source.maxWidth, 0, 16384),
    minHeight: boundedInteger(source.minHeight, 0, 16384),
    maxHeight: boundedInteger(source.maxHeight, 0, 16384),
    minFps: boundedInteger(source.minFps, 0, 1000),
    maxFps: boundedInteger(source.maxFps, 0, 1000),
    widthAlignment: boundedInteger(source.widthAlignment, 0, 1024),
    heightAlignment: boundedInteger(source.heightAlignment, 0, 1024),
    lowLatency: available && source.lowLatency === true
  };
}

let cached: MoonlightHardwareDecoderCapabilities | null = null;

export function probeMoonlightHardwareDecoderCapabilities(
  refresh: boolean = false): MoonlightHardwareDecoderCapabilities {
  if (!refresh && cached !== null) { return cached; }
  try {
    const native: MoonlightHardwareDecoderCapabilities =
      rdpnapi.getHardwareVideoDecoderCapabilities() as MoonlightHardwareDecoderCapabilities;
    const value: MoonlightHardwareDecoderCapabilities = {
      h264: normalize(native.h264), hevc: normalize(native.hevc),
      av1: normalize(native.av1), probeSucceeded: true
    };
    // H.264 is the protocol compatibility baseline. A probe that cannot even
    // find it is treated as unusable rather than advertising speculative
    // advanced formats.
    cached = value.h264.available ? value : safeFallback();
  } catch (_error) {
    cached = safeFallback();
  }
  return cached;
}

export function moonlightDecoderCapability(
  capabilities: MoonlightHardwareDecoderCapabilities,
  codec: MoonlightCodecPreference): MoonlightHardwareDecoderCapability {
  if (codec === 'hevc') { return capabilities.hevc; }
  if (codec === 'av1') { return capabilities.av1; }
  return capabilities.h264;
}

export function moonlightDecoderDisplayName(
  codec: MoonlightCodecPreference,
  capability: MoonlightHardwareDecoderCapability): string {
  const format: string = codec === 'hevc' ? 'H.265 / HEVC' : codec === 'av1' ? 'AV1' : 'H.264';
  if (!capability.available) { return format + ' · 不可用'; }
  const implementation: string = capability.name.trim() === '' ? 'HarmonyOS 硬件' : capability.name;
  return format + ' · ' + implementation;
}
