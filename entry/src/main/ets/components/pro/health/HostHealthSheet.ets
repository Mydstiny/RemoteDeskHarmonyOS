import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { Palette, buildDark, buildLight } from '../../../common/Theme';
import { HostHealthStore } from '../../../services/pro/health/HostHealthStore';
import {
  HostHealthAction,
  HostHealthObservation,
  HostHealthStatus,
  HostHealthVerdict,
  hostHealthAction,
  hostHealthAgeLabel,
  hostHealthCodeDetail,
  hostHealthStatusLabel,
  isHostHealthStale
} from '../../../services/pro/health/HostHealthPolicy';

/** One host as the sheet lists it. */
export interface HostHealthRow {
  id: string;
  label: string;
  protocol: string;
}

interface HostHealthGroup {
  status: HostHealthStatus | 'never';
  rows: HostHealthRow[];
}

const STATUS_ORDER: Array<HostHealthStatus | 'never'> = ['trust_required', 'route_unavailable', 'timeout',
  'remote_rejected', 'peer_offline', 'unknown', 'capability_unsupported', 'never', 'reachable'];

/** The label of the button that does a suggested action. */
export function hostHealthActionLabel(action: HostHealthAction): string {
  switch (action) {
    case 'confirm_certificate': return '连接并确认证书';
    case 'review_fingerprint': return '连接并查看指纹';
    case 'edit_host': return '修改主机';
    case 'check_relay': return '查看中继';
    case 'pair_moonlight': return '去配对';
    case 'check_network': return '重新检测';
    case 'retry': return '重新检测';
    default: return '';
  }
}

/**
 * 主机健康中心: one host (its state in plain words, why, what to do, its last 20 checks) or, after a batch check,
 * every checked host grouped by reason. Reads HostHealthStore; `revision` re-renders it when a check lands.
 */
