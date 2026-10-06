import { common } from '@kit.AbilityKit';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { LengthMetrics, promptAction } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../../../common/Theme';
import { ProBadge } from '../../ProBadge';
import { AppSheetHeader } from '../../AppSheetHeader';
import { AppSettingsChoiceButton } from '../../AppSettingsChoiceButton';
import { settingsVisualIsModern } from '../../../services/SettingsVisualStylePolicy';
import { HostSyncService } from '../../../services/HostSyncService';
import { RemoteHost } from '../../../model/RemoteHost';
import { SshSkinStore, SSH_SKIN_REVISION_KEY } from '../../../services/ssh/skin/SshSkinStore';
import {
  SSH_SKIN_CUSTOM_MAX,
  SSH_SKIN_FONTS,
  SSH_SKIN_NAME_MAX,
  SshSkin,
  SshSkinChromeColors,
  SshSkinFont,
  SshSkinSettings,
  sshBuiltInSkins,
  sshSkinAutoChrome,
  sshSkinById,
  sshSkinColorValid,
  sshSkinContrast,
  sshSkinCopy,
  sshSkinFont,
  sshSkinLuminance,
  sshSkinMix
} from '../../../services/ssh/skin/SshSkinPolicy';

type SkinColorTarget = 'background' | 'foreground' | 'cursor' | 'selection' | 'palette' |
  'bar' | 'keyBar' | 'key' | 'keyText' | 'accent' | 'sheet';

interface SkinColorRow {
  target: SkinColorTarget;
  label: string;
}

const SWATCHES: string[] = [
  '#000000', '#0D0D0D', '#1E1E2E', '#282A36', '#2E3440', '#002B36', '#FDF6E3', '#FFFFFF',
  '#F8F8F2', '#D8DEE9', '#33FF33', '#50FA7B', '#A6E22E', '#8BE9FD', '#61AFEF', '#7AA2F7',
  '#BD93F9', '#C678DD', '#FF79C6', '#FF5555', '#F92672', '#FFB86C', '#F1FA8C', '#E5C07B'
];

const TERMINAL_ROWS: SkinColorRow[] = [
  { target: 'background', label: '背景' }, { target: 'foreground', label: '文字' },
  { target: 'cursor', label: '光标' }, { target: 'selection', label: '选区' }
];
const CHROME_ROWS: SkinColorRow[] = [
  { target: 'bar', label: '顶栏与标签栏' }, { target: 'keyBar', label: '功能键栏' },
  { target: 'key', label: '功能键' }, { target: 'keyText', label: '功能键文字' },
  { target: 'accent', label: '强调色' }, { target: 'sheet', label: '面板底色' }
];
const PALETTE_NAMES: string[] = ['黑', '红', '绿', '黄', '蓝', '品红', '青', '白',
  '亮黑', '亮红', '亮绿', '亮黄', '亮蓝', '亮品红', '亮青', '亮白'];

/**
 * 设置 > SSH 终端 > 终端皮肤 (Pro): Termius-style gallery with live mini-terminal cards,
 * font choice, per-host skins and a full custom skin editor.
 */
