export interface RemoteResolutionPreset {
  id: string;
  label: string;
  width: number;
  height: number;
}

export interface RdpResolutionGeometry {
  width: number;
  height: number;
  orientation: number;
  followsWindow: boolean;
}

export interface RdpResolutionAspectAssessment {
  followsWindow: boolean;
  aspectGapPercent: number;
  avoidsRatioBars: boolean;
}

const PRESETS: RemoteResolutionPreset[] = [
  { id: '1024x768', label: '1024 × 768', width: 1024, height: 768 },
  { id: '1280x720', label: '1280 × 720', width: 1280, height: 720 },
  { id: '1280x800', label: '1280 × 800', width: 1280, height: 800 },
  { id: '1280x1024', label: '1280 × 1024', width: 1280, height: 1024 },
  { id: '1366x768', label: '1366 × 768', width: 1366, height: 768 },
  { id: '1440x900', label: '1440 × 900', width: 1440, height: 900 },
  { id: '1600x900', label: '1600 × 900', width: 1600, height: 900 },
  { id: '1680x1050', label: '1680 × 1050', width: 1680, height: 1050 },
  { id: '1920x1080', label: '1920 × 1080', width: 1920, height: 1080 },
  { id: '1920x1200', label: '1920 × 1200', width: 1920, height: 1200 },
  { id: '2560x1080', label: '2560 × 1080', width: 2560, height: 1080 },
  { id: '2560x1440', label: '2560 × 1440', width: 2560, height: 1440 },
  { id: '2560x1600', label: '2560 × 1600', width: 2560, height: 1600 },
  { id: '2880x1800', label: '2880 × 1800', width: 2880, height: 1800 },
  { id: '3200x1800', label: '3200 × 1800', width: 3200, height: 1800 },
  { id: '3440x1440', label: '3440 × 1440', width: 3440, height: 1440 },
  { id: '3840x2160', label: '3840 × 2160', width: 3840, height: 2160 },
  { id: '3840x2400', label: '3840 × 2400', width: 3840, height: 2400 }
];

export function rdpResolutionPresets(): RemoteResolutionPreset[] {
  return PRESETS.slice();
}

function validDimension(value: number): boolean {
  return Number.isFinite(value) && value >= 200 && value <= 8192;
}

function evenWidth(value: number): number {
  const rounded: number = Math.max(200, Math.min(8192, Math.round(value)));
  return rounded % 2 === 0 ? rounded : rounded - 1;
}

/** Resolve the one authoritative geometry used by both the initial handshake
 * and mid-session Display Control requests. */
export function resolveRdpResolutionGeometry(id: string, adaptiveWidth: number,
  adaptiveHeight: number): RdpResolutionGeometry {
  const preset: RemoteResolutionPreset | null = rdpResolutionPresetForId(id);
  const width: number = preset === null ?
    evenWidth(validDimension(adaptiveWidth) ? adaptiveWidth : 1920) : preset.width;
  const height: number = preset === null ?
    Math.max(200, Math.min(8192, Math.round(validDimension(adaptiveHeight) ? adaptiveHeight : 1080))) :
    preset.height;
  return {
    width,
    height,
    orientation: width >= height ? 0 : 90,
    followsWindow: preset === null
  };
}

export function rdpResolutionAspectAssessment(id: string, surfaceWidth: number,
  surfaceHeight: number): RdpResolutionAspectAssessment {
  if (id === 'auto') {
    return { followsWindow: true, aspectGapPercent: 0, avoidsRatioBars: true };
  }
  const preset: RemoteResolutionPreset | null = rdpResolutionPresetForId(id);
  if (preset === null || !validDimension(surfaceWidth) || !validDimension(surfaceHeight)) {
    return { followsWindow: false, aspectGapPercent: 100, avoidsRatioBars: false };
  }
  const surfaceRatio: number = surfaceWidth / surfaceHeight;
  const presetRatio: number = preset.width / preset.height;
  const gap: number = Math.abs(presetRatio / surfaceRatio - 1) * 100;
  return {
    followsWindow: false,
    aspectGapPercent: gap,
    avoidsRatioBars: gap <= 1.5
  };
}

/** Put aspect-compatible and size-near presets first without removing any
 * explicit fixed-resolution choice. */
export function rdpResolutionPresetsForSurface(surfaceWidth: number,
  surfaceHeight: number): RemoteResolutionPreset[] {
  const result: RemoteResolutionPreset[] = PRESETS.slice();
  if (!validDimension(surfaceWidth) || !validDimension(surfaceHeight)) {
    return result;
  }
  const surfaceRatio: number = surfaceWidth / surfaceHeight;
  result.sort((left: RemoteResolutionPreset, right: RemoteResolutionPreset): number => {
    const leftAspect: number = Math.abs(left.width / left.height / surfaceRatio - 1);
    const rightAspect: number = Math.abs(right.width / right.height / surfaceRatio - 1);
    if (Math.abs(leftAspect - rightAspect) > 0.0001) {
      return leftAspect - rightAspect;
    }
    const leftSize: number = Math.abs(left.width / surfaceWidth - 1) +
      Math.abs(left.height / surfaceHeight - 1);
    const rightSize: number = Math.abs(right.width / surfaceWidth - 1) +
      Math.abs(right.height / surfaceHeight - 1);
    return leftSize - rightSize;
  });
  return result;
}

export function rdpResolutionPresetForId(id: string): RemoteResolutionPreset | null {
  for (let index = 0; index < PRESETS.length; index++) {
    if (PRESETS[index].id === id) {
      return PRESETS[index];
    }
  }
  return null;
}

export function normalizeRdpResolutionId(value: string, legacyPreset: number): string {
  if (value === 'auto' || rdpResolutionPresetForId(value) !== null) {
    return value;
  }
  if (legacyPreset === 0) { return 'auto'; }
  if (legacyPreset === 2) { return '2560x1440'; }
  if (legacyPreset === 3) { return '3840x2160'; }
  return '1920x1080';
}

/** Kept for released preferences and diagnostics only. */
export function legacyRdpPresetForResolutionId(id: string): number {
  if (id === 'auto') { return 0; }
  if (id === '2560x1440') { return 2; }
  if (id === '3840x2160') { return 3; }
  return 1;
}

export function rdpResolutionLabel(id: string): string {
  if (id === 'auto') { return '自适应当前窗口'; }
  const preset = rdpResolutionPresetForId(id);
  return preset === null ? '1920 × 1080' : preset.label;
}