@Component
export struct HostHealthSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop hosts: HostHealthRow[] = [];
  /** '' lists every host in `hosts` grouped by reason; a host id shows that host. */
  @Prop @Watch('onFocusChange') focusHostId: string = '';
  @Prop revision: number = 0;
  @Prop checkingIds: string[] = [];
  @Prop batchChecking: boolean = false;
  @State private shownHostId: string = '';
  onCheck: (hostId: string) => void = (_hostId: string): void => {};
  onCheckAll: () => void = (): void => {};
  onAction: (hostId: string, action: HostHealthAction) => void = (_h: string, _a: HostHealthAction): void => {};
  onClose: () => void = (): void => {};

  aboutToAppear(): void { this.shownHostId = this.focusHostId; }

  private onFocusChange(): void { this.shownHostId = this.focusHostId; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  private history(hostId: string, _revision: number): HostHealthObservation[] {
    return HostHealthStore.getInstance().history(hostId);
  }

  private latest(hostId: string, revision: number): HostHealthObservation | null {
    const rows: HostHealthObservation[] = this.history(hostId, revision);
    return rows.length > 0 ? rows[0] : null;
  }

  private statusColor(status: HostHealthStatus | 'never'): string {
    if (status === 'reachable') { return '#34C759'; }
    if (status === 'trust_required') { return '#FF9F0A'; }
    if (status === 'never' || status === 'capability_unsupported' || status === 'unknown') { return this.pal().text3; }
    return this.pal().danger;
  }

  private routeText(o: HostHealthObservation): string {
    const parts: string[] = [];
    if (o.route === 'gateway') { parts.push('经 RD 网关'); }
    else if (o.route === 'relay') { parts.push('经中继'); }
    else if (o.route === 'proxy') { parts.push('经代理'); }
    else if (o.route === 'direct') { parts.push('直连'); }
    if (o.addressFamily === 'ipv4') { parts.push('IPv4'); }
    if (o.addressFamily === 'ipv6') { parts.push('IPv6'); }
    if (o.latencyMs >= 0) { parts.push(o.latencyMs.toString() + ' ms'); }
    return parts.join(' · ');
  }

  /** The suggested action other than checking again (that is the other button). */
  private primaryAction(hostId: string, revision: number): HostHealthAction {
    const latest: HostHealthObservation | null = this.latest(hostId, revision);
    if (latest === null) { return 'none'; }
    const verdict: HostHealthVerdict = { status: latest.status, code: latest.code };
    const action: HostHealthAction = hostHealthAction(verdict, this.row(hostId)?.protocol ?? '');
    return action === 'retry' || action === 'check_network' ? 'none' : action;
  }

  private primaryActionLabel(hostId: string, revision: number): string {
    return hostHealthActionLabel(this.primaryAction(hostId, revision));
  }

  private row(hostId: string): HostHealthRow | null {
    const found: HostHealthRow | undefined = this.hosts.find((item: HostHealthRow): boolean => item.id === hostId);
    return found === undefined ? null : found;
  }

  private groups(revision: number): HostHealthGroup[] {
    const byStatus: Map<string, HostHealthRow[]> = new Map<string, HostHealthRow[]>();
    for (const host of this.hosts) {
      const latest: HostHealthObservation | null = this.latest(host.id, revision);
      const key: string = latest === null ? 'never' : latest.status;
      const list: HostHealthRow[] = byStatus.get(key) ?? [];
      list.push(host);
      byStatus.set(key, list);
    }
    const result: HostHealthGroup[] = [];
    for (const status of STATUS_ORDER) {
      const rows: HostHealthRow[] | undefined = byStatus.get(status);
      if (rows !== undefined && rows.length > 0) { result.push({ status, rows }); }
    }
    return result;
  }

  @Builder private header(title: string, subtitle: string, back: boolean) {
    Row({ space: 10 }) {
      if (back) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text]) }
          .width(36).height(36).padding(0).backgroundColor(this.pal().surface)
          .onClick((): void => { this.shownHostId = ''; })
          .accessibilityText('返回全部主机')
      }
      Column({ space: 2 }) {
        Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(12).fontColor(this.pal().text3).maxLines(1)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2]) }
        .width(36).height(36).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onClose(); })
        .accessibilityText('关闭')
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
  }

  /** A capsule button: the primary one in the theme colour. */
  private pillColor(primary: boolean): string { return primary ? this.accentColor : this.pal().surface; }

  private pillText(primary: boolean): string { return primary ? appUiOnAccentText(this.accentColor) : this.pal().text; }

  @Builder private historyBars(rows: HostHealthObservation[]) {
    Row({ space: 3 }) {
      ForEach(rows.slice().reverse(), (o: HostHealthObservation): void => {
        Column()
          .width(8)
          .height(o.status === 'reachable' && o.latencyMs >= 0 ?
            Math.max(6, Math.min(48, 6 + o.latencyMs / 10)) : 10)
          .borderRadius(3)
          .backgroundColor(this.statusColor(o.status))
      }, (o: HostHealthObservation): string => o.observedAt.toString())
    }.height(52).alignItems(VerticalAlign.Bottom)
  }

  @Builder private singleView(hostId: string, revision: number) {
    Column() {
      this.header(this.row(hostId)?.label ?? '主机', (this.row(hostId)?.protocol ?? '').toUpperCase() + ' · 健康状况',
        this.focusHostId.length === 0)
      Scroll() {
        Column({ space: 14 }) {
          if (this.latest(hostId, revision) === null) {
            Text(this.checkingIds.indexOf(hostId) >= 0 ? '正在检测…' : '还没有检测过这台主机')
              .fontSize(15).fontColor(this.pal().text2).width('100%')
          } else {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Column().width(10).height(10).borderRadius(5)
                  .backgroundColor(this.statusColor(this.latest(hostId, revision)!.status))
                Text(hostHealthStatusLabel(this.latest(hostId, revision)!.status))
                  .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                Blank()
                Text(isHostHealthStale(this.latest(hostId, revision)!.observedAt, Date.now()) ? '待刷新' :
                  hostHealthAgeLabel(this.latest(hostId, revision)!.observedAt, Date.now()))
                  .fontSize(12).fontColor(this.pal().text3)
              }.width('100%')
              if (hostHealthCodeDetail(this.latest(hostId, revision)!.code).length > 0) {
                Text(hostHealthCodeDetail(this.latest(hostId, revision)!.code))
                  .fontSize(13).fontColor(this.pal().text2).width('100%')
              }
              if (this.routeText(this.latest(hostId, revision)!).length > 0) {
                Text(this.routeText(this.latest(hostId, revision)!)).fontSize(12).fontColor(this.pal().text3)
                  .width('100%')
              }
            }
            .width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().surface)
          }
          Row({ space: 10 }) {
            if (this.primaryActionLabel(hostId, revision).length > 0) {
              Button(this.primaryActionLabel(hostId, revision))
                .height(40).fontSize(14).padding({ left: 16, right: 16 })
                .fontColor(this.pillText(true)).backgroundColor(this.pillColor(true))
                .onClick(() => { this.onAction(hostId, this.primaryAction(hostId, revision)); })
            }
            Button(this.checkingIds.indexOf(hostId) >= 0 ? '检测中…' : '立即检测')
              .height(40).fontSize(14).padding({ left: 16, right: 16 })
              .fontColor(this.pillText(this.primaryActionLabel(hostId, revision).length === 0))
              .backgroundColor(this.pillColor(this.primaryActionLabel(hostId, revision).length === 0))
              .enabled(this.checkingIds.indexOf(hostId) < 0)
              .opacity(this.checkingIds.indexOf(hostId) < 0 ? 1 : 0.5)
              .onClick(() => { this.onCheck(hostId); })
          }.width('100%')
          if (this.history(hostId, revision).length > 1) {
            Column({ space: 8 }) {
              Text('最近 ' + this.history(hostId, revision).length.toString() + ' 次检测')
                .fontSize(13).fontColor(this.pal().text2).width('100%')
              this.historyBars(this.history(hostId, revision))
              ForEach(this.history(hostId, revision).slice(0, 6), (o: HostHealthObservation): void => {
                Row({ space: 8 }) {
                  Column().width(6).height(6).borderRadius(3).backgroundColor(this.statusColor(o.status))
                  Text(hostHealthStatusLabel(o.status)).fontSize(13).fontColor(this.pal().text).layoutWeight(1)
                  Text(hostHealthAgeLabel(o.observedAt, Date.now())).fontSize(12).fontColor(this.pal().text3)
                }.width('100%').height(28)
              }, (o: HostHealthObservation): string => 'row-' + o.observedAt.toString())
            }
            .width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().surface)
            .alignItems(HorizontalAlign.Start)
          }
        }.width('100%').padding({ left: 16, right: 16, bottom: 20 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%')
  }

  @Builder private batchView(revision: number) {
    Column() {
      this.header('主机健康', this.hosts.length.toString() + ' 台主机', false)
      Row() {
        Button(this.batchChecking ? '正在检测…' : '检测这些主机')
          .height(40).fontSize(14).padding({ left: 16, right: 16 })
          .fontColor(this.pillText(true)).backgroundColor(this.pillColor(true))
          .enabled(!this.batchChecking).opacity(this.batchChecking ? 0.5 : 1)
          .onClick(() => { this.onCheckAll(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      List({ space: 8 }) {
        ForEach(this.groups(revision), (group: HostHealthGroup): void => {
          ListItemGroup({ header: this.groupHeader(group) }) {
            ForEach(group.rows, (host: HostHealthRow): void => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(host.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.latest(host.id, revision) === null ? host.protocol.toUpperCase() :
                      host.protocol.toUpperCase() + ' · ' +
                        hostHealthAgeLabel(this.latest(host.id, revision)!.observedAt, Date.now()))
                      .fontSize(12).fontColor(this.pal().text3)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (this.checkingIds.indexOf(host.id) >= 0) {
                    LoadingProgress().width(20).height(20).color(this.accentColor)
                  }
                  SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
                }
                .width('100%').height(56).padding({ left: 14, right: 12 })
                .borderRadius(14).backgroundColor(this.pal().surface)
                .onClick((): void => { this.shownHostId = host.id; })
              }
            }, (host: HostHealthRow): string => host.id + '-' + revision.toString())
          }
        }, (group: HostHealthGroup): string => group.status + '-' + revision.toString())
      }.layoutWeight(1).padding({ left: 16, right: 16 }).scrollBar(BarState.Auto)
    }.width('100%').height('100%')
  }

  @Builder private groupHeader(group: HostHealthGroup) {
    Row({ space: 6 }) {
      Column().width(8).height(8).borderRadius(4).backgroundColor(this.statusColor(group.status))
      Text((group.status === 'never' ? '未检测' : hostHealthStatusLabel(group.status)) + ' · ' +
        group.rows.length.toString())
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2)
    }.width('100%').padding({ top: 8, bottom: 6 })
    .backgroundColor(this.pal().sheetBg)
  }

  build() {
    Column() {
      if (this.shownHostId.length > 0) {
        this.singleView(this.shownHostId, this.revision)
      } else {
        this.batchView(this.revision)
      }
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }
}

