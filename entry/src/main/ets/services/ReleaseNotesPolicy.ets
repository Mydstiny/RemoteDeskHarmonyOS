export enum StartupMode { FIRST_INSTALL_GUIDE, RELEASE_NOTES, LOGIN }

function parseVersion(value: string): number[] | null {
  const parts: string[] = value.split('.');
  if (parts.length !== 3) { return null; }
  const values: number[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    if (!/^\d+$/.test(parts[i])) { return null; }
    values.push(Number(parts[i]));
  }
  return values;
}

export function compareReleaseVersion(left: string, right: string): number {
  const a: number[] | null = parseVersion(left);
  const b: number[] | null = parseVersion(right);
  if (a === null || b === null) { return 0; }
  for (let i: number = 0; i < 3; i++) {
    if (a[i] < b[i]) { return -1; }
    if (a[i] > b[i]) { return 1; }
  }
  return 0;
}

export function resolveStartupMode(guideShown: boolean, lastSeen: string, current: string,
  hasCurrentReleaseNotes: boolean, forceReleaseNotes: boolean = false): StartupMode {
  if (forceReleaseNotes && hasCurrentReleaseNotes && parseVersion(current) !== null) {
    return StartupMode.RELEASE_NOTES;
  }
  if (!guideShown) { return StartupMode.FIRST_INSTALL_GUIDE; }
  if (!hasCurrentReleaseNotes || parseVersion(current) === null) {
    return StartupMode.LOGIN;
  }
  const previous: string = lastSeen.length === 0 ? '0.0.0' : lastSeen;
  if (parseVersion(previous) === null) { return StartupMode.LOGIN; }
  return compareReleaseVersion(previous, current) < 0 ? StartupMode.RELEASE_NOTES : StartupMode.LOGIN;
}

/**
 * 首次安装引导必须作为页面首屏渲染，不能依赖系统 Sheet 的冷启动挂载时序。
 * 只有版本更新说明使用底部 Sheet，避免再次引入首次打开白屏。
 */
export function shouldPresentGuideAsBottomSheet(mode: StartupMode, breakpoint: string): boolean {
  return mode === StartupMode.RELEASE_NOTES && breakpoint === 'sm';
}

/**
 * Pad/PC 端只有版本更新说明使用居中系统 Sheet；首次教程直接显示在页面中。
 */
export function shouldPresentGuideAsCenterSheet(mode: StartupMode, breakpoint: string): boolean {
  return mode === StartupMode.RELEASE_NOTES && breakpoint !== 'sm';
}
