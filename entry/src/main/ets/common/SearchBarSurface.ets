import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

let immersiveState: number = -1;

/**
 * The system's 沉浸光感 material (uiMaterial.ImmersiveMaterial): API 26 and a device that supports it. The app still
 * runs on API 23, where the systemMaterial attribute does not exist, so every use goes through this check.
 */
export function immersiveMaterialAvailable(): boolean {
  if (immersiveState < 0) {
    try {
      immersiveState = deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported() ? 1 : 0;
      // Once per launch: whether the search bars use the system glass, and why not when they do not.
      const info = deviceInfo.sdkApiVersion >= 26 ? uiMaterial.getMaterialInfo() : null;
      hilog.info(0x0000, 'RemoteMaterial', 'api=%{public}d supported=%{public}s level=%{public}d state=%{public}d',
        deviceInfo.sdkApiVersion, String(immersiveState === 1),
        deviceInfo.sdkApiVersion >= 26 ? uiMaterial.getGlobalMaterialLevel() : -1, info === null ? -1 : info.state);
    } catch (_error) {
      immersiveState = 0;
    }
  }
  return immersiveState === 1;
}

/** How a search bar looks where the system material is not available (its look before the material). */
export interface SearchBarFallback {
  background?: ResourceColor;
  border?: ResourceColor;
  blur?: boolean;
  shadow?: boolean;
}

/**
 * Every search bar's surface. On a device with the system's 沉浸光感 (API 26 and support for it) it is the system's
 * own immersive glass, as in the system apps: refraction and a highlight edge, press deformation and touch light,
 * following the device and 设置 → 沉浸光感. Elsewhere the app draws the glass capsule itself: tint, blur, a light rim
 * on top and a darker one below, and a soft shadow (as on the AI assistant's input capsule). The app targets API 26
 * (the material does nothing for an app that targets less) and runs from API 23, where this check keeps it off.
 */
export class SearchBarSurface<T extends CommonMethod<T>> implements AttributeModifier<T> {
  private dark: boolean;
  private fallback: SearchBarFallback;

  constructor(dark: boolean, fallback: SearchBarFallback) {
    this.dark = dark;
    this.fallback = fallback;
  }

  applyNormalAttribute(instance: T): void {
    if (immersiveMaterialAvailable()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        // Tinted enough that the capsule reads over a plain page (a faint tint left only empty space there).
        materialColor: this.dark ? '#33FFFFFF' : '#66E9ECF1',
        interactive: true,
        lightEffect: { color: Color.White }
      }));
      return;
    }
    if (this.fallback.background !== undefined) { instance.backgroundColor(this.fallback.background); }
    instance.backgroundBlurStyle(BlurStyle.Regular);
    instance.border({
      width: { top: 1, left: 0.6, right: 0.6, bottom: 0.8 },
      color: this.dark ? { top: '#4DFFFFFF', left: '#26FFFFFF', right: '#26FFFFFF', bottom: '#1AFFFFFF' } :
        { top: '#FFFFFFFF', left: '#1A000000', right: '#1A000000', bottom: '#24000000' },
      style: BorderStyle.Solid
    });
    if (this.fallback.shadow !== false) {
      instance.shadow({ radius: 14, color: this.dark ? '#33000000' : '#14000000', offsetY: 3 });
    }
  }
}

/*
 * The glass capsule as plain attribute values, set directly on each search bar (an attribute modifier left the bars
 * with no surface at all on device): a white sheen fading down over the bar's colour, and a soft shadow (no rim).
 */
export function searchGlassSheen(dark: boolean): LinearGradientOptions {
  return { angle: 180, colors: dark ? [['#24FFFFFF', 0], ['#08FFFFFF', 0.55], ['#00FFFFFF', 1]] :
    [['#B3FFFFFF', 0], ['#40FFFFFF', 0.55], ['#14FFFFFF', 1]] };
}

export function searchGlassShadow(dark: boolean): ShadowOptions {
  return { radius: 16, color: dark ? '#40000000' : '#1A000000', offsetY: 4 };
}

/** Every search capsule's size and type: one height, fully round, the same text size. */
export const SEARCH_CAPSULE_HEIGHT: number = 44;
export const SEARCH_CAPSULE_RADIUS: number = 22;
export const SEARCH_CAPSULE_TEXT: number = 15;
