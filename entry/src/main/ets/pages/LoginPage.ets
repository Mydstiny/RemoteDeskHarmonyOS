/**
 * LoginPage.ets v8 — bindSheet 警告弹窗 + 官方 Account Kit 登录
 */
import { router, promptAction } from '@kit.ArkUI';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import {
  AccountSessionCoordinator,
  AccountTransitionResult
} from '../services/AccountSessionCoordinator';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SILENT_LOGIN_TIMEOUT_MS,
  shouldShowLoginAfterSilentAttempt,
  silentLoginFallbackMessage
} from '../services/LoginStartupPolicy';
import { FIRST_LAUNCH_PREPARATION_BLOCKS_UI } from '../services/AppStartupPolicy';
import { hashForLog } from '../utils/SafeLogger';
import { AppCloneContext } from '../services/AppCloneContext';

const PREFS_NAME: string = 'RemoteDesktopAppPrefs';
const KEY_LOGIN_MODE: string = 'loginMode';
const KEY_FIRST_LAUNCH: string = 'firstLaunch';

@Entry
@Component
struct LoginPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @State isLoggingIn: boolean = false;
  @State loginError: string = '';
  @State showAnimation: boolean = false;
  @State showSkipSheet: boolean = false;
  @State showEnterpriseSheet: boolean = false;
  @State checkingLogin: boolean = true; // 检查持久化登录状态中
  @State appCloneLocalOnly: boolean = false;
  @State appCloneIsClone: boolean = false;
  @State appCloneStatusText: string = '';

  aboutToAppear(): void {
    setTimeout(() => { this.showAnimation = true; }, 100);

    const appClone: AppCloneContext = AppCloneContext.getInstance();
    appClone.init(getContext(this));
    this.appCloneLocalOnly = appClone.isLocalOnly();
    this.appCloneIsClone = appClone.isClone();
    this.appCloneStatusText = appClone.snapshot().statusText;
    if (this.appCloneLocalOnly) {
      const firstLaunch: boolean = this.isFirstLaunch();
      this.checkingLogin = false;
      if (firstLaunch) {
        void this.prepareFirstLaunch();
        return;
      }
      let cloneSavedMode: string = '';
      try {
        const clonePrefs = preferences.getPreferencesSync(
          getContext(this), { name: PREFS_NAME });
        cloneSavedMode = clonePrefs.getSync(KEY_LOGIN_MODE, '') as string;
      } catch (_error) { cloneSavedMode = ''; }
      if (cloneSavedMode === 'offline') {
        setTimeout((): void => { void this.enterOfflineMode(); }, 50);
      }
      return;
    }

    // 首次启动 (含卸载重装) → 清除残留登录态, 强制显示登录页
    if (this.isFirstLaunch()) {
      // 首次安装不能把可见 UI 绑定到账号/RDB 初始化。准备工作继续在后台，
      // 登录或离线按钮自身仍会在执行操作前等待同一个协调器就绪。
      this.checkingLogin = FIRST_LAUNCH_PREPARATION_BLOCKS_UI;
      void this.prepareFirstLaunch();
      return;
    }

    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const forceShow: boolean = (params && params['forceShow'] === true);

    let savedMode: string = '';
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: PREFS_NAME });
      savedMode = prefs.getSync(KEY_LOGIN_MODE, '') as string;
    } catch { savedMode = ''; }
    if (!forceShow && savedMode === 'offline') {
      setTimeout((): void => { void this.enterOfflineMode(); }, 50);
      return;
    }
    // 已登录账号 → 静默恢复会话 (不弹窗)
    if (!forceShow && savedMode === 'account') {
      this.trySilentLogin();  // 异步 - 成功跳转, 失败设置 checkingLogin=false 显示登录UI
      return;                 // checkingLogin 保持 true, 避免登录页闪现
    }
    this.checkingLogin = false;
  }

  /** 检测是否首次启动 (含卸载重装), 是则清除残留登录态 */
  private isFirstLaunch(): boolean {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: PREFS_NAME });
      const firstLaunch: boolean = prefs.getSync(KEY_FIRST_LAUNCH, true) as boolean;
      if (firstLaunch) {
        // 首次启动 → 标记已启动, 清除可能的残留登录态
        prefs.putSync(KEY_FIRST_LAUNCH, false);
        prefs.putSync(KEY_LOGIN_MODE, '');
        prefs.flushSync();
        return true;
      }
      return false;
    } catch { return true; }
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  /** 静默恢复登录 (杀后台后保留登录态, 不弹窗) */
  private async trySilentLogin(): Promise<void> {
    if (this.appCloneLocalOnly) {
      this.checkingLogin = false;
      return;
    }
    await this.ensureAccountSessionReady();
    let restored: boolean = false;
    try {
      // 使用 Authorization 流程 (与 doHuaweiLogin 同一类型),
      // forceAuthorization=false 实现静默恢复
      const request: authentication.AuthorizationWithHuaweiIDRequest =
        new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
      request.forceAuthorization = false;
      request.scopes = ['openid', 'profile'];
      request.permissions = ['serviceauthcode'];
      request.state = util.generateRandomUUID();
      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(getContext(this));
      const response: authentication.AuthorizationWithHuaweiIDResponse | null = await Promise.race([
        controller.executeRequest(request),
        new Promise<null>((resolve: (value: null) => void): void => {
          setTimeout((): void => { resolve(null); }, SILENT_LOGIN_TIMEOUT_MS);
        })
      ]);
      if (response !== null && response.data) {
        restored = await this.onLoginSuccess(response.data, false);
        if (restored) {
          hilog.info(0x0001, 'LoginDebug', '静默登录恢复成功');
        }
      } else if (response === null) {
        this.loginError = silentLoginFallbackMessage(0, true);
        hilog.warn(0x0001, 'LoginDebug', '静默登录超时，显示登录页');
      } else {
        hilog.warn(0x0001, 'LoginDebug', '静默登录返回空凭据，显示登录页');
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      const code: number = be && typeof be.code === 'number' ? be.code : 0;
      const message: string = be && typeof be.message === 'string' ? be.message : '';
      hilog.info(0x0001, 'LoginDebug',
        '静默登录失败 code=' + code.toString() + ' msg=' + message + ', 显示登录页');
      if (code !== 0 && code !== 1001502002) {
        this.loginError = silentLoginFallbackMessage(code, false);
      }
    } finally {
      // Empty responses and provider errors are normal recovery paths. Never
      // leave a fresh install behind an infinite full-screen spinner. A
      // failed silent authorization is not an explicit logout: keep the
      // persisted account credential and account RDB intact so an upgraded
      // 1.0.7/1.0.8 user can retry authorization without destructive fallback.
      if (shouldShowLoginAfterSilentAttempt(restored)) {
        this.checkingLogin = false;
      }
    }
  }

  private async prepareFirstLaunch(): Promise<void> {
    try {
      await this.ensureAccountSessionReady();
      const transition: AccountTransitionResult =
        await AccountSessionCoordinator.getInstance().transitionToOffline('first-launch');
      if (!transition.ok) {
        hilog.warn(0x0001, 'LoginDebug',
          '首次启动本地作用域准备未完成，登录界面保持可用: ' + transition.message);
      }
    } catch (error) {
      // 首次启动准备不是首屏门禁。任何异常都只能降低账号/云能力，不能
      // 把刚安装的用户永久留在空白页或全屏 loading 中。
      hilog.warn(0x0001, 'LoginDebug',
        '首次启动本地作用域准备异常，登录界面保持可用: ' + JSON.stringify(error));
    }
  }

  /**
   * 华为账号登录 (官方自定义按钮方式)
   */
  private async doHuaweiLogin(): Promise<void> {
    if (this.appCloneLocalOnly) {
      this.loginError = '应用分身使用本地模式，华为账号登录与云同步已关闭';
      return;
    }
    this.isLoggingIn = true;
    this.loginError = '';
    hilog.info(0x0001, 'LoginDebug', '=== 开始登录 ===');
    try {
      // Step 0: 清除设备级授权缓存 (HMS Core 层), 确保必定弹出授权页
      // 即使 App 卸载重装, HMS Core 可能仍保留之前的授权记录
      hilog.info(0x0001, 'LoginDebug', '步骤0: cancelAuthorization 清除缓存');
      try {
        const cancelReq: authentication.CancelAuthorizationRequest =
          new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
        const cancelCtrl: authentication.AuthenticationController =
          new authentication.AuthenticationController(getContext(this));
        await cancelCtrl.executeRequest(cancelReq);
        hilog.info(0x0001, 'LoginDebug', '步骤0: 授权缓存已清除');
      } catch (_err) {
        // cancelAuthorization 在无缓存时可能抛异常, 忽略继续
        hilog.info(0x0001, 'LoginDebug', '步骤0: 无缓存或清除失败 (正常), 继续');
      }

      hilog.info(0x0001, 'LoginDebug', '步骤1: 创建 AuthorizationWithHuaweiIDRequest');
      const request: authentication.AuthorizationWithHuaweiIDRequest =
        new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
      request.forceAuthorization = true;
      request.scopes = ['openid', 'profile'];
      request.permissions = ['serviceauthcode'];
      request.state = util.generateRandomUUID();
      hilog.info(0x0001, 'LoginDebug', '步骤2: forceAuth=true, scopes=openid+profile');

      hilog.info(0x0001, 'LoginDebug', '步骤3: 创建 AuthenticationController');
      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(getContext(this));

      hilog.info(0x0001, 'LoginDebug', '步骤4: 调用 executeRequest (等待系统弹窗)...');
      const response: authentication.AuthorizationWithHuaweiIDResponse =
        await controller.executeRequest(request);

      hilog.info(0x0001, 'LoginDebug', '步骤5: executeRequest 返回, data=' + (response.data ? '有' : '无'));
      if (response.data) {
        await this.onLoginSuccess(response.data);
      } else {
        hilog.error(0x0001, 'LoginDebug', '步骤6失败: response.data 为空');
        this.loginError = '登录失败，未获取到账号信息';
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0001, 'LoginDebug', '异常: code=' + be.code + ' msg=' + be.message + ' name=' + be.name);
      if (be.code === 1001502014) {
        this.showEnterpriseSheet = true;
      } else if (be.code === 1001502002) {
        this.loginError = '用户取消了登录';
      } else {
        this.loginError = '登录失败 [' + be.code + ']: ' + be.message;
        promptAction.showDialog({
          title: '错误码: ' + be.code,
          message: be.message || '无详细信息',
          buttons: [{ text: '关闭', color: this.accentColor }]
        });
      }
    } finally {
      this.isLoggingIn = false;
      hilog.info(0x0001, 'LoginDebug', '=== 登录结束 ===');
    }
  }

  private async onLoginSuccess(credential: authentication.AuthorizationWithHuaweiIDCredential,
    showToast: boolean = true): Promise<boolean> {
    if (this.appCloneLocalOnly) {
      this.loginError = '应用分身使用本地模式，未接受账号授权结果';
      return false;
    }
    await this.ensureAccountSessionReady();
    const unionId: string = credential.unionID ?? '';
    const openId: string = credential.openID ?? '';
    const authCode: string = credential.authorizationCode ?? '';
    const dataObj: Record<string, Object> = credential as Record<string, Object>;
    const avatarUri: string = (dataObj['avatarUri'] as string) ?? '';
    const nickName: string = (dataObj['nickName'] as string) ?? '';
    const displayName: string = nickName || '华为用户';

    hilog.info(0x0001, 'LoginDebug',
      'Account Kit 登录身份已返回 unionHash=' +
      hashForLog(unionId) + ' openHash=' +
      hashForLog(openId) + ' profile=' +
      (nickName.length > 0 || avatarUri.length > 0
        ? 'present' : 'absent'));

    if (unionId.trim().length === 0) {
      this.loginError = '登录失败：账号没有返回稳定的 UnionID';
      hilog.error(0x0001, 'LoginDebug', '登录被拒绝：UnionID 为空');
      return false;
    }
    const transition: AccountTransitionResult =
      await AccountSessionCoordinator.getInstance().transitionToAccount({
        unionID: unionId,
        openID: openId,
        authorizationCode: authCode,
        idToken: '',
        displayName,
        avatarUrl: avatarUri
      }, { deferCloudBootstrap: true });
    if (!transition.ok) {
      this.loginError = transition.message === '' ? '登录失败：账号数据域切换未完成' : transition.message;
      return false;
    }
    if (showToast) {
      promptAction.showToast({ message: '华为账号登录成功', duration: 2000 });
    }
    this.enterMainPage();
    return true;
  }

  private enterMainPage(): void {
    router.replaceUrl({ url: 'pages/HostListPage' });
  }

  private async enterOfflineMode(): Promise<void> {
    await this.ensureAccountSessionReady();
    const transition: AccountTransitionResult =
      await AccountSessionCoordinator.getInstance().transitionToOffline('offline-login');
    if (!transition.ok && transition.state === 'blocked') {
      this.checkingLogin = false;
      this.loginError = transition.message;
      return;
    }
    this.enterMainPage();
  }

  private async ensureAccountSessionReady(): Promise<void> {
    const context = getContext(this);
    try {
      await AccountSessionCoordinator.getInstance().init(context);
    } catch (_error) {
      // 维持现有失败处理链路（失败也需恢复到页面控制器），不在 UI 层吞掉异常。
    }
  }

  build() {
    if (this.checkingLogin) {
      // 检查持久化登录状态中 — 显示loading, 避免登录页闪现
      Column() {
        LoadingProgress()
          .width(40).height(40)
          .color(this.accentColor)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().bg)
    } else {
      Stack() {
        Column()
          .width('100%').height('100%')
          .backgroundColor(this.pal().bg)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column() {
        Row().width('100%').height(44)

        Column() {
          Column() {
            Text('RD')
              .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          }
          .width(72).height(72).borderRadius(18)
          .backgroundColor(this.accentColor)
          .shadow({ radius: 24, color: 'rgba(0,0,0,0.2)', offsetY: 8 })
          .scale({ x: this.showAnimation ? 1 : 0.6, y: this.showAnimation ? 1 : 0.6 })
          .animation({ duration: 400, curve: Curve.FastOutSlowIn })

          Blank().height(20)

          Text('RemoteDesktop')
            .fontSize(34).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).letterSpacing(1)
            .opacity(this.showAnimation ? 1 : 0)
            .animation({ duration: 500, curve: Curve.EaseOut })

          Text($r('app.string.tagline'))
            .fontSize(13).fontColor(this.pal().text3).margin({ top: 8 })
            .opacity(this.showAnimation ? 1 : 0)
            .animation({ duration: 500, curve: Curve.EaseOut })
        }
        .alignItems(HorizontalAlign.Center).margin({ top: 80 })

        Blank()

        Column() {
          if (this.appCloneLocalOnly) {
            Column() {
              Text(this.appCloneIsClone ? '应用分身 · 本地模式' : '本地安全模式')
                .fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor(this.pal().text)
              Text(this.appCloneStatusText +
                '\n主机、凭据和密钥与主应用隔离；华为账号与云同步在分身中关闭。')
                .fontSize(12).fontColor(this.pal().text3)
                .textAlign(TextAlign.Center).lineHeight(19)
                .margin({ top: 8 })
            }.width('86%').padding(16).borderRadius(14)
              .backgroundColor(this.pal().surface)

            Button(this.appCloneIsClone ? '进入应用分身' : '进入本地模式')
              .fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').width('86%').height(50)
              .backgroundColor(this.accentColor).borderRadius(14)
              .shadow({ radius: 16, color: this.pal().fabGlow, offsetY: 4 })
              .margin({ top: 12 })
              .onClick((): void => { void this.enterOfflineMode(); })
          } else {
            Button() {
              if (this.isLoggingIn) {
                LoadingProgress().width(20).height(20).color(Color.White)
              } else {
                Text($r('app.string.btn_login_huawei'))
                  .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              }
            }
            .width('86%').height(50)
            .backgroundColor(this.accentColor).borderRadius(14)
            .shadow({ radius: 16, color: this.pal().fabGlow, offsetY: 4 })
            .enabled(!this.isLoggingIn)
            .onClick(() => { this.doHuaweiLogin(); })

            Button($r('app.string.btn_offline_mode'))
              .fontSize(14).fontWeight(FontWeight.Normal)
              .fontColor(this.pal().text2)
              .width('86%').height(44)
              .backgroundColor(this.pal().surface).borderRadius(14)
              .margin({ top: 10 })
              .onClick(() => { this.showSkipSheet = true; })
              .bindSheet($$this.showSkipSheet, this.skipSheetBuilder(), {
                height: SheetSize.FIT_CONTENT,
                preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
                dragBar: this.breakpoint === 'sm',
                backgroundColor: this.pal().sheetBg,
                blurStyle: BlurStyle.NONE,
                showClose: false
              })
          }

          if (this.loginError !== '') {
            Text(this.loginError)
              .fontSize(13).fontColor(this.pal().danger).margin({ top: 12 })
          }

          Text($r('app.string.version_info'))
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 24 })
        }
        .alignItems(HorizontalAlign.Center).margin({ bottom: 48 })
      }
      .width('100%').height('100%')
      .bindSheet($$this.showEnterpriseSheet, this.enterpriseSheetBuilder(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false
      })
      }
      .width('100%').height('100%')
    }
  }

  // ==================== 跳过登录确认 Sheet ====================
  @Builder skipSheetBuilder() {
    Column() {
      Column() {
        Text('!').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.accentColor)
      }
      .width(40).height(40).borderRadius(20)
      .backgroundColor(AppConfig.getColorWithAlpha(0.10)).justifyContent(FlexAlign.Center)
      .margin({ top: 24, bottom: 12 })

      Text($r('app.string.offline_warning_title'))
        .fontSize(19).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 }).margin({ top: 4 })

      Text($r('app.string.offline_warning_desc'))
        .fontSize(13).fontColor(this.pal().text2).textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 }).margin({ top: 4, bottom: 24 })

      Row() {
        Button($r('app.string.btn_return_login')).layoutWeight(1).height(44).fontSize(14)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(12)
          .onClick(() => { this.showSkipSheet = false; })
        Blank().width(10)
        Button($r('app.string.btn_confirm_skip')).layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
          .shadow({ radius: 10, color: 'rgba(0,0,0,0.12)', offsetY: 3 })
          .onClick(() => {
            this.showSkipSheet = false;
            setTimeout((): void => { void this.enterOfflineMode(); }, 150);
          })
      }
      .width('100%').padding({ left: 24, right: 24, bottom: 36 })
    }
    .width('100%')
    .backgroundColor(this.pal().bg)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }

  // ==================== 企业认证说明 Sheet ====================
  @Builder enterpriseSheetBuilder() {
    Column() {
      Column() {
        Text('i').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }
      .width(36).height(36).borderRadius(18)
      .backgroundColor(this.accentColor)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 22, bottom: 12 })

      Text($r('app.string.enterprise_info_title'))
        .fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text)
        .margin({ bottom: 6 })

      Text($r('app.string.enterprise_info_desc1'))
        .fontSize(13).fontColor(this.pal().text2)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 3 })

      Text($r('app.string.enterprise_info_desc2'))
        .fontSize(13).fontColor(this.pal().text2)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 18 })

      Button($r('app.string.btn_i_know'))
        .width('70%').height(42).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
        .shadow({ radius: 8, color: 'rgba(0,0,0,0.10)', offsetY: 2 })
        .onClick(() => { this.showEnterpriseSheet = false; })
        .margin({ bottom: 24 })
    }
    .width('100%')
    .backgroundColor(this.pal().bg)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }
}
