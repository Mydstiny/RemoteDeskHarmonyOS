/**
 * EntryAbility.ets — 应用入口 UIAbility
 *
 * HarmonyOS 6 沉浸式窗口 + 主题初始化。
 * 仅需 INTERNET 权限 (system_grant, 安装时自动授予，无需弹窗)。
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { buffer } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { KeyVaultService } from '../services/KeyVaultService';
import { HostSyncService } from '../services/HostSyncService';
import { DataCrypto } from '../services/DataCrypto';
import { CloudSyncCoordinator } from '../services/CloudSyncCoordinator';
import { BreakpointUtil } from '../utils/BreakpointUtil';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { RemoteSessionBackgroundTaskService } from '../services/RemoteSessionBackgroundTaskService';
import {
  DEFAULT_DARK_HALO_COLOR,
  DEFAULT_LIGHT_HALO_COLOR,
  HALO_COLOR_DARK_KEY,
  HALO_COLOR_LEGACY_KEY,
  HALO_COLOR_LIGHT_KEY,
  resolveStoredHaloColorForTheme
} from '../services/HaloColorPolicy';
import auth from '@hw-agconnect/auth';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

// AppStorage key: 标识应用正在进入后台 (用于 RemoteDesktop 区分 home gesture vs explicit exit)
const BG_FLAG_KEY = 'remoteDesktopBgFlag';
const ENV_COLOR_MODE_UNKNOWN = -1;
const ENV_COLOR_MODE_LIGHT = 0;
const ENV_COLOR_MODE_DARK = 1;

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;
  private avoidAreaCallback: ((data: window.AvoidAreaOptions) => void) | null = null;

  private disconnectRemoteSessions(source: string): void {
    try {
      ExtensionLoader.getInstance().disconnectAll();
      hilog.info(DOMAIN, TAG, 'Remote sessions disconnected: %{public}s', source);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'disconnectRemoteSessions failed: %{public}s',
        JSON.stringify(err));
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      // 读取系统颜色模式 (必须在 setColorMode 前 + AppStorage 初始化在前)
      const sysColorMode: number = this.context.config.colorMode ?? 0;
      const sysDark: boolean = sysColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      let followSystem: boolean = true;
      let savedTheme: string = sysDark ? 'dark' : 'light';
      let savedAccent: string = '#007DFF';
      let savedHalo: string = '';
      let savedLightHalo: string = '';
      let savedDarkHalo: string = '';
      let savedWallpaper: string = sysDark ? '#1A1A2E' : '#FFFFFF';
      try {
        const prefs = preferences.getPreferencesSync(this.context, { name: 'RemoteDesktopAppPrefs' });
        followSystem = prefs.getSync('followSystem', true) as boolean;
        const prefTheme: string = prefs.getSync('currentTheme', savedTheme) as string;
        if (prefTheme === 'dark' || prefTheme === 'light') { savedTheme = prefTheme; }
        const prefAccent: string = prefs.getSync('accentColor', '') as string;
        const prefHalo: string = prefs.getSync(HALO_COLOR_LEGACY_KEY, '') as string;
        const prefLightHalo: string = prefs.getSync(HALO_COLOR_LIGHT_KEY, '') as string;
        const prefDarkHalo: string = prefs.getSync(HALO_COLOR_DARK_KEY, '') as string;
        const prefWallpaper: string = prefs.getSync('wallpaperColor', '') as string;
        if (prefAccent.length > 0) { savedAccent = prefAccent; }
        if (prefHalo.length > 0) { savedHalo = prefHalo; }
        if (prefLightHalo.length > 0) { savedLightHalo = prefLightHalo; }
        if (prefDarkHalo.length > 0) { savedDarkHalo = prefDarkHalo; }
        if (prefWallpaper.length > 0) { savedWallpaper = prefWallpaper; }
      } catch (_e) { /* 首次启动或 Preferences 不可用时使用系统主题 */ }
      const effectiveDark: boolean = followSystem ? sysDark : savedTheme === 'dark';
      const lightHalo: string = resolveStoredHaloColorForTheme('light', savedLightHalo, savedDarkHalo, savedHalo);
      const darkHalo: string = resolveStoredHaloColorForTheme('dark', savedLightHalo, savedDarkHalo, savedHalo);
      const effectiveHalo: string = effectiveDark ? darkHalo : lightHalo;
      // 先写入 AppStorage (setColorMode 会触发 onConfigurationUpdate 读取这些值)
      AppStorage.setOrCreate<number>('systemColorMode', sysColorMode);
      AppStorage.setOrCreate<boolean>('followSystem', followSystem);
      AppStorage.setOrCreate<string>('accentColor', savedAccent);
      AppStorage.setOrCreate<string>(HALO_COLOR_LIGHT_KEY, lightHalo.length > 0 ? lightHalo : DEFAULT_LIGHT_HALO_COLOR);
      AppStorage.setOrCreate<string>(HALO_COLOR_DARK_KEY, darkHalo.length > 0 ? darkHalo : DEFAULT_DARK_HALO_COLOR);
      AppStorage.setOrCreate<string>(HALO_COLOR_LEGACY_KEY, effectiveHalo);
      AppStorage.setOrCreate<string>('wallpaperColor', savedWallpaper);
      // 跟随系统必须使用 NOT_SET；手动模式才显式指定深/浅色。
      this.context.getApplicationContext().setColorMode(
        followSystem ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
          : (effectiveDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                           : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
      );
      AppStorage.setOrCreate<string>('currentTheme', effectiveDark ? 'dark' : 'light');
      AppStorage.setOrCreate<string>('terminalFgColor', '#33FF33');
      AppStorage.setOrCreate<number>('terminalFontSize', 18);
      // 实况窗默认值: 首次启动默认开启 AVSession 模式 (可由设置页关闭)
      // Preferences 中已有的值会由 HostListPage.aboutToAppear 加载覆盖
      AppStorage.setOrCreate<boolean>('liveViewEnabled', true);
      AppStorage.setOrCreate<number>('liveViewMode', 1);
      this.migrateTerminalFontUnit();
      // 初始化 AGC Auth SDK (读取 agconnect-services.json)
      try {
        const rawFile = this.context.resourceManager.getRawFileContentSync('agconnect-services.json');
        const json: string = buffer.from(rawFile.buffer).toString();
        auth.init(this.context, json);
        hilog.info(0x0001, 'Auth', 'AGC Auth SDK 初始化成功');
      } catch (err) {
        hilog.error(0x0001, 'Auth', "AGC Auth SDK 初始化失败: " + JSON.stringify(err));
      }
      // 初始化密钥保险库 + 主机服务 (串行初始化, 避免竞态)
      hilog.info(0x0001, 'CloudSync', 'EntryAbility: 开始初始化 CloudStore...');
      KeyVaultService.getInstance().init(this.context).then(() => {
        hilog.info(0x0001, 'CloudSync', 'KeyVaultService init done');
        return HostSyncService.getInstance().init(this.context);
      }).then(() => {
        hilog.info(0x0001, 'CloudSync', 'HostSyncService init done');
        return CloudSyncCoordinator.getInstance().requestStartupPull();
      }).then((result) => {
        hilog.info(0x0001, 'CloudSync', 'EntryAbility startup cloud pull ok=' + result.ok.toString());
      }).catch((err: Error) => {
        hilog.error(0x0001, 'CloudSync', "服务初始化失败: " + JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, '初始化失败: %{public}s', JSON.stringify(err));
    }
    // 提取 rustdesk_helper 到沙箱并配置 IPC 路径
    this.extractAndSetupHelper();
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  private migrateTerminalFontUnit(): void {
    const version: number = AppStorage.get<number>('terminalFontUnitVersion') ?? 0;
    if (version >= 2) { return; }
    const oldSize: number = AppStorage.get<number>('terminalFontSize') ?? 18;
    let migrated: number = oldSize;
    if (oldSize >= 24) {
      migrated = 18;
    } else if (oldSize > 20) {
      migrated = 20;
    }
    migrated = Math.max(12, Math.min(32, migrated));
    AppStorage.setOrCreate<number>('terminalFontSize', migrated);
    AppStorage.setOrCreate<number>('terminalFontUnitVersion', 2);
    hilog.info(DOMAIN, TAG, `terminalFontSize migrated old=${oldSize} new=${migrated}vp`);
  }

  /**
   * 从 rawfile 提取 rustdesk_helper 到 App 沙箱, 并通过 NAPI 配置 IPC 路径。
   */
  private extractAndSetupHelper(): void {
    try {
      // 设置 IPC socket 路径 (内置 C++ helper pthread, 不需要外部二进制)
      const socketPath: string = this.context.filesDir + '/rustdesk_helper.sock';
      ExtensionLoader.getInstance().setHelperSocketPath(socketPath, '');
      hilog.info(DOMAIN, TAG, 'RustDesk IPC socket 路径: %{public}s', socketPath);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'helper socket 路径设置失败: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    // 最终销毁 — 必须完全断连所有远程会话 + 移除灵动岛
    AppStorage.setOrCreate<boolean>(BG_FLAG_KEY, false);
    this.disconnectRemoteSessions('ability-destroy');
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.windowStage = windowStage;
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      this.initArkUIEnvironment(mainWindow);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '预初始化 ArkUI environment 失败: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/GuidePage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载页面失败: %{public}s', JSON.stringify(err));
        return;
      }
      this.initImmersiveWindow();
    });
  }

  onWindowStageDestroy(): void {
    // WindowStage 销毁 — 完全断连 + 移除灵动岛
    AppStorage.setOrCreate<boolean>(BG_FLAG_KEY, false);
    this.disconnectRemoteSessions('window-stage-destroy');
    try {
      const win = this.windowStage?.getMainWindowSync();
      if (win && this.avoidAreaCallback) {
        win.off('avoidAreaChange', this.avoidAreaCallback);
      }
    } catch (_e) { /* ignore */ }
    this.avoidAreaCallback = null;
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 前台恢复 — 清除后台标志, 停止后台保活任务
    // 注意: 实况窗由 RemoteDesktop.restoreFromBackground() 控制, 不在此处提前关闭
    AppStorage.setOrCreate<boolean>(BG_FLAG_KEY, false);
    this.syncEffectiveTheme('foreground');
    try {
      RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(this.context);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopSessionTask on foreground failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onWillBackground(): void {
    // API 20+ 在 onBackground 前回调；先通知 RemoteDesktop，避免页面
    // aboutToDisappear 先一步把后台保活连接误判为显式退出。
    AppStorage.setOrCreate<boolean>(BG_FLAG_KEY, true);
    hilog.info(DOMAIN, TAG, 'Ability onWillBackground (background flag set early)');
  }

  onBackground(): void {
    // 切后台 — 标记后台标志, 不再无条件断连
    // RemoteDesktop.aboutToDisappear() 读取此标志决定是保活还是完全断连
    AppStorage.setOrCreate<boolean>(BG_FLAG_KEY, true);

    // 清除内存 DEK (安全策略保持不变)
    try {
      DataCrypto.getInstance().lock();
    } catch (_e) { /* ignore */ }

    // 注意: 不在这里调用 disconnectRemoteSessions.
    // 后台保活决策由 RemoteDesktop 的 aboutToDisappear 配合 BackgroundTaskService 处理.
    // 如果判断应保活: detach render → start background task → keep protocol+audio.
    // 如果判断应断连: full disconnectAndCleanup.

    hilog.info(DOMAIN, TAG, 'Ability onBackground (background flag set, sessions preserved if active)');
  }

  // 监听系统主题变化, 同步到 AppStorage
  onConfigurationUpdate(newConfig: Configuration): void {
    const sysMode: number = this.resolveSystemColorMode(newConfig);
    const isDark: boolean = sysMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const follow: boolean = AppStorage.get<boolean>('followSystem') ?? true;
    if (follow) {
      // 仅跟随模式才记录系统颜色模式 (手动 setColorMode 也会触发此回调, 避免污染)
      AppStorage.setOrCreate('systemColorMode', sysMode);
      AppStorage.setOrCreate('currentTheme', isDark ? 'dark' : 'light');
    }
    const barDark: boolean = follow ? isDark
      : (AppStorage.get<string>('currentTheme') ?? 'light') === 'dark';
    this.updateStatusBar(barDark);
    hilog.info(DOMAIN, TAG, '主题更新: mode=%{public}d sysDark=%{public}s follow=%{public}s',
      sysMode, isDark.toString(), follow.toString());
  }

  private resolveSystemColorMode(config?: Configuration): number {
    const mode: number | undefined = config?.colorMode;
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return mode;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    const envMode: number | null = this.resolveEnvironmentColorMode();
    if (envMode !== null) {
      return envMode;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    // 系统从深色切回浅色时，部分设备的回调不携带 LIGHT，而 context.config
    // 仍可能短暂保持旧 DARK。回调场景下未知值按浅色处理，避免旧 dark 反向污染。
    if (config !== undefined) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    const ctxMode: number | undefined = this.context.config.colorMode;
    if (ctxMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return ctxMode;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }

  private resolveEnvironmentColorMode(): number | null {
    const envMode: number | undefined = AppStorage.get<number>('colorMode');
    if (envMode === ENV_COLOR_MODE_DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (envMode === ENV_COLOR_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return null;
  }

  private syncFollowSystemTheme(source: string): void {
    const follow: boolean = AppStorage.get<boolean>('followSystem') ?? true;
    if (!follow) { return; }
    const sysMode: number = this.resolveSystemColorMode();
    const isDark: boolean = sysMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('systemColorMode', sysMode);
    AppStorage.setOrCreate('currentTheme', isDark ? 'dark' : 'light');
    this.updateStatusBar(isDark);
    hilog.info(DOMAIN, TAG, '跟随系统主题同步: source=%{public}s mode=%{public}d theme=%{public}s',
      source, sysMode, isDark ? 'dark' : 'light');
  }

  private syncEffectiveTheme(source: string): void {
    const follow: boolean = AppStorage.get<boolean>('followSystem') ?? true;
    if (follow) {
      this.syncFollowSystemTheme(source);
      return;
    }
    const theme: string = AppStorage.get<string>('currentTheme') ?? 'light';
    const isDark: boolean = theme === 'dark';
    this.context.getApplicationContext().setColorMode(
      isDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
    );
    this.updateStatusBar(isDark);
    hilog.info(DOMAIN, TAG, '手动主题前台恢复: source=%{public}s theme=%{public}s',
      source, theme);
  }

  private async updateStatusBar(isDark: boolean): Promise<void> {
    try {
      if (!this.windowStage) { return; }
      const win = await this.windowStage.getMainWindow();
      if (!win) { return; }
      // 深色模式: #E6E6E6 避免纯白 21:1 极端对比度
      // 浅色模式: #1C1C1C 深灰而非纯黑, 保证舒适对比度
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: isDark ? '#E6E6E6' : '#1C1C1C',
        navigationBarContentColor: isDark ? '#E6E6E6' : '#1C1C1C'
      });
    } catch (err) {
      // 静默
    }
  }

  /**
   * 沉浸式窗口：全屏布局 + 透明系统栏
   */
  private async initImmersiveWindow(): Promise<void> {
    try {
      if (!this.windowStage) {
        return;
      }
      const mainWindow = await this.windowStage.getMainWindow();
      if (!mainWindow) {
        return;
      }
      // 初始化响应式断点系统 (PC 自由窗口适配)
      BreakpointUtil.init(mainWindow);
      this.syncAvoidAreas(mainWindow);
      // PC 自由窗口尺寸限制 (防止缩到不可用)
      mainWindow.setWindowLimits({ minWidth: 360, minHeight: 480, maxWidth: 2560, maxHeight: 1600 });
      const follow: boolean = AppStorage.get<boolean>('followSystem') ?? true;
      const isDark: boolean = follow ? this.resolveSystemColorMode() === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (AppStorage.get<string>('currentTheme') ?? 'light') === 'dark';
      const contentColor: string = isDark ? '#E6E6E6' : '#1C1C1C';
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
      hilog.info(DOMAIN, TAG, '沉浸式窗口初始化完成');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '沉浸式窗口初始化失败: %{public}s', JSON.stringify(err));
    }
  }

  private initArkUIEnvironment(mainWindow: window.Window): void {
    try {
      const uiContext = mainWindow.getUIContext();
      uiContext.runScopedTask((): void => {
        Environment.envProp('colorMode', ENV_COLOR_MODE_UNKNOWN);
      });
      hilog.info(DOMAIN, TAG, 'ArkUI environment colorMode initialized');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ArkUI environment colorMode init failed: %{public}s', JSON.stringify(err));
    }
  }

  private syncAvoidAreas(mainWindow: window.Window): void {
    try {
      const systemArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottomArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('topRectHeight', systemArea.topRect.height);
      AppStorage.setOrCreate<number>('bottomRectHeight', bottomArea.bottomRect.height);

      this.avoidAreaCallback = (data: window.AvoidAreaOptions): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>('topRectHeight', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate<number>('bottomRectHeight', data.area.bottomRect.height);
        }
      };
      mainWindow.on('avoidAreaChange', this.avoidAreaCallback);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '同步避让区域失败: %{public}s', JSON.stringify(err));
      AppStorage.setOrCreate<number>('topRectHeight', 0);
      AppStorage.setOrCreate<number>('bottomRectHeight', 0);
    }
  }
}
