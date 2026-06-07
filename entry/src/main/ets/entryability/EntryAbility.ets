import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    windowStage.loadContent('pages/HostListPage', (err?: BusinessError) => {
      if (err) {
        console.error('Failed to load content, code: ' + err.code + ', msg: ' + err.message);
        return;
      }
      this.initImmersiveWindow();
    });
  }

  private async initImmersiveWindow(): Promise<void> {
    try {
      const mainWindow: window.Window = await this.windowStage!.getMainWindow();
      if (!mainWindow) {
        return;
      }
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      });
      await mainWindow.setWindowAvoidAreaOption({
        type: window.AvoidAreaType.TYPE_SYSTEM,
        mode: window.AvoidAreaMode.MODE_AVOID
      });
      console.info('Immersive window initialized successfully');
    } catch (err) {
      console.error('Failed to init immersive window: ' + err);
    }
  }

  onWindowStageDestroy(): void {
    this.windowStage = null;
  }

  onForeground(): void {
    console.info('EntryAbility onForeground');
  }

  onBackground(): void {
    console.info('EntryAbility onBackground');
  }
}
