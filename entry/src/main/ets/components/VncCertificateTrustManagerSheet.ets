import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { VncTrustEndpoint, VncTrustService, VncTrustView } from '../services/VncTrustService';
import { VncGatewayService } from '../services/VncGatewayService';
import { VncHostService } from '../services/VncHostService';
import { buildVncTrustDirectory, VncTrustDirectoryItem } from '../services/VncTrustEndpointDirectory';
import { showLockGate, lockGateErrorMessage } from './LockGate';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { VncSheetScaffold } from './vnc/VncSheetScaffold';

/**
 * The sole mutable VNC TLS trust surface. Callers provide navigation for a
 * re-check because only the connection page owns a concrete endpoint.
 */
@Component
export struct VncCertificateTrustManagerSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onClose: () => void = (): void => {};
  onRecheck: (trust: VncTrustView, hostId: string) => void =
    (_trust: VncTrustView, _hostId: string): void => {};
  pendingEndpoint: VncTrustEndpoint | null = null;
  pendingFingerprintSha256: string = '';
  onConfirmed: () => void = (): void => {};
  canConfirmPending: () => boolean = (): boolean => true;

  @State trustItems: VncTrustDirectoryItem[] = [];
  @State revision: number = 0;
  @State busyId: string = '';
  @State errorText: string = '';
  @State expandedIds: string[] = [];

  private readonly trustService: VncTrustService = VncTrustService.getInstance();
  private readonly hostService: VncHostService = VncHostService.getInstance();
  private readonly gatewayService: VncGatewayService = VncGatewayService.getInstance();
  private trustUnsubscribe: (() => void) | null = null;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const context = getContext(this) as common.Context;
    this.trustService.init(context);
    this.hostService.init(context);
    this.gatewayService.init(context);
    this.trustUnsubscribe = this.trustService.onChange((): void => { this.load(); });
    this.load();
  }

  aboutToDisappear(): void {
    if (this.trustUnsubscribe !== null) {
      this.trustUnsubscribe();
      this.trustUnsubscribe = null;
    }
  }

  private load(): void {
    this.trustItems = buildVncTrustDirectory(this.trustService.list(),
      this.hostService.list(), this.gatewayService.list());
    this.revision += 1;
  }

  private redactedFingerprint(value: string): string {
    const normalized: string = value.trim().toLowerCase();
    if (normalized.length !== 64) { return '未知指纹'; }
    return normalized.substring(0, 8) + '…' + normalized.substring(normalized.length - 8);
  }

  private formatTimestamp(value: number): string {
    if (!Number.isFinite(value) || value <= 0) { return '未知'; }
    const date: Date = new Date(value);
    const pad = (part: number): string => part < 10 ? '0' + part.toString() : part.toString();
    return date.getFullYear().toString() + '-' + pad(date.getMonth() + 1) + '-' +
      pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private ownerLabel(trust: VncTrustView): string {
    return trust.ownerType === 'gateway' ? 'VNC Gateway' : 'VNC 主机';
  }

  private statusLabel(trust: VncTrustView): string {
    if (trust.confirmed) { return '本设备已确认'; }
    if (trust.cloudCandidate) { return '云端候选 · 待本机确认'; }
    return '待本设备确认';
  }

  private endpointStatusLabel(item: VncTrustDirectoryItem): string {
    if (item.status === 'orphaned') { return 'owner 已删除/孤立记录'; }
    if (item.status === 'target_missing') { return 'Gateway 存在 · 无当前 target'; }
    if (item.status === 'changed') { return 'endpoint 已变化'; }
    if (item.status === 'ambiguous') { return '多个 target · 请从主机重查'; }
    return '当前 endpoint 存在';
  }

  private transportLabel(value: string): string {
    if (value === 'ultravnc_repeater') { return 'UltraVNC Repeater'; }
    if (value === 'direct_tcp') { return 'Direct TCP'; }
    if (value === 'websocket_gateway') { return 'WebSocket Gateway'; }
    return value === '' ? '未知传输' : value;
  }

  private canRecheck(item: VncTrustDirectoryItem): boolean {
    return item.status === 'current' && item.selectedHostId !== '';
  }

  private isExpanded(id: string): boolean { return this.expandedIds.indexOf(id) >= 0; }

  private toggleDetails(id: string): void {
    if (this.isExpanded(id)) {
      this.expandedIds = this.expandedIds.filter((value: string): boolean => value !== id);
    } else {
      this.expandedIds = this.expandedIds.concat([id]);
    }
  }

  private statusColor(trust: VncTrustView): string {
    return trust.confirmed ? this.pal().success : this.pal().danger;
  }

  private async forgetTrust(trust: VncTrustView): Promise<void> {
    if (this.busyId !== '') { return; }
    const gate = await showLockGate('删除 VNC TLS 信任记录', 'biometric');
    if (!gate.ok) {
      const message: string = lockGateErrorMessage(gate);
      if (message !== '') { promptAction.showToast({ message, duration: 2000 }); }
      return;
    }
    this.busyId = trust.id;
    this.errorText = '';
    const removed: boolean = this.trustService.remove(trust.id);
    this.busyId = '';
    if (!removed) {
      this.errorText = '删除未完成，当前账号或本地信任状态可能已变化';
      return;
    }
    promptAction.showToast({ message: 'VNC TLS 信任已删除', duration: 1500 });
  }

  private async confirmPendingTrust(): Promise<void> {
    if (this.pendingEndpoint === null || this.pendingFingerprintSha256.trim() === '') { return; }
    const gate = await showLockGate('确认 VNC TLS 证书', 'biometric');
    if (!gate.ok) {
      const message: string = lockGateErrorMessage(gate);
      if (message !== '') { promptAction.showToast({ message, duration: 2000 }); }
      return;
    }
    if (!this.canConfirmPending()) {
      this.errorText = '当前 endpoint、账号或存储已变化，请重新执行证书检查';
      return;
    }
    const result = this.trustService.saveForEndpoint(
      this.pendingEndpoint, this.pendingFingerprintSha256, null);
    if (!result.ok) {
      this.errorText = result.message || '证书确认未完成';
      return;
    }
    promptAction.showToast({ message: 'VNC TLS 证书已确认', duration: 1500 });
    this.onConfirmed();
  }

  @Builder private trustCard(item: VncTrustDirectoryItem) {
    Column() {
      Row() {
        Column() {
          Text(this.ownerLabel(item.trust)).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Text(item.ownerLabel !== '' ? item.ownerLabel : item.trust.ownerId)
            .fontSize(11).fontColor(this.pal().text3).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.statusLabel(item.trust)).fontSize(10).fontColor(this.statusColor(item.trust))
          .maxLines(2).textAlign(TextAlign.End)
      }.width('100%').alignItems(VerticalAlign.Top)

      Text(this.redactedFingerprint(item.trust.fingerprintSha256)).fontSize(11)
        .fontColor(this.pal().text2).fontFamily('monospace').width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(8).backgroundColor(this.pal().surface).margin({ top: 10 })

      Column() {
        Text(this.endpointStatusLabel(item) + ' · ' + this.transportLabel(item.transport)).fontSize(11)
          .fontColor(item.status === 'current' ? this.pal().success : this.pal().danger)
          .width('100%').margin({ top: 5 })
        if (item.trust.commonName !== '') { Text('CN: ' + item.trust.commonName).fontSize(11).fontColor(this.pal().text2).maxLines(1) }
        if (item.trust.issuer !== '') { Text('Issuer: ' + item.trust.issuer).fontSize(11).fontColor(this.pal().text2).maxLines(1).margin({ top: 3 }) }
        Text('确认时间 ' + this.formatTimestamp(item.trust.confirmedAt)).fontSize(11)
          .fontColor(this.pal().text3).margin({ top: 5 })
        if (item.trust.notAfterMs > 0) {
          Text('有效期至 ' + this.formatTimestamp(item.trust.notAfterMs)).fontSize(11)
            .fontColor(item.trust.notAfterMs < Date.now() ? this.pal().danger : this.pal().text3).margin({ top: 3 })
        }
        if (!item.trust.rootTrusted || item.trust.hostMismatch) {
          Text((!item.trust.rootTrusted ? '根信任未验证' : '') +
            (!item.trust.rootTrusted && item.trust.hostMismatch ? ' · ' : '') +
            (item.trust.hostMismatch ? '名称不匹配' : ''))
            .fontSize(10).fontColor(this.pal().danger).margin({ top: 4 })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)

      Row() {
        Button('查看详情').height(32).fontSize(12).padding({ left: 10, right: 10 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(8)
          .onClick((): void => { this.toggleDetails(item.trust.id); })
        Button('重新检查').height(32).fontSize(12).padding({ left: 10, right: 10 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(8)
          .enabled(this.busyId === '' && this.canRecheck(item))
          .onClick((): void => { this.onRecheck(item.trust, item.selectedHostId); })
        Button(this.busyId === item.trust.id ? '删除中' : '忘记').height(32).fontSize(12)
          .padding({ left: 10, right: 10 }).backgroundColor(this.pal().surface)
          .fontColor(this.pal().danger).borderRadius(8).margin({ left: 8 })
          .enabled(this.busyId === '').onClick((): void => { void this.forgetTrust(item.trust); })
      }.width('100%').margin({ top: 12 })
      if (this.isExpanded(item.trust.id)) {
        Column() {
          Text('SHA-256 ' + item.trust.fingerprintSha256).fontSize(10).fontFamily('monospace')
            .fontColor(this.pal().text2).width('100%').lineHeight(16)
          Text('Subject: ' + (item.trust.subject === '' ? '未知' : item.trust.subject)).fontSize(11)
            .fontColor(this.pal().text2).width('100%').margin({ top: 4 })
          Text('Issuer: ' + (item.trust.issuer === '' ? '未知' : item.trust.issuer)).fontSize(11)
            .fontColor(this.pal().text2).width('100%').margin({ top: 4 })
          Text('Probe 元数据 · CN=' + (item.trust.commonName === '' ? '未知' : item.trust.commonName) +
            ' · 根信任=' + (item.trust.rootTrusted ? '是' : '否') +
            ' · 名称匹配=' + (item.trust.hostMismatch ? '否' : '是')).fontSize(11)
            .fontColor(this.pal().text2).width('100%').lineHeight(16).margin({ top: 4 })
          Text('endpoint binding ' + this.redactedFingerprint(item.trust.endpointBindingFingerprint)).fontSize(10)
            .fontColor(this.pal().text3).fontFamily('monospace').width('100%').margin({ top: 4 })
        }.width('100%').padding(10).margin({ top: 8 }).backgroundColor(this.pal().surface).borderRadius(8)
      }
    }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
      .margin({ bottom: 10 })
  }

  @Builder private body() {
    Column() {
      Text('云同步记录不会自动取得本机信任；每次 endpoint、账号或设备变化都需要重新确认。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 14 })
      if (this.pendingEndpoint !== null && this.pendingFingerprintSha256 !== '') {
        Column() {
          Text('当前 Gateway 需要本机确认证书').fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).width('100%')
          Text('SHA-256 ' + this.pendingFingerprintSha256).fontSize(10).fontFamily('monospace')
            .fontColor(this.pal().text2).width('100%').lineHeight(16).margin({ top: 6 })
          Button('确认此证书').height(34).fontSize(12).padding({ left: 12, right: 12 })
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(8)
            .margin({ top: 10 }).onClick((): void => { void this.confirmPendingTrust(); })
        }.width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface)
          .margin({ bottom: 10 })
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
          .width('100%').padding(10).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 10 })
      }
      if (this.trustItems.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(34).fontColor([this.pal().text3])
          Text('暂无 VNC TLS 信任记录').fontSize(15).fontColor(this.pal().text).margin({ top: 12 })
          Text('首次连接启用 TLS 的 VNC 主机或 Gateway 并选择信任后，会在这里显示。')
            .fontSize(12).fontColor(this.pal().text3).textAlign(TextAlign.Center).lineHeight(18).margin({ top: 6 })
        }.width('100%').padding({ top: 34, bottom: 38 })
      } else {
        ForEach(this.trustItems, (item: VncTrustDirectoryItem) => { this.trustCard(item); },
          (item: VncTrustDirectoryItem): string => item.trust.id + ':' + this.revision.toString())
      }
    }.width('100%')
  }

  build() {
    VncSheetScaffold({
      title: 'VNC TLS 证书信任',
      subtitle: '主机与 Gateway 使用 endpoint-bound 信任记录',
      showFooter: false,
      onLeadingAction: (): void => { this.onClose(); },
      contentBuilder: (): void => { this.body(); }
    })
  }
}
