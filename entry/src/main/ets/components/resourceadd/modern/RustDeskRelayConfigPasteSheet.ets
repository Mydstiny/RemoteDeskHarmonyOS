import { RustDeskRelayImportResult, RustDeskRelayImportService } from '../../../services/RustDeskRelayImportService';
import { Palette, buildDark, buildLight, AppTheme } from '../../../common/Theme';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { promptAction } from '@kit.ArkUI';

@Component
export struct RustDeskRelayConfigPasteSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  /** Back to the relay form. */
  onCancel: () => void = (): void => {};
  /** ✕: closes the whole sheet (the page asks first when something typed would be lost). */
  onClose: () => void = (): void => {};
  onDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  onImported: (result: RustDeskRelayImportResult) => string = (_result: RustDeskRelayImportResult): string => '';

  @State configText: string = '';
  @State errorText: string = '';

  private relayImporter: RustDeskRelayImportService = new RustDeskRelayImportService();

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  /** Back or 取消 with pasted text: ask before it is dropped. */
  private cancelWithConfirm(): void {
    if (this.configText.trim() === '') { this.onCancel(); return; }
    promptAction.showDialog({
      title: '放弃粘贴的配置？',
      message: '粘贴的内容还没有解析和填写，返回后不会保留。',
      buttons: [{ text: '继续编辑', color: this.pal().text2 }, { text: '放弃', color: this.pal().danger }]
    }).then((result: Object): void => {
      const value: Record<string, number> = result as Record<string, number>;
      if (value['index'] === 1) { this.onCancel(); }
    }).catch((): void => {});
  }

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
        .accessibilityText('返回').onClick((): void => { this.cancelWithConfirm(); })
        Column() {
          Text('粘贴 RustDesk 加密配置').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('手动粘贴后解析，确认服务器 Key 类型后再保存').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .accessibilityText('关闭').onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 16 })

      Text('请在 RustDesk 客户端复制服务器配置，再在下方输入框中手动粘贴。应用不会主动读取系统剪贴板。')
        .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(18)
        .width('100%').margin({ bottom: 10 })

      TextArea({ placeholder: '粘贴从 RustDesk 复制来的加密配置', text: this.configText })
        .height(170).borderRadius(10).backgroundColor(this.pal().surface).fontSize(12).fontFamily('monospace')
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).padding(12)
        .onChange((value: string): void => {
          this.configText = value; this.errorText = '';
          this.onDirtyChange(value.trim() !== '');
        })

      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font())
          .width('100%').padding(10).borderRadius(9).backgroundColor(this.pal().surface).margin({ top: 10 })
      }

      Row() {
        Button('取消').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.pal().surface)
          .fontColor(this.pal().text2).onClick((): void => { this.cancelWithConfirm(); })
        Button('解析并填写').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.accentColor)
          .fontColor(appUiOnAccentText(this.accentColor)).margin({ left: 10 }).onClick((): void => { this.parseAndImport(); })
      }.width('100%').margin({ top: 14 })
    }
    .width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    .constraintSize({ maxWidth: 760 }).backgroundColor(this.pal().sheetBg)
  }
}
