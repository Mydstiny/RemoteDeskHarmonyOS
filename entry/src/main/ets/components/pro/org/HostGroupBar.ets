import { display } from '@kit.ArkUI';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProSymbolIcon } from '../ProSymbolIcon';
import {
  HostFilter, HostGroupDefinition, hostMatchesFilter, parseHostFilterKey
} from '../../../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../../../services/pro/org/HostOrganizationStore';
import { hostFilterLabel, orgHostView, OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import {
  HOST_SMART_FILTER_REVISION_KEY, HostSmartFilterPreferences
} from '../../../services/pro/org/HostSmartFilterPreferences';
import { HostOrganizationManager } from './HostOrganizationManager';

/** Sheet content scrolls beyond 85% of the screen minus the title row. */
function sheetBodyMaxHeight(): number {
  try {
    const screen: display.Display = display.getDefaultDisplaySync();
    return Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.85) - 70;
  } catch (_error) {
    return 560;
  }
}

/**
 * Home-page chip bar for Pro 高级主机管理: 全部, the chosen smart chips and every user group with live counts.
 * Long-press a chip or tap the gear to manage groups, tags and smart chips.
 */
@Component
export struct HostGroupBar {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp(HOST_SMART_FILTER_REVISION_KEY) smartRevision: number = 0;
  @Prop rows: OrgHostRow[] = [];
  @Prop onlineRefs: string[] = [];
  @Prop offlineRefs: string[] = [];
  @Prop filterKey: string = 'all';
  @Prop compact: boolean = false;
  onFilter: (key: string) => void = (_key: string): void => {};
  onExport: () => void = (): void => {};
  onImport: () => void = (): void => {};
  onSelectHosts: (refs: string[]) => void = (_refs: string[]): void => {};
  @State revision: number = 0;
  @State showManager: boolean = false;
  @State managerTab: string = 'groups';
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    HostSmartFilterPreferences.getInstance().load(getContext(this));
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private groups(_revision: number): HostGroupDefinition[] { return HostOrganizationStore.getInstance().listGroups(); }
  private smartKeys(_revision: number): string[] { return HostSmartFilterPreferences.getInstance().list(); }
  private online(ref: string): boolean | undefined {
    if (this.onlineRefs.indexOf(ref) >= 0) { return true; }
    if (this.offlineRefs.indexOf(ref) >= 0) { return false; }
    return undefined;
  }
  private count(key: string, _revision: number): number {
    const filter: HostFilter = parseHostFilterKey(key);
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    const now: number = Date.now();
    return this.rows.filter((row: OrgHostRow): boolean =>
      hostMatchesFilter(orgHostView(row, this.online(row.ref)), store.membership(row.ref), filter, now)).length;
  }
  private select(key: string): void { this.onFilter(this.filterKey === key && key !== 'all' ? 'all' : key); }
  private openManager(tab: string): void { this.managerTab = tab; this.showManager = true; }

  @Builder private chip(key: string, label: string, icon: string, color: string) {
    Row({ space: 5 }) {
      if (icon.length > 0) {
        ProSymbolIcon({ icon: icon, glyphSize: 13, color: color.length > 0 ? color : this.accent })
      } else if (color.length > 0) {
        Circle().width(8).height(8).fill(color)
      }
      Text(label).fontSize(13).fontFamily(AppConfig.fontFamily).maxLines(1)
        .constraintSize({ maxWidth: 120 }).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.filterKey === key ? (color.length > 0 ? color : this.accent) : this.pal().text2)
        .fontWeight(this.filterKey === key ? FontWeight.Medium : FontWeight.Normal)
      Text(this.count(key, this.revision + this.smartRevision).toString()).fontSize(11)
        .fontColor(this.filterKey === key ? (color.length > 0 ? color : this.accent) : this.pal().text3)
    }
    .height(32).padding({ left: 12, right: 12 }).borderRadius(16).margin({ right: 8 })
    .backgroundColor(this.filterKey === key ? this.tint(color.length > 0 ? color : this.accent, '1F') : this.pal().surface)
    .border({ width: 1, color: this.filterKey === key ? (color.length > 0 ? color : this.accent) : Color.Transparent })
    .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    .onClick((): void => { this.select(key); })
    .gesture(LongPressGesture().onAction((): void => {
      this.openManager(key.startsWith('group:') ? 'groups' : key.startsWith('tag:') ? 'tags' : 'smart');
    }))
  }

  @Builder private managerSheet() {
    Column() {
      Row() {
        Text('高级主机管理').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
        Text('完成').fontSize(15).fontColor(this.accent).padding(6).onClick((): void => { this.showManager = false; })
      }.width('100%').padding({ left: 20, right: 16, top: 18, bottom: 10 })
      Scroll() {
        Column() {
          HostOrganizationManager({
            extraRows: this.rows.filter((row: OrgHostRow): boolean => row.protocol === 'moonlight'),
            homeActions: true,
            initialTab: this.managerTab,
            onExport: (): void => { this.showManager = false; this.onExport(); },
            onImport: (): void => { this.showManager = false; this.onImport(); },
            onSelectHosts: (refs: string[]): void => { this.showManager = false; this.onSelectHosts(refs); }
          })
        }.padding({ left: 16, right: 16, bottom: 28 })
      }.constraintSize({ maxHeight: sheetBodyMaxHeight() }).scrollBar(BarState.Off).align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }

  build() {
    Row() {
      Scroll() {
        Row() {
          this.chip('all', '全部', '', '')
          ForEach(this.smartKeys(this.smartRevision), (key: string): void => {
            this.chip(key, hostFilterLabel(key), '', '')
          }, (key: string): string => key + ':' + this.smartRevision.toString())
          ForEach(this.groups(this.revision), (group: HostGroupDefinition): void => {
            this.chip('group:' + group.id, group.name, group.icon, group.color)
          }, (group: HostGroupDefinition): string => group.id + ':' + group.updatedAt.toString() + ':' +
            group.order.toString())
          Row() {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(15).fontColor([this.accent])
          }.width(32).height(32).borderRadius(16).justifyContent(FlexAlign.Center)
          .backgroundColor(this.pal().surface).margin({ right: 8 })
          .accessibilityText('新建分组')
          .onClick((): void => { this.openManager('groups'); })
        }.padding({ left: 16, right: 8 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).layoutWeight(1)
      Row() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(16).fontColor([this.pal().text2])
      }.width(36).height(32).justifyContent(FlexAlign.Center).margin({ right: 12 })
      .accessibilityText('管理分组与标签')
      .onClick((): void => { this.openManager('groups'); })
    }
    .width('100%').padding({ top: 2, bottom: 6 })
    .bindSheet($$this.showManager, this.managerSheet(), {
      height: SheetSize.FIT_CONTENT, dragBar: true, showClose: false, backgroundColor: this.pal().sheetBg,
      onWillDismiss: (action: DismissSheetAction): void => { action.dismiss(); }
    })
  }
}
