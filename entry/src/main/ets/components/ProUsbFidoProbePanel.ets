import { DEBUG } from 'BuildProfile';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { ProUsbFidoCandidate, ProUsbFidoProbe } from '../services/pro/ProUsbFidoProbe';

@Component
export struct ProUsbFidoProbePanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State supported: boolean = false;
  @State busy: boolean = false;
  @State candidates: ProUsbFidoCandidate[] = [];
  @State message: string = '连接 USB 安全密钥后读取设备，再选择对应接口进行检测。';
  isOpen: () => boolean = (): boolean => true;
  private live: boolean = false;
  private foreground: boolean = true;
  private lease: (() => boolean) | null = null;
  private unsubscribe: (() => void) | null = null;
  private application: common.ApplicationContext | null = null;
  private applicationState: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => { this.foreground = true; },
    onApplicationBackground: (): void => { this.foreground = false; this.cancel(); }
  };

  aboutToAppear(): void {
    if (!DEBUG) { return; }
    this.live = true;
    try {
      this.application = (getContext(this) as common.UIAbilityContext).getApplicationContext();
      this.application.on('applicationStateChange', this.applicationState);
    } catch (_error) { this.application = null; this.supported = false; }
    this.unsubscribe = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      this.supported = this.application !== null && ProUsbFidoProbe.getInstance().debugAllowed();
      this.candidates = [];
    });
  }
  aboutToDisappear(): void {
    this.live = false; this.cancel(); this.unsubscribe?.(); this.unsubscribe = null;
    if (this.application !== null) {
      try { this.application.off('applicationStateChange', this.applicationState); } catch (_error) {}
      this.application = null;
    }
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private cancel(): void {
    if (this.lease !== null) {
      ProUsbFidoProbe.getInstance().cancel(this.lease);
      if (this.live) { this.message = '已取消 USB 检测'; }
    }
  }
  private refresh(): void {
    if (!this.live || !this.isOpen() || !this.foreground || this.application === null) { return; }
    this.candidates = ProUsbFidoProbe.getInstance().list();
    this.message = this.candidates.length === 0 ? '没有发现可检测的 64-byte 非 Boot HID 接口，或另一窗口正在检测。' :
      '列表只是候选接口。选择后将申请临时 USB 授权，并检查 FIDO 报告格式。';
  }
  private async probe(candidate: ProUsbFidoCandidate): Promise<void> {
    if (this.busy || this.application === null) { return; }
    const epoch = ProPurchaseLifecycle.capture();
    const lease = (): boolean => this.live && this.isOpen() && this.foreground && ProPurchaseLifecycle.current(epoch);
    this.lease = lease; this.busy = true; this.message = '正在请求授权并检测 USB 安全密钥…';
    try {
      const message = await ProUsbFidoProbe.getInstance().probe(candidate.key, lease);
      if (lease()) { this.message = message; }
    } catch (error) {
      if (lease()) { this.message = (error as Error).message; }
    } finally {
      if (this.lease === lease) { this.lease = null; this.busy = false; }
    }
  }
  build() {
    if (DEBUG && this.supported) {
      Column({ space: 10 }) {
        Text('开发者验证 · USB 安全密钥').fontSize(14).fontColor(this.pal().text).width('100%')
        Text('仅验证本机 USB 初始化。不会读取 PIN、注册通行密钥或执行远端认证。')
          .fontSize(12).fontColor(this.pal().text2).width('100%')
        Button('读取 USB 候选接口').enabled(!this.busy).onClick((): void => { this.refresh(); })
        ForEach(this.candidates, (candidate: ProUsbFidoCandidate): void => {
          Button(candidate.label).fontSize(13).width('100%').enabled(!this.busy)
            .onClick((): void => { void this.probe(candidate); })
        }, (candidate: ProUsbFidoCandidate): string => candidate.key)
        Text(this.message).fontSize(12).fontColor(this.pal().text2).width('100%')
        if (this.busy) {
          Button('取消检测').onClick((): void => { this.cancel(); })
        }
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
    }
  }
}
