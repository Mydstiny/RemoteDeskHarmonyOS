import { display } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { ProBadge } from '../ProBadge';
import {
  RemoteResolutionPreset,
  rdpResolutionLabel,
  rdpResolutionPresets
} from '../../services/RemoteResolutionPresetPolicy';
import {
  RDP_PRO_DESKTOP_SCALE_GRID,
  isRdpFreeDesktopScale,
  rdpDesktopScaleSelection,
  remoteDisplayAspectLabel,
  remoteDisplaySizeLabel
} from '../../services/RemoteDisplayProfilePolicy';

/** Presets grouped under one aspect ratio heading. */
interface RdpPresetGroup { aspect: string; presets: RemoteResolutionPreset[]; }

const ASPECT_ORDER: string[] = ['16:9', '16:10', '3:2', '4:3', '5:4', '21:9', '32:9'];

function presetGroups(): RdpPresetGroup[] {
  const groups: RdpPresetGroup[] = [];
  rdpResolutionPresets().forEach((preset: RemoteResolutionPreset): void => {
    const aspect: string = remoteDisplayAspectLabel(preset.width, preset.height);
    const found: RdpPresetGroup | undefined = groups.find((group: RdpPresetGroup): boolean => group.aspect === aspect);
    if (found !== undefined) { found.presets.push(preset); } else { groups.push({ aspect, presets: [preset] }); }
  });
  const rank = (aspect: string): number => {
    const index: number = ASPECT_ORDER.indexOf(aspect);
    return index < 0 ? ASPECT_ORDER.length : index;
  };
  return groups.sort((a: RdpPresetGroup, b: RdpPresetGroup): number => rank(a.aspect) - rank(b.aspect));
}

/**
 * Pro 远端显示方案: remote desktop size and Windows scale edited together in one sheet. Settings and the RDP session
 * panel both open it; it reads the saved values from AppStorage and writes through the caller's handlers, so each
 * caller keeps its own rules (settings persist for the next connection, a live session also renegotiates).
 * Opened only from entries gated by ProEntries.visible(PRO_RDP_ADVANCED_DISPLAY_FEATURE).
 */
