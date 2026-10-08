import { ProBadge } from './ProBadge';
import { window } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProFeatureGate } from './ProFeatureGate';
import { ProConnectionShareSender, proConnectionShareContext } from '../services/pro/ProConnectionShareSender';
import { ProConnectionShareReceiver, ProConnectionShareIncomingSnapshot } from '../services/pro/ProConnectionShareReceiver';

@Component
export struct ProConnectionShareControls {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  onPrepare: () => void = (): void => {};
  @State message: string = '';
  private windowId: number = 0;
  private stop: (() => void) | null = null;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    try { this.windowId = window.findWindow(this.getUIContext().getWindowName()).getWindowProperties().id; } catch (_error) {}
    this.stop = ProConnectionShareSender.getInstance().subscribe((): void => {
      const state = ProConnectionShareSender.getInstance().snapshot();
      this.message = state.windowId === this.windowId ? state.message : '';
    });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }
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
      this.menuRow(this.message === '' ? '碰一碰分享连接' : '重新准备分享',
        this.message === '' ? '分享直连 SSH 信息，接收方在本机自行认证' : this.message, true, this.onPrepare)
      if (this.message !== '') {
        this.menuRow('结束分享准备', '', false,
          (): void => { ProConnectionShareSender.getInstance().stop(this.windowId); })
      }
    }.width('100%')
  }
  build() {
    ProFeatureGate({ featureId: 'pro.connection.knockShare', context: proConnectionShareContext(), content: (): void => { this.controls(); } })
  }
}

@Component
export struct ProIncomingConnectionShareCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State state: ProConnectionShareIncomingSnapshot = ProConnectionShareReceiver.getInstance().snapshot();
  onImport: (id: string) => void = (_id: string): void => {};
  private stop: (() => void) | null = null;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    this.stop = ProConnectionShareReceiver.getInstance().subscribe((): void => {
      this.state = ProConnectionShareReceiver.getInstance().snapshot();
    });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }
  build() {
    if (this.state.visible) {
      Column({ space: 8 }) {
        Text('收到 SSH 连接分享').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(this.state.label).fontSize(14).fontColor(this.pal().text).maxLines(2)
        Text(this.state.endpoint).fontSize(12).fontColor(this.pal().text2).maxLines(3)
        if (this.state.directory !== '') {
          Text('连接后打开目录：' + this.state.directory).fontSize(12).fontColor(this.pal().text2).maxLines(3)
        }
        Text(this.state.message).fontSize(12).fontColor(this.pal().text2)
        Button('核对并添加主机').constraintSize({ minHeight: 44 }).fontSize(13).enabled(this.state.canAccept)
          .onClick((): void => { this.onImport(this.state.id); })
        Button('拒绝').constraintSize({ minHeight: 44 }).fontSize(13).backgroundColor(Color.Transparent)
          .fontColor(this.pal().text2).onClick((): void => { ProConnectionShareReceiver.getInstance().cancel(this.state.id); })
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
        .backgroundColor(this.pal().card).borderRadius(16).margin({ bottom: 12 })
    }
  }
}
