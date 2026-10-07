import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

let immersiveState: number = -1;

/**
 * The system's 沉浸光感 material (uiMaterial.ImmersiveMaterial): API 26 and a device that supports it. The app still
 * runs on API 23, where the systemMaterial attribute does not exist, so every use goes through this check.
 */
export function immersiveMaterialAvailable(): boolean {
  if (immersiveState < 0) {
    try {
      immersiveState = deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported() ? 1 : 0;
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
 * Every search bar's surface. With 沉浸光感 available it is the system's own glass, as in the system apps: the
 * refraction and highlight edge, the press deformation and the touch light, following the device's computing level
 * and 设置 → 沉浸光感. Elsewhere the bar keeps the look it had. The bar's corner radius shapes the glass, so it is
 * set on the bar itself; background, border and shadow belong to this surface and are not set on the bar.
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
        // A faint tint keeps the glass visible over a plain page, as the system bars do.
        materialColor: this.dark ? '#1AFFFFFF' : '#40F4F6FA',
        interactive: true,
        lightEffect: { color: Color.White }
      }));
      return;
    }
    if (this.fallback.background !== undefined) { instance.backgroundColor(this.fallback.background); }
    if (this.fallback.blur === true) { instance.backgroundBlurStyle(BlurStyle.Regular); }
    if (this.fallback.border !== undefined) {
      instance.border({ width: 0.5, color: this.fallback.border, style: BorderStyle.Solid });
    }
    if (this.fallback.shadow === true) { instance.shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetY: 2 }); }
  }
}
