import { ProBadge } from './ProBadge';
import { common } from '@kit.AbilityKit';
import { window, LengthMetrics } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProFeatureGate } from './ProFeatureGate';
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
  private windowId: number = 0;
  private stop: (() => void) | null = null;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    try { this.windowId = window.findWindow(this.getUIContext().getWindowName()).getWindowProperties().id; } catch (_error) {}
    this.stop = ProContinuationService.getInstance().subscribe((): void => {
      const state = ProContinuationService.getInstance().snapshot();
      this.status = state.sourceWindow === this.windowId ? state.sourceMessage : '';
      this.canClose = state.sourceWindow === this.windowId && state.sourceCloseAllowed;
    });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }
  @Builder private controls() {
    Column({ space: 8 }) {
      Row() { Blank(); ProBadge() }.width('100%')
      Button(this.status === '' ? '准备同账号接续' : '重新准备接续')
        .width('100%').constraintSize({ minHeight: 44 }).fontSize(14)
        .backgroundColor(Color.Transparent).fontColor(this.accent).onClick(this.onPrepare)
      if (this.status !== '') {
        Text(this.status).fontSize(12).fontColor(this.pal().text2).width('100%')
        if (this.canClose) {
          Button('目标已就绪，结束本端会话').constraintSize({ minHeight: 44 }).fontSize(13)
            .onClick((): void => { ProContinuationService.getInstance().closeConfirmedSource(this.windowId); })
        }
        Button('取消接续准备').constraintSize({ minHeight: 44 }).fontSize(13)
          .backgroundColor(Color.Transparent).fontColor(this.pal().text2)
          .onClick((): void => { ProContinuationService.getInstance().cancelSource(this.windowId); })
      }
    }.width('100%').padding(12)
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
          Button('确认并进行主机认证').constraintSize({ minHeight: 44 }).fontSize(13)
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
