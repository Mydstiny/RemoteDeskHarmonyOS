import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { VncTrustService, VncTrustView } from '../services/VncTrustService';
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
  onRecheck: (trust: VncTrustView) => void = (_trust: VncTrustView): void => {};

  @State trusts: VncTrustView[] = [];
  @State revision: number = 0;
  @State busyId: string = '';
  @State errorText: string = '';

  private readonly trustService: VncTrustService = VncTrustService.getInstance();
  private trustUnsubscribe: (() => void) | null = null;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    this.trustService.init(getContext(this) as common.Context);
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
    this.trusts = this.trustService.list();
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

  @Builder private trustCard(trust: VncTrustView) {
    Column() {
      Row() {
        Column() {
          Text(this.ownerLabel(trust)).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Text(trust.endpointLabel !== '' ? trust.endpointLabel : trust.ownerId)
            .fontSize(11).fontColor(this.pal().text3).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.statusLabel(trust)).fontSize(10).fontColor(this.statusColor(trust))
          .maxLines(2).textAlign(TextAlign.End)
      }.width('100%').alignItems(VerticalAlign.Top)

      Text(this.redactedFingerprint(trust.fingerprintSha256)).fontSize(11)
        .fontColor(this.pal().text2).fontFamily('monospace').width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(8).backgroundColor(this.pal().surface).margin({ top: 10 })

      Column() {
        if (trust.commonName !== '') { Text('CN: ' + trust.commonName).fontSize(11).fontColor(this.pal().text2).maxLines(1) }
        if (trust.issuer !== '') { Text('Issuer: ' + trust.issuer).fontSize(11).fontColor(this.pal().text2).maxLines(1).margin({ top: 3 }) }
        Text('确认时间 ' + this.formatTimestamp(trust.confirmedAt)).fontSize(11)
          .fontColor(this.pal().text3).margin({ top: 5 })
        if (trust.notAfterMs > 0) {
          Text('有效期至 ' + this.formatTimestamp(trust.notAfterMs)).fontSize(11)
            .fontColor(trust.notAfterMs < Date.now() ? this.pal().danger : this.pal().text3).margin({ top: 3 })
        }
        if (!trust.rootTrusted || trust.hostMismatch) {
          Text((!trust.rootTrusted ? '根信任未验证' : '') +
            (!trust.rootTrusted && trust.hostMismatch ? ' · ' : '') +
            (trust.hostMismatch ? '名称不匹配' : ''))
            .fontSize(10).fontColor(this.pal().danger).margin({ top: 4 })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)

      Row() {
        Button('重新检查').height(32).fontSize(12).padding({ left: 10, right: 10 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(8)
          .enabled(this.busyId === '').onClick((): void => { this.onRecheck(trust); })
        Button(this.busyId === trust.id ? '删除中' : '忘记').height(32).fontSize(12)
          .padding({ left: 10, right: 10 }).backgroundColor(this.pal().surface)
          .fontColor(this.pal().danger).borderRadius(8).margin({ left: 8 })
          .enabled(this.busyId === '').onClick((): void => { void this.forgetTrust(trust); })
      }.width('100%').margin({ top: 12 })
    }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
      .margin({ bottom: 10 })
  }

  @Builder private body() {
    Column() {
      Text('云同步记录不会自动取得本机信任；每次 endpoint、账号或设备变化都需要重新确认。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 14 })
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
          .width('100%').padding(10).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 10 })
      }
      if (this.trusts.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(34).fontColor([this.pal().text3])
          Text('暂无 VNC TLS 信任记录').fontSize(15).fontColor(this.pal().text).margin({ top: 12 })
          Text('首次连接启用 TLS 的 VNC 主机或 Gateway 并选择信任后，会在这里显示。')
            .fontSize(12).fontColor(this.pal().text3).textAlign(TextAlign.Center).lineHeight(18).margin({ top: 6 })
        }.width('100%').padding({ top: 34, bottom: 38 })
      } else {
        ForEach(this.trusts, (trust: VncTrustView) => { this.trustCard(trust); },
          (trust: VncTrustView): string => trust.id + ':' + this.revision.toString())
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
