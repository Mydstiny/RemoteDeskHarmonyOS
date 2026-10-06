/**
 * QrCodeScanner.ets — 二维码扫码组件 (v3, API 23)
 *
 * 使用 @kit.ScanKit 系统扫码界面 + 手动 URI 粘贴回退。
 */
import { TotpEntry } from '../model/TotpEntry';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import { TotpEngine } from '../services/TotpEngine';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { scanBarcode, scanCore } from '@kit.ScanKit';

@Component
export struct QrCodeScanner {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  /** The host sheet has its own title. */
  @Prop showTitle: boolean = true;
  /** 解析并添加 adds at once; a flow that confirms first says 解析. */
  @Prop parseLabel: string = '解析并添加';
  @State otpUri: string = '';
  @State status: string = '';
  onScanned?: (entry: TotpEntry) => void;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private async startScan(): Promise<void> {
    this.status = '正在启动扫码...';
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: false
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(
        getContext(this), options);
      if (result?.originalValue) {
        this.otpUri = result.originalValue;
        this.parseUri();
        this.status = '';
      } else {
        this.status = '未识别到二维码';
      }
    } catch (err) {
      this.status = '没有完成扫码（已取消，或这台设备不能扫码）。也可以在下面粘贴 otpauth 配置';
    }
  }

  private parseUri(): void {
    const entry: TotpEntry | null = TotpEngine.parseOtpAuthUri(this.otpUri.trim());
    if (entry) {
      this.status = '解析成功';
      if (this.onScanned) { this.onScanned(entry); }
    } else {
      this.status = '无效的 otpauth URI';
    }
  }

  build() {
    Column() {
      if (this.showTitle) {
        Text('添加 2FA 验证器').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).margin({ bottom: 12 })
      }

      // 扫码按钮
      Button('扫描二维码').width('100%').height(44).fontSize(14)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).borderRadius(10)
        .margin({ bottom: 14 })
        .onClick(() => { this.startScan(); })

      // 分隔线
      Row() {
        Column().height(1).backgroundColor(this.pal().divider).layoutWeight(1)
        Text('  或  ').fontSize(11).fontColor(this.pal().text3)
        Column().height(1).backgroundColor(this.pal().divider).layoutWeight(1)
      }.width('100%').margin({ bottom: 12 })

      // 手动输入
      Text('粘贴 otpauth URI:').fontSize(12).fontColor(this.pal().text2)
        .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)

      TextInput({ placeholder: 'otpauth://totp/...', text: this.otpUri })
        .height(44).backgroundColor(this.pal().surface).borderRadius(10)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .fontSize(13).padding({ left: 12, right: 12 })
        .onChange((v: string) => { this.otpUri = v; })
        .margin({ bottom: 10 })

      if (this.status !== '') {
        Text(this.status).fontSize(12)
          .fontColor(this.status.includes('成功') ? this.pal().success : this.pal().text2)
          .margin({ bottom: 10 })
      }

      Button(this.parseLabel).width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).borderRadius(10)
        .enabled(this.otpUri.trim() !== '')
        .onClick(() => { this.parseUri(); })
    }
    .width('100%')
  }
}
