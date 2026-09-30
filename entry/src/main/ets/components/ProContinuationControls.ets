import { ProBadge } from './ProBadge';
import { common } from '@kit.AbilityKit';
import { window, LengthMetrics } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProFeatureGate } from './ProFeatureGate';
import { ProContinuationPreferences } from '../services/pro/ProContinuationPreferences';
import { ProContinuationService, proContinuationContext, ProContinuationSnapshot } from '../services/pro/ProContinuationService';
import { RemoteHost } from '../model/RemoteHost';

@Component
export struct ProContinuationControls {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop protocol: string = 'ssh';
  onPrepare: () => void = (): void => {};
  @State status: string = '';
  @State canClose: boolean = false;
  @State auto: boolean = true;
  private windowId: number = 0;
  private stopPreferences: (() => void) | null = null;
  private stop: (() => void) | null = null;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    try { this.windowId = window.findWindow(this.getUIContext().getWindowName()).getWindowProperties().id; } catch (_error) {}
    this.stopPreferences = ProContinuationPreferences.getInstance().subscribe((): void => {
      this.auto = ProContinuationPreferences.getInstance().settings().auto;
    });
    this.stop = ProContinuationService.getInstance().subscribe((): void => {
      const state = ProContinuationService.getInstance().snapshot();
      this.status = state.sourceWindow === this.windowId ? state.sourceMessage : '';
      this.canClose = state.sourceWindow === this.windowId && state.sourceCloseAllowed;
    });
  }
  aboutToDisappear(): void {
    this.stop?.(); this.stop = null; this.stopPreferences?.(); this.stopPreferences = null;
  }
  // Matches the SSH "更多" menu rows: title (+ Pro badge), grey detail, trailing chevron.
  @Builder private menuRow(title: string, detail: string, badge: boolean, action: () => void) {
    Row() {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(title).fontSize(14).fontColor(this.pal().text).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          if (badge) { ProBadge() }
        }
        if (detail.length > 0) {
          Text(detail).fontSize(11).fontColor(this.pal().text3).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
    }
    .width('100%').constraintSize({ minHeight: 52 }).padding({ left: 14, right: 12, top: 6, bottom: 6 })
    .onClick(action).accessibilityText(title + (detail.length > 0 ? '，' + detail : ''))
  }
  @Builder private controls() {
    Column() {
      this.menuRow('同账号接续', this.status !== '' ? this.status : (this.auto && this.protocol === 'ssh' ?
        '连接后自动开启 · 点按重新开启或授予协同权限' : '点按后 2 分钟内在同账号设备继续') + ' · 支持直连 SSH、RDP、RustDesk、VNC',
        true, this.onPrepare)
      if (this.status !== '') {
        if (this.canClose) {
          this.menuRow('结束本端会话', '目标设备已就绪', false,
            (): void => { ProContinuationService.getInstance().closeConfirmedSource(this.windowId); })
        }
        if (!(this.auto && this.protocol === 'ssh')) {
          this.menuRow('取消接续准备', '', false,
            (): void => { ProContinuationService.getInstance().cancelSource(this.windowId); })
        }
      }
    }.width('100%')
  }
  build() {
    ProFeatureGate({ featureId: 'pro.connection.continuation', context: proContinuationContext(this.protocol), content: (): void => { this.controls(); } })
  }
}

@Component
export struct ProIncomingContinuationCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State state: ProContinuationSnapshot = ProContinuationService.getInstance().snapshot();
  @State busy: boolean = false;
  onConnect: (host: RemoteHost, transferId: string) => void = (_host: RemoteHost, _id: string): void => {};
  private stop: (() => void) | null = null;
  private live: boolean = false;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  // HostListPage accepts each incoming transfer once automatically; this card shows the progress,
  // the failure reason and a retry.
  aboutToAppear(): void {
    this.live = true;
    this.stop = ProContinuationService.getInstance().subscribe((): void => {
      this.state = ProContinuationService.getInstance().snapshot();
    });
  }
  aboutToDisappear(): void { this.live = false; this.stop?.(); this.stop = null; }
  private async accept(): Promise<void> {
    if (this.busy || !this.live) { return; }
    this.busy = true;
    const service = ProContinuationService.getInstance();
    const id = service.incomingId();
    try {
      const host = await service.accept(getContext(this) as common.UIAbilityContext);
      if (host !== null && this.live && id === service.incomingId()) { this.onConnect(host, id); }
      else if (host !== null) { service.cancelIncoming(id); }
    } finally { if (this.live) { this.busy = false; } }
  }
  build() {
    if (this.state.incoming) {
      Column({ space: 8 }) {
        Text(this.state.incomingProtocol === 'rdp' ? '继续另一台设备的 RDP 会话' : '继续另一台设备的 SSH 会话')
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(this.state.incomingLabel).fontSize(14).fontColor(this.pal().text).maxLines(2)
        Text(this.state.incomingEndpoint).fontSize(12).fontColor(this.pal().text2).maxLines(3)
        Text(this.state.incomingMessage).fontSize(12).fontColor(this.pal().text2)
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8) } }) {
          Button(this.busy ? '正在接续…' : '重试接续').constraintSize({ minHeight: 44 }).fontSize(13)
            .enabled(!this.busy && this.state.incomingCanAccept)
            .onClick((): void => { void this.accept(); })
          Button('拒绝').constraintSize({ minHeight: 44 }).fontSize(13).backgroundColor(Color.Transparent)
            .fontColor(this.pal().text2).onClick((): void => { ProContinuationService.getInstance().cancelIncoming(); })
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
        .backgroundColor(this.pal().card).borderRadius(16).margin({ bottom: 12 })
    }
  }
}
