import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { APP_ICON_MIN_API, AppIconProvider, AppIconState } from './AppIconPolicy';

// bundleManager itself is present on API 23. New members are resolved only after this guard;
// there is no import or eager initialization of a new API 26-only module.
export class AppIconAdapter implements AppIconProvider {
  supported(): boolean {
    return deviceInfo.sdkApiVersion >= APP_ICON_MIN_API &&
      canIUse('SystemCapability.BundleManager.BundleFramework.Core');
  }
  async query(): Promise<AppIconState[]> {
    if (!this.supported()) { return []; }
    const icons = await bundleManager.getAlternateIcons();
    return icons.map((icon: bundleManager.AlternateIconInfo): AppIconState =>
      ({ name: icon.iconName, enabled: icon.enabled }));
  }
  async apply(name: string): Promise<void> {
    if (!this.supported()) { throw new Error('iconUnsupported'); }
    try { await bundleManager.setAlternateIcon(name); }
    catch (error) {
      // Restoring the already-default icon is an idempotent operation.
      if (name === '' && (error as BusinessError).code === 17700309) { return; }
      throw new Error('iconApplyFailed');
    }
  }
}