@Component
export struct RdpDisplayProfilePanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  /** The session panel is always dark. */
  @Prop forceDark: boolean = false;
  @Prop isDesktopDevice: boolean = false;
  /** Shown under the title: when changes take effect. */
  @Prop applyHint: string = '保存后用于下次连接';
  @StorageProp('rdpDesktopResolutionId') @Watch('onResolutionChange') resolutionId: string = 'auto';
  @StorageProp('rdpCustomWidth') @Watch('onCustomChange') customWidth: number = 1920;
  @StorageProp('rdpCustomHeight') @Watch('onCustomChange') customHeight: number = 1080;
  @StorageProp('rdpDesktopScaleMode') scaleMode: string = 'auto';
  @StorageProp('rdpDesktopScalePercent') scalePercent: number = 100;
  /** 自适应 / 预设 / 自定义; switching tabs does not apply anything by itself except 自适应. */
  @State sizeTab: string = 'auto';
  @State widthDraft: string = '1920';
  @State heightDraft: string = '1080';
  @State scaleDraft: string = '';
  private groups: RdpPresetGroup[] = presetGroups();
  onResolution: (id: string) => void = (_id: string): void => {};
  onCustomResolution: (width: string, height: string) => void = (_width: string, _height: string): void => {};
  onRemoteUiScale: (value: string) => void = (_value: string): void => {};
  onDesktopScalePercent: (value: string) => void = (_value: string): void => {};

  aboutToAppear(): void {
    this.onResolutionChange();
    this.onCustomChange();
  }

  onResolutionChange(): void {
    this.sizeTab = this.resolutionId === 'auto' ? 'auto' : this.resolutionId === 'custom' ? 'custom' : 'preset';
  }

  onCustomChange(): void {
    this.widthDraft = this.customWidth.toString();
    this.heightDraft = this.customHeight.toString();
  }

  private pal(): Palette {
    return this.forceDark || this.theme !== 'light' ? buildDark(this.accent) : buildLight(this.accent);
  }

  private maxPanelHeight(): number {
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      return Math.max(360, Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.82));
    } catch (_error) {
      return 560;
    }
  }

  private scaleSelection(): string { return rdpDesktopScaleSelection(this.scaleMode, this.scalePercent, true); }

  /** Percent currently in effect, or 0 for 自动. */
  private activeScale(): number {
    const selection: string = this.scaleSelection();
    return selection === 'auto' ? 0 : selection === 'custom' ? this.scalePercent : Number(selection);
  }

  private pickScale(percent: number): void {
    if (percent === 0) { this.onRemoteUiScale('auto'); return; }
    if (isRdpFreeDesktopScale(percent)) { this.onRemoteUiScale(percent.toString()); return; }
    this.onDesktopScalePercent(percent.toString());
  }

  private customDirty(): boolean {
    return this.resolutionId !== 'custom' || this.widthDraft !== this.customWidth.toString() ||
      this.heightDraft !== this.customHeight.toString();
  }

  private scaleDraftUsable(): boolean {
    const value: number = Number(this.scaleDraft);
    return this.scaleDraft.length > 0 && Number.isInteger(value) && value >= 100 && value <= 500 &&
      value !== this.activeScale();
  }

  private sizeTitle(): string {
    if (this.resolutionId === 'auto') { return this.isDesktopDevice ? '跟随会话窗口' : '连接时适应设备'; }
    if (this.resolutionId === 'custom') { return remoteDisplaySizeLabel(this.customWidth, this.customHeight); }
    return rdpResolutionLabel(this.resolutionId);
  }

  private sizeAspect(): string {
    if (this.resolutionId === 'auto') { return '自适应'; }
    if (this.resolutionId === 'custom') { return remoteDisplayAspectLabel(this.customWidth, this.customHeight); }
    const preset: RemoteResolutionPreset | undefined = rdpResolutionPresets()
      .find((item: RemoteResolutionPreset): boolean => item.id === this.resolutionId);
    return preset === undefined ? '' : remoteDisplayAspectLabel(preset.width, preset.height);
  }

  /** Preview frame proportional to the chosen size (a dashed 16:10 frame for 自适应). */
  private previewRatio(): number {
    if (this.resolutionId === 'custom' && this.customHeight > 0) { return this.customWidth / this.customHeight; }
    const preset: RemoteResolutionPreset | undefined = rdpResolutionPresets()
      .find((item: RemoteResolutionPreset): boolean => item.id === this.resolutionId);
    return preset === undefined || preset.height <= 0 ? 1.6 : preset.width / preset.height;
  }
  private previewWidth(): number { return this.previewRatio() >= 1.6 ? 132 : Math.round(82 * this.previewRatio()); }
  private previewHeight(): number { return this.previewRatio() >= 1.6 ? Math.round(132 / this.previewRatio()) : 82; }

  @Builder private sectionTitle(title: string, detail: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Text(detail).fontSize(11).fontColor(this.pal().text3)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder private preview() {
    Row({ space: 16 }) {
      Stack() {
        Column()
          .width(this.previewWidth()).height(this.previewHeight()).borderRadius(8)
          .backgroundColor(this.pal().surface)
          .border({ width: 1.5, color: this.accent, style: this.resolutionId === 'auto' ? BorderStyle.Dashed : BorderStyle.Solid })
        Text(this.sizeAspect()).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.accent)
      }.width(140).height(90)
      Column({ space: 6 }) {
        Text(this.sizeTitle()).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).maxLines(1)
        Text('Windows 缩放 ' + (this.activeScale() === 0 ? '自动' : this.activeScale().toString() + '%'))
          .fontSize(13).fontColor(this.pal().text2)
        Text(this.applyHint).fontSize(11).fontColor(this.pal().text3)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private tab(label: string, id: string) {
    Text(label).fontSize(13).layoutWeight(1).textAlign(TextAlign.Center).height(32)
      .fontColor(this.sizeTab === id ? '#FFFFFF' : this.pal().text2)
      .fontWeight(this.sizeTab === id ? FontWeight.Medium : FontWeight.Normal)
      .backgroundColor(this.sizeTab === id ? this.accent : Color.Transparent)
      .borderRadius(9)
      .onClick((): void => {
        this.sizeTab = id;
        if (id === 'auto') { this.onResolution('auto'); }
        if (id === 'custom') { this.onCustomChange(); }
      })
  }

  @Builder private presetChip(preset: RemoteResolutionPreset) {
    Text(preset.label).fontSize(12).maxLines(1)
      .fontColor(this.resolutionId === preset.id ? '#FFFFFF' : this.pal().text)
      .fontWeight(this.resolutionId === preset.id ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 }).margin({ right: 8, bottom: 8 })
      .backgroundColor(this.resolutionId === preset.id ? this.accent : this.pal().surface)
      .borderRadius(9)
      .onClick((): void => { this.onResolution(preset.id); })
  }

  @Builder private sizeSection() {
    Column({ space: 12 }) {
      this.sectionTitle('远端桌面大小', '远端 Windows 输出的桌面尺寸，决定画面比例和清晰度')
      Row() {
        this.tab('自适应', 'auto')
        this.tab('预设', 'preset')
        this.tab('自定义', 'custom')
      }.width('100%').padding(3).borderRadius(12).backgroundColor(this.pal().surface)
      if (this.sizeTab === 'auto') {
        Text(this.isDesktopDevice ? '跟随会话窗口大小自动协商，窗口变化时重新匹配，不产生比例黑边' :
          '每次连接时按本机屏幕计算最合适的尺寸')
          .fontSize(12).fontColor(this.pal().text2).width('100%')
      } else if (this.sizeTab === 'preset') {
        Column({ space: 4 }) {
          ForEach(this.groups, (group: RdpPresetGroup): void => {
            Column() {
              Text(group.aspect).fontSize(11).fontColor(this.pal().text3).width('100%').margin({ top: 4, bottom: 6 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(group.presets, (preset: RemoteResolutionPreset): void => { this.presetChip(preset) },
                  (preset: RemoteResolutionPreset): string => preset.id)
              }.width('100%')
            }.width('100%')
          }, (group: RdpPresetGroup): string => group.aspect)
        }.width('100%')
      } else {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            TextInput({ text: this.widthDraft, placeholder: '宽' })
              .layoutWeight(1).height(44).type(InputType.Number).maxLength(4)
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .placeholderColor(this.pal().text3).textAlign(TextAlign.Center)
              .backgroundColor(this.pal().surface).borderRadius(12)
              .onChange((value: string): void => { this.widthDraft = value; })
            Text('×').fontSize(18).fontColor(this.pal().text3)
            TextInput({ text: this.heightDraft, placeholder: '高' })
              .layoutWeight(1).height(44).type(InputType.Number).maxLength(4)
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .placeholderColor(this.pal().text3).textAlign(TextAlign.Center)
              .backgroundColor(this.pal().surface).borderRadius(12)
              .onChange((value: string): void => { this.heightDraft = value; })
          }.width('100%')
          Row() {
            Text(remoteDisplayAspectLabel(Number(this.widthDraft), Number(this.heightDraft)).length > 0 ?
              '比例 ' + remoteDisplayAspectLabel(Number(this.widthDraft), Number(this.heightDraft)) +
                ' · 200–8192，宽度为偶数' : '宽高 200–8192，宽度为偶数')
              .fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
            Button('应用尺寸').height(34).fontSize(13).padding({ left: 16, right: 16 })
              .fontColor(this.customDirty() ? '#FFFFFF' : this.pal().text3)
              .backgroundColor(this.customDirty() ? this.accent : this.pal().surface)
              .enabled(this.customDirty())
              .onClick((): void => { this.onCustomResolution(this.widthDraft, this.heightDraft); })
          }.width('100%')
        }.width('100%')
      }
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private scaleChip(label: string, percent: number) {
    Text(label).fontSize(12).maxLines(1).textAlign(TextAlign.Center)
      .fontColor(this.activeScale() === percent ? '#FFFFFF' : this.pal().text)
      .fontWeight(this.activeScale() === percent ? FontWeight.Medium : FontWeight.Normal)
      .constraintSize({ minWidth: 58 })
      .padding({ left: 10, right: 10, top: 8, bottom: 8 }).margin({ right: 8, bottom: 8 })
      .backgroundColor(this.activeScale() === percent ? this.accent : this.pal().surface)
      .borderRadius(9)
      .onClick((): void => { this.pickScale(percent); })
  }

  @Builder private scaleSection() {
    Column({ space: 12 }) {
      this.sectionTitle('Windows 界面缩放', '远端字体与控件的大小；与本地查看缩放相互独立')
      Flex({ wrap: FlexWrap.Wrap }) {
        this.scaleChip('自动', 0)
        ForEach(RDP_PRO_DESKTOP_SCALE_GRID, (percent: number): void => {
          this.scaleChip(percent.toString() + '%', percent)
        }, (percent: number): string => 'scale' + percent.toString())
      }.width('100%')
      Row({ space: 10 }) {
        Text('其他比例').fontSize(13).fontColor(this.pal().text2)
        TextInput({ text: this.scaleDraft, placeholder: this.scaleSelection() === 'custom' &&
          RDP_PRO_DESKTOP_SCALE_GRID.indexOf(this.scalePercent) < 0 ? this.scalePercent.toString() : '100–500' })
          .width(124).height(36).type(InputType.Number).maxLength(3)
          .fontSize(14).fontColor(this.pal().text).placeholderColor(this.pal().text3).textAlign(TextAlign.Center)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.scaleDraft = value; })
        Text('%').fontSize(13).fontColor(this.pal().text3)
        Blank()
        Button('应用').height(34).fontSize(13).padding({ left: 16, right: 16 })
          .fontColor(this.scaleDraftUsable() ? '#FFFFFF' : this.pal().text3)
          .backgroundColor(this.scaleDraftUsable() ? this.accent : this.pal().surface)
          .enabled(this.scaleDraftUsable())
          .onClick((): void => { this.onDesktopScalePercent(this.scaleDraft); this.scaleDraft = ''; })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          Text('远端显示方案').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          ProBadge()
        }.width('100%')
        this.preview()
        this.sizeSection()
        this.scaleSection()
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    }
    .width('100%').constraintSize({ maxHeight: this.maxPanelHeight() }).scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    .backgroundColor(this.forceDark ? this.pal().sheetBg : Color.Transparent)
  }
}
