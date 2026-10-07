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
 * Every search bar's surface: a glass capsule drawn by the app (its tint, blur and soft shadow, with a light rim
 * along the top and a darker one below, as on the AI assistant's input capsule), so it shows on every device. The
 * system's immersive material is not used here: with the app targeting API 23 it drew nothing on API 26 devices and
 * the bars were left without a surface. The bar's own corner radius shapes the capsule.
 */
export class SearchBarSurface<T extends CommonMethod<T>> implements AttributeModifier<T> {
  private dark: boolean;
  private fallback: SearchBarFallback;

  constructor(dark: boolean, fallback: SearchBarFallback) {
    this.dark = dark;
    this.fallback = fallback;
  }

  applyNormalAttribute(instance: T): void {
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
