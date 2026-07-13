/**
 * QrCodeScanner.ets — 二维码扫码组件 (v3, API 23)
 *
 * 使用 @kit.ScanKit 系统扫码界面 + 手动 URI 粘贴回退。
 */
import { TotpEntry } from '../model/TotpEntry';
import { TotpEngine } from '../services/TotpEngine';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { scanBarcode, scanCore } from '@kit.ScanKit';

@Component
export struct QrCodeScanner {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
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
      this.status = '扫码取消或不可用';
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
      Text('添加 2FA 验证器').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 12 })

      // 扫码按钮
      Button('扫描二维码').width('100%').height(44).fontSize(14)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
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
          .fontColor(this.status.includes('成功') ? '#51CF66' : this.pal().text2)
          .margin({ bottom: 10 })
      }

      Button('解析并添加').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
        .enabled(this.otpUri.trim() !== '')
        .onClick(() => { this.parseUri(); })
    }
    .width('100%')
  }
}
