import { RustDeskRelayImportResult, RustDeskRelayImportService } from '../../../services/RustDeskRelayImportService';
import { Palette, buildDark, buildLight, AppTheme } from '../../../common/Theme';

@Component
export struct RustDeskRelayConfigPasteSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onCancel: () => void = (): void => {};
  onImported: (result: RustDeskRelayImportResult) => string = (_result: RustDeskRelayImportResult): string => '';

  @State configText: string = '';
  @State errorText: string = '';

  private relayImporter: RustDeskRelayImportService = new RustDeskRelayImportService();

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  private parseAndImport(): void {
    const text: string = this.configText.trim();
    if (text.length === 0) {
      this.errorText = '请先粘贴从 RustDesk 客户端复制的配置';
      return;
    }
    if (text.length > RustDeskRelayImportService.MAX_FILE_SIZE) {
      this.errorText = '配置内容超过 256 KB 限制';
      return;
    }
    const result: RustDeskRelayImportResult = this.relayImporter.parse('手动粘贴配置', text);
    if (!result.ok) {
      this.errorText = result.error;
      return;
    }
    const saveError: string = this.onImported(result);
    if (saveError !== '') {
      this.errorText = saveError;
    }
  }

  build() {
    Column() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onCancel(); })
        Column() {
          Text('粘贴 RustDesk 加密配置').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('手动粘贴后解析并保存中继服务器').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onCancel(); })
      }.width('100%').margin({ bottom: 16 })

      Text('请在 RustDesk 客户端复制服务器配置，再在下方输入框中手动粘贴。应用不会主动读取系统剪贴板。')
        .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(18)
        .width('100%').margin({ bottom: 10 })

      TextArea({ placeholder: '粘贴从 RustDesk 复制来的加密配置', text: this.configText })
        .height(170).borderRadius(10).backgroundColor(this.pal().surface).fontSize(12).fontFamily('monospace')
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).padding(12)
        .onChange((value: string): void => { this.configText = value; this.errorText = ''; })

      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font())
          .width('100%').padding(10).borderRadius(9).backgroundColor(this.pal().surface).margin({ top: 10 })
      }

      Row() {
        Button('取消').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.pal().surface)
          .fontColor(this.pal().text2).onClick((): void => { this.onCancel(); })
        Button('解析并导入').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.accentColor)
          .fontColor(Color.White).margin({ left: 10 }).onClick((): void => { this.parseAndImport(); })
      }.width('100%').margin({ top: 14 })
    }
    .width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    .constraintSize({ maxWidth: 760 }).backgroundColor(this.pal().sheetBg)
  }
}