@Component
export struct SshSkinSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp(SSH_SKIN_REVISION_KEY) revision: number = 0;
  /** 设置 → 个性化 → 全新视觉: shared header and tabs, and a visible edit button on each skin. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
  @State @Watch('reportEditingDirty') editing: SshSkin | null = null;
  @State editingIsNew: boolean = false;
  /** The settings sheet shows a close button on Pad and PC, where it has no drag bar. */
  @Prop showClose: boolean = false;
  onClose: () => void = (): void => {};
  /** Tells the sheet host when the skin editor holds unsaved changes, so closing asks first. */
  onEditingDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  private editingStart: string = '';
  @State colorTarget: SkinColorTarget = 'background';
  @State paletteIndex: number = 0;
  @State hexDraft: string = '';
  @State tab: number = 0;
  // Live sheet width: 2 cards per row on phones, 3 on narrow Pad/split windows, 4 on wide windows.
  @State panelWidth: number = 360;
  private sequence: number = 0;

  aboutToAppear(): void { SshSkinStore.getInstance().load(this.context()); }
  private context(): common.Context { return getContext(this) as common.Context; }
  private columns(): number { return this.panelWidth >= 760 ? 4 : this.panelWidth >= 500 ? 3 : 2; }
  private cardWidth(): string {
    const gap: number = 10;
    const width: number = Math.max(120, (Math.min(this.panelWidth, 960) - 40 - gap * (this.columns() - 1)) / this.columns());
    return Math.floor(width).toString() + 'vp';
  }
  private previewHeight(): number { return this.columns() >= 4 ? 92 : 86; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private modern(): boolean { return settingsVisualIsModern(this.visualStyle); }
  private settings(_revision: number): SshSkinSettings { return SshSkinStore.getInstance().snapshot(); }
  private allSkins(revision: number): SshSkin[] { return sshBuiltInSkins().concat(this.settings(revision).custom); }
  private sshHosts(): RemoteHost[] {
    return HostSyncService.getInstance().getAllHosts().filter((host: RemoteHost): boolean => host.protocol === 'ssh');
  }

  // ---------- actions ----------
  private apply(skin: SshSkin): void {
    SshSkinStore.getInstance().setGlobalSkin(this.context(), skin.id);
  }
  private newId(): string { return 'custom-' + Date.now().toString(36) + '-' + (++this.sequence).toString(); }
  private reportEditingDirty(): void {
    this.onEditingDirtyChange(this.editing !== null && JSON.stringify(this.editing) !== this.editingStart);
  }
  private beginCopy(skin: SshSkin): void {
    if (this.settings(this.revision).custom.length >= SSH_SKIN_CUSTOM_MAX) {
      promptAction.showToast({ message: '最多保存 ' + SSH_SKIN_CUSTOM_MAX.toString() + ' 个自定义皮肤', duration: 2000 });
      return;
    }
    const name: string = (skin.builtIn ? skin.name : skin.name + ' 副本').slice(0, SSH_SKIN_NAME_MAX);
    const copy: SshSkin = sshSkinCopy(skin, this.newId(), skin.builtIn ? name + ' · 自定义' : name);
    this.editingStart = JSON.stringify(copy);
    this.editing = copy;
    this.editingIsNew = true;
    this.colorTarget = 'background';
    this.hexDraft = copy.terminal.background;
  }
  private beginEdit(skin: SshSkin): void {
    const copy: SshSkin = sshSkinCopy(skin, skin.id, skin.name);
    this.editingStart = JSON.stringify(copy);
    this.editing = copy;
    this.editingIsNew = false;
    this.colorTarget = 'background';
    this.hexDraft = copy.terminal.background;
  }
  private saveEditing(): void {
    const skin: SshSkin | null = this.editing;
    if (skin === null) { return; }
    if (!SshSkinStore.getInstance().saveCustom(this.context(), skin)) {
      promptAction.showToast({ message: '皮肤保存失败，请检查颜色和名称', duration: 2000 });
      return;
    }
    SshSkinStore.getInstance().setGlobalSkin(this.context(), skin.id);
    this.editing = null;
  }
  private deleteCustom(skin: SshSkin): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除皮肤', message: '删除「' + skin.name + '」？使用它的主机会恢复为全局皮肤。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1) { SshSkinStore.getInstance().deleteCustom(this.context(), skin.id); }
    }).catch((): void => {});
  }
  /** The system action menu takes one to six buttons as a tuple. */
  private menuButtons(labels: string[]): [promptAction.Button, promptAction.Button?, promptAction.Button?,
    promptAction.Button?, promptAction.Button?, promptAction.Button?] {
    const b: promptAction.Button[] = labels.slice(0, 6)
      .map((text: string): promptAction.Button => ({ text: text, color: this.pal().text }));
    if (b.length >= 6) { return [b[0], b[1], b[2], b[3], b[4], b[5]]; }
    if (b.length === 5) { return [b[0], b[1], b[2], b[3], b[4]]; }
    if (b.length === 4) { return [b[0], b[1], b[2], b[3]]; }
    if (b.length === 3) { return [b[0], b[1], b[2]]; }
    if (b.length === 2) { return [b[0], b[1]]; }
    return [b.length > 0 ? b[0] : { text: '取消', color: this.pal().text2 }];
  }

  private skinMenu(skin: SshSkin): void {
    const buttons: string[] = skin.builtIn ? ['复制为自定义皮肤'] : ['编辑', '复制', '删除'];
    this.getUIContext().getPromptAction().showActionMenu({
      title: skin.name,
      buttons: this.menuButtons(buttons)
    }).then((result): void => {
      const choice: string = buttons[result.index] ?? '';
      if (choice === '编辑') { this.beginEdit(skin); }
      else if (choice === '删除') { this.deleteCustom(skin); }
      else { this.beginCopy(skin); }
    }).catch((): void => {});
  }

  // ---------- editor color handling ----------
  private currentColor(): string {
    const skin: SshSkin | null = this.editing;
    if (skin === null) { return '#000000'; }
    const t: SkinColorTarget = this.colorTarget;
    if (t === 'background') { return skin.terminal.background; }
    if (t === 'foreground') { return skin.terminal.foreground; }
    if (t === 'cursor') { return skin.terminal.cursor; }
    if (t === 'selection') { return skin.terminal.selection; }
    if (t === 'palette') { return skin.terminal.palette[this.paletteIndex]; }
    return this.chromePreview(skin, t);
  }
  private setColor(color: string): void {
    const skin: SshSkin | null = this.editing;
    if (skin === null || !sshSkinColorValid(color)) { return; }
    const next: SshSkin = sshSkinCopy(skin, skin.id, skin.name);
    const hex: string = color.toUpperCase();
    const t: SkinColorTarget = this.colorTarget;
    if (t === 'background') { next.terminal.background = hex; }
    else if (t === 'foreground') { next.terminal.foreground = hex; }
    else if (t === 'cursor') { next.terminal.cursor = hex; }
    else if (t === 'selection') { next.terminal.selection = hex; }
    else if (t === 'palette') { next.terminal.palette[this.paletteIndex] = hex; }
    else if (t === 'bar') { next.chrome.bar = hex; }
    else if (t === 'keyBar') { next.chrome.keyBar = hex; }
    else if (t === 'key') { next.chrome.key = hex; }
    else if (t === 'keyText') { next.chrome.keyText = hex; }
    else if (t === 'accent') { next.chrome.accent = hex; }
    else if (t === 'sheet') { next.chrome.sheet = hex; }
    next.dark = sshSkinLuminance(next.terminal.background) < 0.5;
    this.editing = next;
    this.hexDraft = hex;
  }
  private adjust(amount: number): void {
    this.setColor(sshSkinMix(this.currentColor(), amount > 0 ? '#FFFFFF' : '#000000', Math.abs(amount)));
  }
  private autoChrome(): void {
    const skin: SshSkin | null = this.editing;
    if (skin === null) { return; }
    const next: SshSkin = sshSkinCopy(skin, skin.id, skin.name);
    const chrome: SshSkinChromeColors = sshSkinAutoChrome(next.terminal, next.chrome.accent);
    next.chrome = chrome;
    this.editing = next;
  }
  private selectTarget(target: SkinColorTarget, paletteIndex: number = 0): void {
    this.colorTarget = target;
    this.paletteIndex = paletteIndex;
    this.hexDraft = this.currentColor();
  }
  private setName(name: string): void {
    const skin: SshSkin | null = this.editing;
    if (skin === null) { return; }
    const next: SshSkin = sshSkinCopy(skin, skin.id, name);
    this.editing = next;
  }
  private setFont(fontId: string): void {
    const skin: SshSkin | null = this.editing;
    if (skin === null) { return; }
    const next: SshSkin = sshSkinCopy(skin, skin.id, skin.name);
    next.fontId = sshSkinFont(fontId).id;
    this.editing = next;
  }

  // ---------- shared previews ----------
  @Builder private miniTerminal(skin: SshSkin, height: number) {
    Column({ space: 0 }) {
      Row({ space: 4 }) {
        Circle().width(6).height(6).fill('#FF5F57')
        Circle().width(6).height(6).fill('#FEBC2E')
        Circle().width(6).height(6).fill('#28C840')
        Blank()
        Text('ssh').fontSize(8).fontColor(skin.chrome.barTextDim)
      }.width('100%').height(16).padding({ left: 7, right: 7 }).backgroundColor(skin.chrome.bar)
      Column({ space: 1 }) {
        Row() {
          Text('user@host').fontSize(9).fontColor(skin.terminal.palette[2]).fontFamily('monospace')
          Text(':').fontSize(9).fontColor(skin.terminal.foreground).fontFamily('monospace')
          Text('~/app').fontSize(9).fontColor(skin.terminal.palette[4]).fontFamily('monospace')
          Text('$ ls').fontSize(9).fontColor(skin.terminal.foreground).fontFamily('monospace')
        }
        Row({ space: 6 }) {
          Text('src').fontSize(9).fontColor(skin.terminal.palette[12]).fontFamily('monospace')
          Text('run.sh').fontSize(9).fontColor(skin.terminal.palette[10]).fontFamily('monospace')
          Text('err.log').fontSize(9).fontColor(skin.terminal.palette[9]).fontFamily('monospace')
        }
        Row() {
          Text('$ ').fontSize(9).fontColor(skin.terminal.foreground).fontFamily('monospace')
          Column().width(5).height(10).backgroundColor(skin.terminal.cursor)
        }
      }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 7, top: 4 })
      Row({ space: 3 }) {
        ForEach(['Esc', 'Ctrl', 'Tab', '↑'], (key: string): void => {
          Text(key).fontSize(7).fontColor(skin.chrome.keyText).padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(skin.chrome.key).borderRadius(3)
        }, (key: string): string => key)
      }.width('100%').height(15).padding({ left: 6 }).backgroundColor(skin.chrome.keyBar)
    }.width('100%').height(height).backgroundColor(skin.terminal.background).borderRadius(10).clip(true)
  }

  @Builder private skinCard(skin: SshSkin, selected: boolean) {
    Column({ space: 6 }) {
      this.miniTerminal(skin, this.previewHeight())
      Row({ space: 4 }) {
        Column({ space: 1 }) {
          Text(skin.name).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(sshSkinFont(skin.fontId).label).fontSize(this.modern() ? 12 : 10)
            .fontColor(this.modern() ? this.pal().text2 : this.pal().text3).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([this.accent])
        }
        if (this.modern()) {
          // The long-press menu, reachable with a tap or a mouse click.
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.pal().text2])
            .width(32).height(32).accessibilityText(skin.builtIn ? '复制' + skin.name : '编辑' + skin.name)
            .onClick((): void => { this.skinMenu(skin); })
        }
      }.width('100%').padding({ left: 2, right: 2 })
    }
    .padding(6).borderRadius(14).backgroundColor(this.pal().card)
    .border({ width: selected ? 2 : 0.5, color: selected ? this.accent : this.pal().cardBorder })
    .onClick((): void => { this.apply(skin); })
    .gesture(LongPressGesture({ duration: 450 }).onAction((): void => { this.skinMenu(skin); }))
    .accessibilityText(skin.name + (selected ? '，当前皮肤' : ''))
  }

  @Builder private sectionTitle(title: string, detail: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
      if (detail.length > 0) {
        Text(detail).fontSize(this.modern() ? 12 : 11).fontColor(this.modern() ? this.pal().text2 : this.pal().text3)
          .fontFamily(AppConfig.fontFamily).lineHeight(16)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 6 })
  }

  // ---------- gallery ----------
  @Builder private gallery() {
    Column({ space: 12 }) {
      if (this.modern()) {
        AppSheetHeader({ title: '终端皮肤', subtitle: '字体、配色、功能键栏和顶栏成套切换；点皮肤上的铅笔可复制或编辑',
          showProBadge: true, horizontalPadding: 0, whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('使用终端皮肤').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text('关闭后终端恢复默认外观').fontSize(12).fontColor(this.pal().text2)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings(this.revision).globalSkinId.length > 0 })
            .selectedColor(this.accent).accessibilityText('使用终端皮肤')
            .onChange((on: boolean): void => {
              SshSkinStore.getInstance().setGlobalSkin(this.context(), on ? 'default-dark' : '');
            })
        }.width('100%').constraintSize({ minHeight: 56 })
        Row({ space: 8 }) {
          ForEach(['皮肤', '字体', '按主机'], (label: string, index: number): void => {
            AppSettingsChoiceButton({ label: label, isSelected: this.tab === index, whiteOnAccent: true,
              onSelect: (): void => { this.tab = index; } })
          }, (label: string): string => label)
        }.width('100%')
      } else {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text('终端皮肤').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(AppConfig.fontFamily)
            ProBadge()
          }
          Text('字体、配色、功能键栏和顶栏成套切换；长按皮肤可复制或编辑').fontSize(11).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.settings(this.revision).globalSkinId.length > 0 })
          .selectedColor(this.accent)
          .onChange((on: boolean): void => {
            SshSkinStore.getInstance().setGlobalSkin(this.context(), on ? 'default-dark' : '');
          })
        if (this.showClose) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
            .width(36).height(36).accessibilityText('关闭')
            .onClick((): void => { this.onClose(); })
        }
      }.width('100%')
      Row({ space: 8 }) {
        ForEach(['皮肤', '字体', '按主机'], (label: string, index: number): void => {
          Text(label).fontSize(13).fontColor(this.tab === index ? appUiOnAccentText(this.accent) : this.pal().text2)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 }).borderRadius(16)
            .backgroundColor(this.tab === index ? this.accent : this.pal().card)
            .onClick((): void => { this.tab = index; })
        }, (label: string): string => label)
      }.width('100%')
      }
      if (this.tab === 0) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
          ForEach(this.allSkins(this.revision), (skin: SshSkin): void => {
            Column() { this.skinCard(skin, this.settings(this.revision).globalSkinId === skin.id) }
              .width(this.cardWidth())
          }, (skin: SshSkin): string => skin.id + ':' + this.revision.toString())
          Column({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(24).fontColor([this.accent])
            Text('新建皮肤').fontSize(12).fontColor(this.accent)
            Text('从当前皮肤复制').fontSize(10).fontColor(this.pal().text3)
          }.width(this.cardWidth()).height(this.previewHeight() + 42).justifyContent(FlexAlign.Center).borderRadius(14)
          .border({ width: 1, color: this.accent, style: BorderStyle.Dashed })
          .onClick((): void => {
            const current: SshSkin | null = sshSkinById(this.settings(this.revision),
              this.settings(this.revision).globalSkinId);
            this.beginCopy(current !== null ? current : sshBuiltInSkins()[0]);
          })
        }.width('100%')
      } else if (this.tab === 1) {
        this.fontList()
      } else {
        this.hostList()
      }
    }.width('100%')
  }

  @Builder private fontRow(font: SshSkinFont | null, selected: boolean) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(font === null ? '跟随皮肤' : font.label).fontSize(14).fontColor(this.pal().text)
        Text(font === null ? '使用每款皮肤推荐的字体' :
          (font.bundled ? '随应用内置 · SIL OFL 1.1' : '系统自带')).fontSize(10).fontColor(this.pal().text3)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (selected) { SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accent]) }
    }.width('100%').padding(14)
    .onClick((): void => { SshSkinStore.getInstance().setFont(this.context(), font === null ? '' : font.id); })
  }

  @Builder private fontList() {
    Column() {
      this.fontRow(null, this.settings(this.revision).fontId.length === 0)
      ForEach(SSH_SKIN_FONTS, (font: SshSkinFont): void => {
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 14, right: 14 })
        this.fontRow(font, this.settings(this.revision).fontId === font.id)
      }, (font: SshSkinFont): string => font.id + ':' + this.revision.toString())
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    Text('内置字体只包含拉丁字符，中文自动使用系统字体。终端字号和行距在「SSH 终端」设置中调整。')
      .fontSize(11).fontColor(this.pal().text3).lineHeight(16).width('100%')
  }

  private hostSkinLabel(hostId: string, revision: number): string {
    const id: string = this.settings(revision).hostSkins[hostId] ?? '';
    const skin: SshSkin | null = id.length > 0 ? sshSkinById(this.settings(revision), id) : null;
    return skin === null ? '跟随全局' : skin.name;
  }

  private pickHostSkin(host: RemoteHost): void {
    const skins: SshSkin[] = this.allSkins(this.revision);
    const labels: string[] = ['跟随全局'].concat(skins.map((skin: SshSkin): string => skin.name)).slice(0, 6);
    // The system action menu shows up to six entries; the full list is reachable by setting a global skin.
    this.getUIContext().getPromptAction().showActionMenu({
      title: host.label.length > 0 ? host.label : host.host,
      buttons: this.menuButtons(labels)
    }).then((result): void => {
      const skinId: string = result.index === 0 ? '' : (skins[result.index - 1]?.id ?? '');
      SshSkinStore.getInstance().setHostSkin(this.context(), host.id, skinId);
    }).catch((): void => {});
  }

  @Builder private hostList() {
    if (this.sshHosts().length === 0) {
      Text('还没有 SSH 主机').fontSize(12).fontColor(this.pal().text3).width('100%').padding(16)
    } else {
      Column() {
        ForEach(this.sshHosts(), (host: RemoteHost, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 14, right: 14 }) }
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(host.label.length > 0 ? host.label : host.host).fontSize(14).fontColor(this.pal().text).maxLines(1)
              Text(host.username + '@' + host.host).fontSize(10).fontColor(this.pal().text3).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text(this.hostSkinLabel(host.id, this.revision)).fontSize(12).fontColor(this.accent)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
          }.width('100%').padding(14).onClick((): void => { this.pickHostSkin(host); })
        }, (host: RemoteHost): string => host.id + ':' + this.revision.toString())
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      Text('例如给生产环境指定醒目的皮肤。长按「皮肤」页中的皮肤可复制或编辑；主机菜单最多列出前五款皮肤。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(16).width('100%')
    }
  }

  // ---------- editor ----------
  @Builder private colorChip(target: SkinColorTarget, label: string, color: string, paletteIndex: number) {
    Column({ space: 3 }) {
      Column().width(28).height(28).borderRadius(8).backgroundColor(color)
        .border({ width: this.colorTarget === target && (target !== 'palette' || this.paletteIndex === paletteIndex) ? 2.5 : 1,
          color: this.colorTarget === target && (target !== 'palette' || this.paletteIndex === paletteIndex) ?
            this.accent : this.pal().cardBorder })
      Text(label).fontSize(9).fontColor(this.pal().text2).maxLines(1)
    }.width(52).onClick((): void => { this.selectTarget(target, paletteIndex); })
  }

  @Builder private editor(skin: SshSkin) {
    Column({ space: 12 }) {
      Row() {
        Button('取消').fontSize(13).fontColor(this.pal().text2).backgroundColor(Color.Transparent)
          .onClick((): void => { this.editing = null; })
        Text(this.editingIsNew ? '新建皮肤' : '编辑皮肤').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).layoutWeight(1).textAlign(TextAlign.Center)
        Button('保存').fontSize(13).fontColor(appUiOnAccentText(this.accent)).backgroundColor(this.accent).height(32)
          .onClick((): void => { this.saveEditing(); })
      }.width('100%')
      if (this.columns() >= 4) {
        Row({ space: 20 }) {
          Column({ space: 12 }) { this.editorPreview(skin) }.width('38%')
          Column({ space: 12 }) { this.editorControls(skin) }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
      } else {
        this.editorPreview(skin)
        this.editorControls(skin)
      }
    }.width('100%')
  }

  @Builder private editorPreview(skin: SshSkin) {
      this.miniTerminal(skin, 150)
      if (sshSkinContrast(skin.terminal.foreground, skin.terminal.background) < 3) {
        Text('文字与背景对比度偏低（' + sshSkinContrast(skin.terminal.foreground, skin.terminal.background).toFixed(1) +
          ':1），可能不易阅读').fontSize(11).fontColor('#B26A00').width('100%')
      }
      TextInput({ text: skin.name, placeholder: '皮肤名称' }).height(40).maxLength(SSH_SKIN_NAME_MAX)
        .backgroundColor(this.pal().card).borderRadius(10)
        .onChange((value: string): void => { this.setName(value); })

  }

  @Builder private editorControls(skin: SshSkin) {
      this.sectionTitle('终端', '点选要修改的颜色，再从下方色板选择或输入色值')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(TERMINAL_ROWS, (row: SkinColorRow): void => {
          this.colorChip(row.target, row.label,
            row.target === 'background' ? skin.terminal.background : row.target === 'foreground' ?
              skin.terminal.foreground : row.target === 'cursor' ? skin.terminal.cursor : skin.terminal.selection, 0)
        }, (row: SkinColorRow): string => row.target)
      }.width('100%')
      Text('16 色调色板').fontSize(11).fontColor(this.pal().text2).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(PALETTE_NAMES, (name: string, index: number): void => {
          this.colorChip('palette', name, skin.terminal.palette[index], index)
        }, (name: string, index: number): string => index.toString())
      }.width('100%')

      this.sectionTitle('界面', '顶栏、功能键栏与面板')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(CHROME_ROWS, (row: SkinColorRow): void => {
          this.colorChip(row.target, row.label, this.chromePreview(skin, row.target), 0)
        }, (row: SkinColorRow): string => row.target)
      }.width('100%')
      Button('根据终端配色自动搭配界面').width('100%').height(36).fontSize(12)
        .fontColor(this.accent).backgroundColor(this.pal().card)
        .onClick((): void => { this.autoChrome(); })

      this.sectionTitle('调色 · 当前：' + this.targetLabel(), '')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(SWATCHES, (color: string): void => {
          Column().width(28).height(28).borderRadius(14).backgroundColor(color)
            .border({ width: this.currentColor() === color ? 2.5 : 1,
              color: this.currentColor() === color ? this.accent : this.pal().cardBorder })
            .onClick((): void => { this.setColor(color); })
        }, (color: string): string => color)
      }.width('100%')
      Row({ space: 8 }) {
        Button('更暗').fontSize(12).height(34).layoutWeight(1).fontColor(this.pal().text)
          .backgroundColor(this.pal().card).onClick((): void => { this.adjust(-0.12); })
        Button('更亮').fontSize(12).height(34).layoutWeight(1).fontColor(this.pal().text)
          .backgroundColor(this.pal().card).onClick((): void => { this.adjust(0.12); })
        TextInput({ text: this.hexDraft, placeholder: '#RRGGBB' }).height(34).layoutWeight(1.4).fontSize(12)
          .maxLength(7).backgroundColor(this.pal().card).borderRadius(8)
          .onChange((value: string): void => {
            this.hexDraft = value;
            if (sshSkinColorValid(value)) { this.setColor(value); }
          })
      }.width('100%')

      this.sectionTitle('字体', '')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(SSH_SKIN_FONTS, (font: SshSkinFont): void => {
          Text(font.label).fontSize(12).fontColor(skin.fontId === font.id ? appUiOnAccentText(this.accent) : this.pal().text2)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(16)
            .backgroundColor(skin.fontId === font.id ? this.accent : this.pal().card)
            .onClick((): void => { this.setFont(font.id); })
        }, (font: SshSkinFont): string => font.id)
      }.width('100%')
  }

  /** Chrome colors may carry alpha (#AARRGGBB); the editor shows and edits the opaque color. */
  private chromePreview(skin: SshSkin, target: SkinColorTarget): string {
    const c: SshSkinChromeColors = skin.chrome;
    const value: string = target === 'bar' ? c.bar : target === 'keyBar' ? c.keyBar : target === 'key' ? c.key :
      target === 'keyText' ? c.keyText : target === 'accent' ? c.accent : target === 'sheet' ? c.sheet : '#000000';
    return value.length === 9 ? '#' + value.substring(3) : value;
  }

  private targetLabel(): string {
    if (this.colorTarget === 'palette') { return PALETTE_NAMES[this.paletteIndex]; }
    const row: SkinColorRow | undefined = TERMINAL_ROWS.concat(CHROME_ROWS)
      .find((item: SkinColorRow): boolean => item.target === this.colorTarget);
    return row !== undefined ? row.label : '';
  }

  build() {
    Scroll() {
      Column() {
        if (this.editing !== null) {
          this.editor(this.editing as SshSkin)
        } else {
          this.gallery()
        }
      }.width('100%').constraintSize({ maxWidth: 960 }).padding({ left: 20, right: 20, top: 20, bottom: 32 })
    }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .onAreaChange((_old: Area, next: Area): void => {
      const width: number = Number(next.width);
      if (Number.isFinite(width) && width > 0 && Math.abs(width - this.panelWidth) >= 1) { this.panelWidth = width; }
    })
  }
}
