import {
  MOONLIGHT_TOOLBAR_AUTO_HIDE_MS,
  MoonlightToolbarAction,
  MoonlightToolbarItem,
  moonlightToolbarItems
} from '../../services/MoonlightUiPolicy';
import { MoonlightBrandIcon } from './MoonlightBrandIcon';

@Component
export struct MoonlightSessionToolbar {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop audioAvailable: boolean = false;
  @Prop controllerAvailable: boolean = false;
  @Prop pipAvailable: boolean = false;
  @Prop qualityColor: string = '#66DD7A';
  @Prop qualityLabel: string = '良好';
  @State private expanded: boolean = false;
  @State private pinned: boolean = false;
  private hideTimer: number = -1;
  onAction: (action: MoonlightToolbarAction) => void = (_action: MoonlightToolbarAction): void => {};
  onUnavailable: (reason: string) => void = (_reason: string): void => {};

  private items(): MoonlightToolbarItem[] {
    return moonlightToolbarItems(
      this.breakpoint, this.audioAvailable, this.controllerAvailable, this.pipAvailable);
  }

  private icon(action: MoonlightToolbarAction): Resource {
    if (action === 'control') { return $r('sys.symbol.display'); }
    if (action === 'keyboard') { return $r('sys.symbol.keyboard'); }
    if (action === 'controller') { return $r('sys.symbol.gamecontroller_fill'); }
    if (action === 'audio') { return $r('sys.symbol.speaker_slash_fill'); }
    if (action === 'display') { return $r('sys.symbol.display'); }
    if (action === 'more') { return $r('sys.symbol.ellipsis_bubble'); }
    return $r('sys.symbol.xmark_circle_fill');
  }

  private clearTimer(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
  }

  private scheduleHide(): void {
    this.clearTimer();
    if (!this.expanded || this.pinned) { return; }
    this.hideTimer = setTimeout((): void => {
      if (!this.pinned) { this.expanded = false; }
      this.clearTimer();
    }, MOONLIGHT_TOOLBAR_AUTO_HIDE_MS);
  }

  private invoke(item: MoonlightToolbarItem): void {
    this.scheduleHide();
    if (!item.enabled) { this.onUnavailable(item.disabledReason); return; }
    this.onAction(item.action);
  }

  aboutToDisappear(): void { this.clearTimer(); }

  @Builder private toolItem(item: MoonlightToolbarItem) {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(this.icon(item.action)).fontSize(20)
          .fontColor([item.dangerous ? '#FF8A80' : (item.enabled ? '#FFFFFF' : 'rgba(255,255,255,0.32)')])
        Text(item.label).fontSize(9)
          .fontColor(item.dangerous ? '#FF8A80' : (item.enabled ? '#FFFFFF' : 'rgba(255,255,255,0.32)'))
          .maxLines(1)
      }
    }
    .width(50).height(50).borderRadius(14)
    .backgroundColor(item.dangerous ? 'rgba(255,90,90,0.12)' : 'rgba(255,255,255,0.08)')
    .enabled(true)
    .opacity(item.enabled ? 1 : 0.72)
    .accessibilityText(item.enabled ? item.label : item.label + '，' + item.disabledReason)
    .onClick((): void => { this.invoke(item); })
  }

  build() {
    Stack() {
      if (!this.expanded) {
        Row() {
          MoonlightBrandIcon({ iconSize: 18, tint: '#FFFFFF', accessibilityLabel: '打开 Moonlight 控制' })
          Column().width(7).height(7).borderRadius(4).backgroundColor(this.qualityColor)
            .margin({ left: 5 })
        }
        .width(46).height(58).justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(14,18,28,0.78)')
        .borderRadius({ topLeft: 18, bottomLeft: 18, topRight: 6, bottomRight: 6 })
        .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
        .onClick((): void => { this.expanded = true; this.scheduleHide(); })
        .accessibilityText('打开串流控制，连接质量' + this.qualityLabel)
      } else {
        Row({ space: 8 }) {
          ForEach(this.items(), (item: MoonlightToolbarItem): void => {
            this.toolItem(item)
          }, (item: MoonlightToolbarItem): string => item.action)
          Button() {
            SymbolGlyph(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'))
              .fontSize(17).fontColor([this.pinned ? this.accentColor : '#FFFFFF'])
          }.width(44).height(50).borderRadius(14).backgroundColor('rgba(255,255,255,0.08)')
            .onClick((): void => { this.pinned = !this.pinned; this.scheduleHide(); })
            .accessibilityText(this.pinned ? '取消固定工具条' : '固定工具条')
        }
        .padding(8).backgroundColor('rgba(14,18,28,0.86)').borderRadius(18)
        .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
        .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 5 })
        .onHover((hover: boolean): void => { if (hover) { this.clearTimer(); } else { this.scheduleHide(); } })
      }
    }
  }
}
