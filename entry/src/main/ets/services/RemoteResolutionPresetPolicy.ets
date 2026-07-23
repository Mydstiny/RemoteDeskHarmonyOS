export interface RemoteResolutionPreset {
  id: string;
  label: string;
  width: number;
  height: number;
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
