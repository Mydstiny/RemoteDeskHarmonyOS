/**
 * TotpCodeCard.ets — TOTP 验证码卡片 (v4: 纯展示, 操作由 swipeAction 处理)
 */
import { TotpEntry, TotpCode } from '../model/TotpEntry';
import { TotpEngine } from '../services/TotpEngine';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  TotpBrandVisual, totpBrandLogoUrl, totpBrandVisual, totpInitialOf
} from '../services/TotpBrandService';

@Component
export struct TotpCodeCard {
  @Prop entry: TotpEntry;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('totpLogoMode') totpLogoMode: string = 'logo';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop pageLocked: boolean = false;
  @Prop showCheckbox: boolean = false;
  @Prop checkboxSelected: boolean = false;
  onCheckChange?: (checked: boolean) => void;
  @State codeStr: string = '------';
  @State remaining: number = 30;
  @State logoFailed: boolean = false;
  private timer: number = -1;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    this.logoFailed = false;
    if (!this.pageLocked && !this.entry.locked) {
      this.refresh();
      this.timer = setInterval(() => { this.refresh(); }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private refresh(): void {
    const tc: TotpCode = TotpEngine.generateCode(this.entry);
    this.codeStr = tc.code;
    this.remaining = tc.remaining;
  }

  private copyCode(): void {
    if (this.pageLocked || this.entry.locked) { return; }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.codeStr);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: `验证码 ${this.codeStr} 已复制`, duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  private avatarVisual(): TotpBrandVisual {
    return totpBrandVisual(this.entry.issuer, this.entry.account);
  }

  build() {
    Row() {
      if (this.showCheckbox) {
        Checkbox()
          .select(this.checkboxSelected)
          .selectedColor('#007DFF')
          .margin({ right: 8 })
          .onChange((v: boolean) => { if (this.onCheckChange) { this.onCheckChange(v); } })
      }
      // Logo 模式只请求经过 issuer 白名单映射的 Simple Icons URL；失败时
      // 自动回退到本地首字母，不会因为网络或主题色导致卡片不可读。
      if (this.totpLogoMode === 'logo' && !this.logoFailed &&
        totpBrandLogoUrl(this.entry.issuer, this.entry.account) !== '') {
        Image(totpBrandLogoUrl(this.entry.issuer, this.entry.account))
          .width(42).height(42).padding(9).borderRadius(21)
          .backgroundColor(this.pal().surface)
          .objectFit(ImageFit.Contain)
          .onError(() => { this.logoFailed = true; })
          .margin({ right: 10 })
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text(totpInitialOf(this.entry.issuer))
            .fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(this.avatarVisual().foreground)
            .fontFamily(AppTheme.fontFamily)
            .textAlign(TextAlign.Center)
            .maxLines(1)
        }
        .width(42).height(42)
        .borderRadius(21)
        .backgroundColor(this.avatarVisual().background)
        .margin({ right: 10 })
      }

      Column() {
        Row() {
          Text(this.entry.issuer || 'Unknown')
            .fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
            .maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.entry.locked) {
            SymbolGlyph($r('sys.symbol.ohos_lock'))
              .fontSize(14)
              .fontColor([this.accentColor])
              .margin({ left: 6 })
          }
        }
        if (this.entry.account !== '') {
          Text(this.entry.account)
            .fontSize(12).fontColor(this.pal().text2)
            .fontFamily(AppTheme.fontFamily)
            .margin({ top: 2 }).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.entry.locked || this.pageLocked) {
          Text('已锁定 · 需要验证')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (!this.entry.locked && !this.pageLocked) {
        Column() {
          Text(this.codeStr)
            .fontSize(26).fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor).fontFamily('monospace')
            .onClick(() => { this.copyCode(); })
          Row() {
            Progress({ value: this.remaining, total: this.entry.period, type: ProgressType.Linear })
              .width(60).height(3).color(this.accentColor)
              .backgroundColor(this.pal().surface)
            Text(`${this.remaining}s`)
              .fontSize(10).fontColor(this.pal().text3)
              .fontFamily('monospace').margin({ left: 6 })
          }.margin({ top: 4 })
        }.alignItems(HorizontalAlign.End)
      } else {
        SymbolGlyph($r('sys.symbol.ohos_lock'))
          .fontSize(24)
          .fontColor([this.pal().text3])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
    .borderRadius(14).backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }
}
