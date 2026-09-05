import { Palette, buildDark, buildLight } from '../../common/Theme';
import { MoonlightAddress } from '../../model/MoonlightModels';
import {
  advanceMoonlightHostAddStep,
  beginMoonlightHostAddDiscovery,
  applyMoonlightHostAddVerification,
  backMoonlightHostAddStep,
  beginMoonlightHostAddOperation,
  cancelMoonlightHostAddDiscovery,
  cancelMoonlightHostAddOperation,
  cloneMoonlightHostAddVerification,
  cloneMoonlightHostAddState,
  committedMoonlightHostAddId,
  completeMoonlightHostAddCatalog,
  completeMoonlightHostAddPairing,
  completeMoonlightHostAddSave,
  completeMoonlightHostAddTrust,
  createMoonlightHostAddState,
  expireMoonlightHostAddPairingPin,
  failMoonlightHostAddTrust,
  moonlightHostAddDraftIsDirty,
  moonlightHostAddDiscoveryIsCurrent,
  moonlightHostAddOperationIsCurrent,
  moonlightHostAddPinDigits,
  moonlightHostAddSaveCanBegin,
  MoonlightHostAddBeginResult,
  MoonlightHostAddCandidate,
  MoonlightHostAddCatalogSummary,
  MoonlightHostAddDiscoveryBeginResult,
  MoonlightHostAddDiscoveryKey,
  MoonlightHostAddOperationKey,
  MoonlightHostAddState,
  MoonlightHostAddTransitionResult,
  MoonlightHostAddVerification,
  parseMoonlightHostAddAddress,
  selectMoonlightHostAddCandidate,
  setMoonlightHostAddDisplayName,
  setMoonlightHostAddPairingPin,
  updateMoonlightHostAddManualAddress
} from '../../services/MoonlightHostAddFlowPolicy';
import { protocolIconDescriptor } from '../../services/ProtocolIconPolicy';

export interface MoonlightPairingPreparation {
  ok: boolean;
  pin: string;
  expiresAt: number;
  errorText: string;
}

export interface MoonlightPairingCompletion {
  paired: boolean;
  errorText: string;
  certificateSha256?: string;
}

export interface MoonlightLocalSaveResult {
  localCommitted: boolean;
  hostId: string;
  errorText: string;
  commitState: 'committed' | 'not_committed' | 'partial' | 'uncertain';
}

function unavailablePairingPreparation(): Promise<MoonlightPairingPreparation> {
  const result: MoonlightPairingPreparation = {
    ok: false,
    pin: '',
    expiresAt: 0,
    errorText: 'Moonlight 主机控制能力尚未开放'
  };
  return Promise.resolve(result);
}

function unavailablePairingCompletion(
  _pin: string,
  _key: MoonlightHostAddOperationKey
): Promise<MoonlightPairingCompletion> {
  const result: MoonlightPairingCompletion = {
    paired: false,
    errorText: 'Moonlight 主机控制能力尚未开放'
  };
  return Promise.resolve(result);
}

function unavailableCatalog(): Promise<MoonlightHostAddCatalogSummary> {
  const result: MoonlightHostAddCatalogSummary = {
    appCount: 0,
    titles: [],
    stale: false,
    errorText: '应用目录将在主机控制能力开放后加载'
  };
  return Promise.resolve(result);
}

function unavailableLocalSave(): Promise<MoonlightLocalSaveResult> {
  const result: MoonlightLocalSaveResult = {
    localCommitted: false,
    hostId: '',
    errorText: '当前入口未配置本地主机保存回调',
    commitState: 'not_committed'
  };
  return Promise.resolve(result);
}

@Component
export struct MoonlightHostAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop ownerToken: number = 0;
  @Prop candidates: MoonlightHostAddCandidate[] = [];
  @Prop discoveryRunning: boolean = false;
  @Prop discoveryResultOwnerToken: number = 0;
  @Prop discoveryResultGeneration: number = 0;
  @Prop initialDiscoveryEnabled: boolean = true;
  onBackToProtocols: () => void = (): void => {};
  onStartDiscovery: (key: MoonlightHostAddDiscoveryKey) => void =
    (_key: MoonlightHostAddDiscoveryKey): void => {};
  onPauseDiscovery: (key: MoonlightHostAddDiscoveryKey) => void =
    (_key: MoonlightHostAddDiscoveryKey): void => {};
  onCancelOwner: (ownerToken: number) => void = (_ownerToken: number): void => {};
  onVerify: (
    address: MoonlightAddress,
    selectedServerUuid: string,
    candidateAddresses: MoonlightAddress[],
    key: MoonlightHostAddOperationKey
  ) => Promise<MoonlightHostAddVerification | null> = (
    _address: MoonlightAddress,
    _selectedServerUuid: string,
    _candidateAddresses: MoonlightAddress[],
    _key: MoonlightHostAddOperationKey
  ): Promise<MoonlightHostAddVerification | null> => Promise.resolve(null);
  onPreparePairing: (
    key: MoonlightHostAddOperationKey
  ) => Promise<MoonlightPairingPreparation> = (
    _key: MoonlightHostAddOperationKey
  ): Promise<MoonlightPairingPreparation> => unavailablePairingPreparation();
  onAwaitPairing: (
    pin: string,
    key: MoonlightHostAddOperationKey
  ) => Promise<MoonlightPairingCompletion> = unavailablePairingCompletion;
  onCommitTrust: (
    accepted: boolean,
    key: MoonlightHostAddOperationKey
  ) => Promise<boolean> = (
    _accepted: boolean,
    _key: MoonlightHostAddOperationKey
  ): Promise<boolean> => Promise.resolve(false);
  onLoadCatalog: (
    key: MoonlightHostAddOperationKey
  ) => Promise<MoonlightHostAddCatalogSummary> = (
    _key: MoonlightHostAddOperationKey
  ): Promise<MoonlightHostAddCatalogSummary> => unavailableCatalog();
  onSaveLocal: (
    state: MoonlightHostAddState,
    openCatalog: boolean,
    key: MoonlightHostAddOperationKey
  ) => Promise<MoonlightLocalSaveResult> = (
    _state: MoonlightHostAddState,
    _openCatalog: boolean,
    _key: MoonlightHostAddOperationKey
  ): Promise<MoonlightLocalSaveResult> => unavailableLocalSave();
  onOpenExistingHost: (hostId: string, ownerToken: number) => void = (
    _hostId: string, _ownerToken: number
  ): void => {};
  onSaved: (hostId: string, openCatalog: boolean, ownerToken: number) => void = (
    _hostId: string,
    _openCatalog: boolean,
    _ownerToken: number
  ): void => {};
  onDiscardTemporaryState: () => Promise<void> = (): Promise<void> => Promise.resolve();

  @State flow: MoonlightHostAddState = createMoonlightHostAddState(0);
  @State moonlightIconFailed: boolean = false;
  @State showAdvancedPort: boolean = false;
  @State showDiscardConfirmation: boolean = false;
  @State pairingNowMs: number = 0;
  private pairingCountdownTimer: number = -1;

  aboutToAppear(): void {
    this.flow = createMoonlightHostAddState(this.ownerToken);
    if (this.initialDiscoveryEnabled) {
      this.startDiscovery();
    } else {
      const next: MoonlightHostAddState = cloneMoonlightHostAddState(this.flow);
      next.mode = 'manual';
      this.flow = next;
    }
  }

  aboutToDisappear(): void {
    this.pauseDiscovery();
    this.cancelActiveOperation();
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private withError(message: string): void {
    this.cancelActiveOperation();
    const next: MoonlightHostAddState = cloneMoonlightHostAddState(this.flow);
    next.errorText = message;
    this.flow = next;
  }

  private currentDiscoveryKey(): MoonlightHostAddDiscoveryKey {
    const key = new MoonlightHostAddDiscoveryKey();
    key.ownerToken = this.flow.ownerToken;
    key.generation = this.flow.discoveryGeneration;
    return key;
  }

  private discoveryPayloadIsCurrent(): boolean {
    const key: MoonlightHostAddDiscoveryKey = this.currentDiscoveryKey();
    return moonlightHostAddDiscoveryIsCurrent(this.flow, key) &&
      this.discoveryResultOwnerToken === key.ownerToken &&
      this.discoveryResultGeneration === key.generation;
  }

  private visibleCandidates(): MoonlightHostAddCandidate[] {
    return this.discoveryPayloadIsCurrent() ? this.candidates : [];
  }

  private discoveryIsRunning(): boolean {
    return this.discoveryPayloadIsCurrent() && this.discoveryRunning;
  }

  private pauseDiscovery(): void {
    if (!this.flow.discoveryActive) { return; }
    const key: MoonlightHostAddDiscoveryKey = this.currentDiscoveryKey();
    this.flow = cancelMoonlightHostAddDiscovery(this.flow);
    this.onPauseDiscovery(key);
  }

  private startDiscovery(): void {
    this.pauseDiscovery();
    const begin: MoonlightHostAddDiscoveryBeginResult =
      beginMoonlightHostAddDiscovery(this.flow);
    this.flow = begin.state;
    this.onStartDiscovery(begin.key);
  }

  private cancelActiveOperation(): void {
    this.stopPairingCountdown();
    if (this.flow.activeOperation !== 'none' && this.flow.ownerToken > 0) {
      this.onCancelOwner(this.flow.ownerToken);
    }
    this.flow = cancelMoonlightHostAddOperation(this.flow);
  }

  private stopPairingCountdown(): void {
    if (this.pairingCountdownTimer !== -1) {
      clearInterval(this.pairingCountdownTimer);
      this.pairingCountdownTimer = -1;
    }
  }

  private startPairingCountdown(): void {
    this.stopPairingCountdown();
    this.pairingNowMs = Date.now();
    this.pairingCountdownTimer = setInterval((): void => {
      const nowMs: number = Date.now();
      const previousPin: string = this.flow.pairingPin;
      const next: MoonlightHostAddState =
        expireMoonlightHostAddPairingPin(this.flow, nowMs);
      this.pairingNowMs = nowMs;
      this.flow = next;
      if (previousPin !== '' && next.pairingPin === '') {
        if (next.ownerToken > 0) { this.onCancelOwner(next.ownerToken); }
        this.stopPairingCountdown();
      }
    }, 1000);
  }

  private pairingSecondsRemaining(): number {
    if (this.flow.pairingPin === '' || this.flow.pairingPinExpiresAt <= this.pairingNowMs) {
      return 0;
    }
    return Math.ceil((this.flow.pairingPinExpiresAt - this.pairingNowMs) / 1000);
  }

  private stepLabel(): string {
    if (this.flow.step === 1) { return '1/4  查找主机'; }
    if (this.flow.step === 2) { return '2/4  验证主机'; }
    if (this.flow.step === 3) { return '3/4  配对与信任'; }
    return '4/4  完成';
  }

  private requestBack(): void {
    if (this.flow.step > 1) {
      this.cancelActiveOperation();
      this.flow = backMoonlightHostAddStep(this.flow);
      this.showDiscardConfirmation = false;
      return;
    }
    if (moonlightHostAddDraftIsDirty(this.flow)) {
      this.showDiscardConfirmation = true;
      return;
    }
    this.pauseDiscovery();
    this.onBackToProtocols();
  }

  private async discardAndBack(): Promise<void> {
    this.pauseDiscovery();
    this.cancelActiveOperation();
    try {
      await this.onDiscardTemporaryState();
    } catch (_error) {
      // The native path revokes local trust before attempting remote cleanup.
      // Navigation may continue even when Sunshine cannot confirm /unpair.
    }
    this.showDiscardConfirmation = false;
    this.onBackToProtocols();
  }

  private selectedCandidate(): MoonlightHostAddCandidate | null {
    const candidates: MoonlightHostAddCandidate[] = this.visibleCandidates();
    for (let index = 0; index < candidates.length; index++) {
      if (candidates[index].serverUuid === this.flow.selectedServerUuid) {
        return candidates[index];
      }
    }
    return null;
  }

  private canVerifyHost(): boolean {
    if (this.flow.activeOperation !== 'none') { return false; }
    if (this.flow.mode === 'automatic') { return this.selectedCandidate() !== null; }
    return parseMoonlightHostAddAddress(
      this.flow.manualAddressText, this.flow.manualPortText).ok;
  }

  private async verifyHost(): Promise<void> {
    let address: MoonlightAddress;
    let serverUuid: string = '';
    let candidateAddresses: MoonlightAddress[] = [];
    if (this.flow.mode === 'automatic') {
      const candidate: MoonlightHostAddCandidate | null = this.selectedCandidate();
      if (candidate === null) { this.withError('请选择一台已发现的主机'); return; }
      address = candidate.address;
      serverUuid = candidate.serverUuid;
      candidateAddresses = candidate.addresses === undefined ?
        [candidate.address] : candidate.addresses;
    } else {
      const parsed = parseMoonlightHostAddAddress(
        this.flow.manualAddressText, this.flow.manualPortText);
      if (!parsed.ok) { this.withError(parsed.errorText); return; }
      address = parsed.address;
      candidateAddresses = [parsed.address];
    }
    this.pauseDiscovery();
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'verify');
    this.flow = begin.state;
    try {
      const result: MoonlightHostAddVerification | null =
        await this.onVerify(address, serverUuid, candidateAddresses, begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      if (result === null) {
        this.withError('无法验证主机，请检查 Sunshine、地址与网络后重试');
        return;
      }
      this.flow = applyMoonlightHostAddVerification(this.flow, begin.key, result);
    } catch (_error) {
      if (moonlightHostAddOperationIsCurrent(this.flow, begin.key)) {
        this.withError('无法验证主机，请检查 Sunshine 和网络后重试');
      }
    }
  }

  private continueFromVerification(): void {
    const transition: MoonlightHostAddTransitionResult =
      advanceMoonlightHostAddStep(this.flow);
    this.flow = transition.state;
  }

  private async startPairing(): Promise<void> {
    if (this.flow.activeOperation !== 'none') {
      this.cancelActiveOperation();
    }
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'pair');
    this.flow = begin.state;
    try {
      const preparation: MoonlightPairingPreparation =
        await this.onPreparePairing(begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      if (!preparation.ok) {
        this.withError(preparation.errorText === '' ? '无法生成配对码' : preparation.errorText);
        return;
      }
      this.flow = setMoonlightHostAddPairingPin(
        this.flow, begin.key, preparation.pin, preparation.expiresAt, Date.now());
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key) ||
          this.flow.pairingPin === '') {
        this.withError('配对码无效，请重新生成');
        return;
      }
      this.startPairingCountdown();
      const completion: MoonlightPairingCompletion =
        await this.onAwaitPairing(preparation.pin, begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      const nowMs: number = Date.now();
      const beforeExpiry: string = this.flow.pairingPin;
      this.flow = expireMoonlightHostAddPairingPin(this.flow, nowMs);
      if (beforeExpiry !== '' && this.flow.pairingPin === '') {
        if (this.flow.ownerToken > 0) { this.onCancelOwner(this.flow.ownerToken); }
        this.stopPairingCountdown();
        return;
      }
      this.stopPairingCountdown();
      if (completion.paired && completion.certificateSha256 !== undefined &&
          /^[0-9a-fA-F]{64}$/.test(completion.certificateSha256) &&
          this.flow.verification !== null) {
        const withFingerprint: MoonlightHostAddState = cloneMoonlightHostAddState(this.flow);
        const pairedVerification: MoonlightHostAddVerification =
          cloneMoonlightHostAddVerification(this.flow.verification);
        pairedVerification.fingerprintSha256 = completion.certificateSha256;
        withFingerprint.verification = pairedVerification;
        this.flow = withFingerprint;
      }
      this.flow = completeMoonlightHostAddPairing(
        this.flow, begin.key, completion.paired, nowMs, completion.errorText);
    } catch (_error) {
      if (moonlightHostAddOperationIsCurrent(this.flow, begin.key)) {
        this.withError('配对连接已中断，请重新生成配对码');
      }
    }
  }

  private async trustAndContinue(): Promise<void> {
    if (!this.flow.paired) { this.withError('请先完成主机配对'); return; }
    if (this.flow.trustState === 'changed') {
      this.withError('主机证书已变化，请返回并重新验证');
      return;
    }
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'trust');
    this.flow = begin.state;
    try {
      const committed: boolean = await this.onCommitTrust(true, begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      if (!committed) {
        this.flow = failMoonlightHostAddTrust(this.flow, begin.key);
        return;
      }
      this.flow = completeMoonlightHostAddTrust(this.flow, begin.key, true);
      const transition: MoonlightHostAddTransitionResult =
        advanceMoonlightHostAddStep(this.flow);
      this.flow = transition.state;
      if (transition.ok) { await this.loadCatalog(); }
    } catch (_error) {
      if (moonlightHostAddOperationIsCurrent(this.flow, begin.key)) {
        this.withError('无法保存主机信任，请重试');
      }
    }
  }

  private async rejectTrust(): Promise<void> {
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'trust');
    this.flow = begin.state;
    try {
      await this.onCommitTrust(false, begin.key);
    } catch (_error) {
      // Rejection remains local even if best-effort remote unpair fails.
    }
    if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
    this.flow = completeMoonlightHostAddTrust(this.flow, begin.key, false);
    try {
      await this.onDiscardTemporaryState();
    } catch (_error) {
      // Explicit rejection remains authoritative locally.
    }
  }

  private async loadCatalog(): Promise<void> {
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'catalog');
    this.flow = begin.state;
    try {
      const catalog: MoonlightHostAddCatalogSummary = await this.onLoadCatalog(begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      this.flow = completeMoonlightHostAddCatalog(this.flow, begin.key, catalog);
    } catch (_error) {
      if (moonlightHostAddOperationIsCurrent(this.flow, begin.key)) {
        this.flow = completeMoonlightHostAddCatalog(this.flow, begin.key, {
          appCount: 0,
          titles: [],
          stale: false,
          errorText: '应用目录暂时无法加载，可保存后再刷新'
        });
      }
    }
  }

  private async save(openCatalog: boolean): Promise<void> {
    if (this.flow.activeOperation !== 'none' || this.flow.savedLocally) {
      return;
    }
    if (!moonlightHostAddSaveCanBegin(this.flow)) {
      this.withError('主机尚未完成配对与信任');
      return;
    }
    const begin: MoonlightHostAddBeginResult =
      beginMoonlightHostAddOperation(this.flow, 'save');
    this.flow = begin.state;
    try {
      const result: MoonlightLocalSaveResult =
        await this.onSaveLocal(cloneMoonlightHostAddState(this.flow), openCatalog, begin.key);
      if (!moonlightHostAddOperationIsCurrent(this.flow, begin.key)) { return; }
      const committedHostId: string = committedMoonlightHostAddId(
        result.localCommitted, result.hostId);
      const handoffEligible: boolean = committedHostId !== '';
      const errorText: string = result.localCommitted && !handoffEligible ?
        '本地主机已保存，但未返回稳定 ID；请在主机列表刷新后打开' : result.errorText;
      this.flow = completeMoonlightHostAddSave(
        this.flow, begin.key, result.localCommitted, errorText, result.commitState);
      if (result.localCommitted && result.commitState === 'committed') {
        this.onSaved(
          committedHostId,
          openCatalog && handoffEligible,
          begin.key.ownerToken
        );
      }
    } catch (_error) {
      if (moonlightHostAddOperationIsCurrent(this.flow, begin.key)) {
        this.withError('本地主机保存失败，请重试');
      }
    }
  }

  private fingerprintSummary(): string {
    if (this.flow.verification === null) { return '—'; }
    const value: string = this.flow.verification.fingerprintSha256.toUpperCase();
    if (value.length < 16) { return value === '' ? '—' : value; }
    return value.substring(0, 4) + ' ' + value.substring(4, 8) + ' · ' +
      value.substring(value.length - 8, value.length - 4) + ' ' +
      value.substring(value.length - 4);
  }

  private addressSummary(): string {
    const address: MoonlightAddress = this.flow.selectedAddress;
    if (address.host === '') { return '—'; }
    const scope: string = address.scope === undefined ? '' : address.scope;
    return address.family === 'ipv6' ?
      '[' + address.host + (scope === '' ? '' : '%' + scope) + ']:' + address.port.toString() :
      address.host + ':' + address.port.toString();
  }

  private modeIsSelected(automatic: boolean): boolean {
    return (this.flow.mode === 'automatic') === automatic;
  }

  private manualAddressFeedbackText(): string {
    const parsed = parseMoonlightHostAddAddress(
      this.flow.manualAddressText, this.flow.manualPortText);
    return parsed.ok ? '将验证：' + parsed.canonical : parsed.errorText;
  }

  private manualAddressFeedbackColor(): string {
    return parseMoonlightHostAddAddress(
      this.flow.manualAddressText, this.flow.manualPortText).ok ?
      this.pal().text3 : this.pal().danger;
  }

  @Builder private header() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(18).fontColor([this.pal().text2])
      }
      .width(36).height(36).borderRadius(18).padding(0)
      .backgroundColor(this.pal().surface)
      .accessibilityText(this.flow.step === 1 ? '返回协议选择' : '返回上一步')
      .onClick((): void => { this.requestBack(); })
      if (!this.moonlightIconFailed) {
        Image(protocolIconDescriptor('moonlight').resource)
          .width(28).height(28).fillColor(this.accentColor)
          .margin({ left: 12, right: 10 }).accessibilityText('Moonlight')
          .onError((): void => { this.moonlightIconFailed = true; })
      } else {
        SymbolGlyph(protocolIconDescriptor('moonlight').fallback)
          .fontSize(26).fontColor([this.accentColor])
          .margin({ left: 12, right: 10 }).accessibilityText('Moonlight')
      }
      Column() {
        Text('添加 Moonlight 主机').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text)
        Text(this.stepLabel()).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').margin({ bottom: 18 })
  }

  @Builder private modeButton(title: string, subtitle: string, automatic: boolean,
    enabled: boolean = true) {
    Column() {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium)
        .fontColor(this.modeIsSelected(automatic) ? Color.White :
          (enabled ? this.pal().text : this.pal().text3))
      Text(subtitle).fontSize(11)
        .fontColor(this.modeIsSelected(automatic) ? '#DDEEFF' : this.pal().text3).margin({ top: 4 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(14).borderRadius(12)
      .backgroundColor(this.modeIsSelected(automatic) ? this.accentColor : this.pal().surface)
      .opacity(enabled ? 1 : 0.58)
      .onClick((): void => {
        if (!enabled) { return; }
        if (!automatic) { this.pauseDiscovery(); }
        const next: MoonlightHostAddState = cloneMoonlightHostAddState(this.flow);
        next.mode = automatic ? 'automatic' : 'manual';
        next.errorText = '';
        this.flow = next;
        if (automatic && !this.flow.discoveryActive) { this.startDiscovery(); }
      })
  }

  @Builder private field(
    title: string,
    value: string,
    hint: string,
    change: (value: string) => void
  ) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(11)
        .padding({ left: 12, right: 12 }).onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private statusCard(title: string, subtitle: string, positive: boolean = false) {
    Row() {
      SymbolGlyph(positive ? $r('sys.symbol.checkmark_circle_fill') :
        $r('sys.symbol.info_circle_fill'))
        .fontSize(22).fontColor([positive ? this.pal().success : this.accentColor])
        .margin({ right: 10 })
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(subtitle).fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      .margin({ bottom: 12 })
  }

  @Builder private primaryButton(title: string, action: () => void, enabled: boolean = true) {
    Button(title).width('100%').height(44).borderRadius(12)
      .backgroundColor(enabled ? this.accentColor : this.pal().surface)
      .fontColor(enabled ? Color.White : this.pal().text3).enabled(enabled)
      .opacity(enabled ? 1 : 0.72).onClick(action)
  }

  @Builder private discoveryStep() {
    Text('主机需运行 Sunshine 或兼容 GameStream 服务，并与当前设备位于可访问网络。')
      .fontSize(12).fontColor(this.pal().text3).width('100%').margin({ bottom: 14 })
    Row() {
      this.modeButton('自动发现', this.initialDiscoveryEnabled ?
        '搜索同一局域网主机' : '已在网络设置中关闭', true, this.initialDiscoveryEnabled)
      Blank().width(8)
      this.modeButton('手动输入', '使用域名或 IP 地址', false)
    }.width('100%').margin({ bottom: 14 })
    if (this.flow.mode === 'automatic') {
      Row() {
        if (this.discoveryIsRunning()) {
          LoadingProgress().width(18).height(18).color(this.accentColor)
        } else {
          SymbolGlyph($r('sys.symbol.link')).fontSize(18).fontColor([this.accentColor])
        }
        Text(this.discoveryIsRunning() ?
          '正在发现（已找到 ' + this.visibleCandidates().length.toString() + ' 台）' :
          (this.visibleCandidates().length === 0 ? '暂未发现主机' :
            '已发现 ' + this.visibleCandidates().length.toString() + ' 台主机'))
          .fontSize(12).fontColor(this.pal().text3).margin({ left: 8 }).layoutWeight(1)
        Button(this.discoveryIsRunning() ? '暂停' : '重新扫描').height(36).borderRadius(9)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => {
            if (this.discoveryIsRunning()) { this.pauseDiscovery(); } else { this.startDiscovery(); }
          })
      }.width('100%').margin({ bottom: 10 })
      // Keep the sheet intrinsic like RustDesk, but bound the dynamic result
      // region so a crowded LAN or large font never pushes the actions out of
      // the visible sheet. Only the candidate list scrolls.
      Scroll() {
        Column() {
          ForEach(this.visibleCandidates(), (candidate: MoonlightHostAddCandidate) => {
            Row() {
              Column() {
                Text(candidate.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text)
                Text((candidate.reachable ? '在线' : '状态未知') + ' · ' +
                  candidate.address.host + (candidate.paired ? ' · 已配对' : ' · 未配对'))
                  .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.flow.selectedServerUuid === candidate.serverUuid) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(20).fontColor([this.accentColor])
              } else {
                Text('选择').fontSize(12).fontColor(this.accentColor)
              }
            }.width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface)
              .margin({ bottom: 7 })
              .border({
                width: this.flow.selectedServerUuid === candidate.serverUuid ? 1 : 0,
                color: this.accentColor
              })
              .onClick((): void => {
                this.flow = selectMoonlightHostAddCandidate(this.flow, candidate);
              })
          }, (candidate: MoonlightHostAddCandidate): string => candidate.serverUuid)
        }.width('100%')
      }.width('100%')
        .constraintSize({ maxHeight: this.breakpoint === 'sm' ? 260 : 320 })
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    } else {
      this.field('主机地址', this.flow.manualAddressText, '例如：gaming-pc.local 或 192.168.1.10',
        (value: string): void => {
          this.flow = updateMoonlightHostAddManualAddress(
            this.flow, value, this.flow.manualPortText);
        })
      Row() {
        Text('自定义端口').fontSize(12).fontColor(this.pal().text2).layoutWeight(1)
        Button(this.showAdvancedPort ? '收起' : '展开').height(32).borderRadius(8)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.showAdvancedPort = !this.showAdvancedPort; })
      }.width('100%').margin({ bottom: this.showAdvancedPort ? 6 : 12 })
      if (this.showAdvancedPort) {
        this.field('主机控制端口', this.flow.manualPortText, '47989', (value: string): void => {
          this.flow = updateMoonlightHostAddManualAddress(
            this.flow, this.flow.manualAddressText, value);
        })
      }
      if (this.flow.manualAddressText.trim() !== '') {
        Text(this.manualAddressFeedbackText())
          .fontSize(11).fontColor(this.manualAddressFeedbackColor())
          .width('100%').margin({ bottom: 10 })
      }
    }
    Column({ space: this.breakpoint === 'sm' ? 12 : 10 }) {
      if (this.flow.mode === 'automatic' && this.visibleCandidates().length === 0 &&
          !this.discoveryIsRunning()) {
        Button('改用手动输入').width('100%').height(40).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => {
            this.pauseDiscovery();
            const next: MoonlightHostAddState = cloneMoonlightHostAddState(this.flow);
            next.mode = 'manual';
            this.flow = next;
          })
      }
      // Keep the verification gate in this state-owning builder. Passing the
      // computed boolean through primaryButton freezes its initial value on
      // ArkUI V1, so discovery selection and manual-address edits could not
      // enable the button even though the flow state had changed.
      Button(this.flow.activeOperation === 'verify' ? '正在验证…' : '验证主机')
        .width('100%').height(44).borderRadius(12)
        .backgroundColor(this.canVerifyHost() ? this.accentColor : this.pal().surface)
        .fontColor(this.canVerifyHost() ? Color.White : this.pal().text3)
        .enabled(this.canVerifyHost())
        .opacity(this.canVerifyHost() ? 1 : 0.72)
        .onClick((): void => { this.verifyHost(); })
    }.width('100%').margin({ top: 4 })
  }

  @Builder private verificationStep() {
    if (this.flow.verification !== null) {
      this.statusCard(
        this.flow.verification.hostType === 'sunshine' ? '已找到 Sunshine' : '已找到兼容 GameStream 主机',
        this.flow.verification.serverName + ' · ' + this.addressSummary(), true)
      Column({ space: 8 }) {
        Row() {
          Text('服务器版本').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
          Text(this.flow.verification.version === '' ? '未知' : this.flow.verification.version)
            .fontSize(12).fontColor(this.pal().text)
        }.width('100%')
        Row() {
          Text('配对状态').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
          Text(this.flow.verification.paired ? '已配对' : '需要配对')
            .fontSize(12).fontColor(this.pal().text)
        }.width('100%')
        Row() {
          Text('媒体网络').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
          Text(this.flow.verification.udpVerified ? '已验证' : '启动前仍需检查')
            .fontSize(12).fontColor(this.flow.verification.udpVerified ?
              this.pal().success : this.pal().editColor)
        }.width('100%')
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
        .margin({ bottom: 12 })
      this.field('显示名称', this.flow.displayName, '例如：客厅游戏电脑',
        (value: string): void => {
          this.flow = setMoonlightHostAddDisplayName(this.flow, value);
        })
      if (this.flow.verification.duplicateHostId !== '') {
        Text('这台主机已经保存在当前账号的本地数据中，不会创建重复记录。')
          .fontSize(12).fontColor(this.pal().editColor).width('100%').margin({ bottom: 10 })
        Button('查看已有主机').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => {
            if (this.flow.verification !== null) {
              this.onOpenExistingHost(
                this.flow.verification.duplicateHostId, this.flow.ownerToken);
            }
          })
      } else {
        this.primaryButton(this.flow.verification.paired ? '检查信任' : '继续配对',
          (): void => { this.continueFromVerification(); })
      }
    } else {
      this.statusCard('尚未验证主机', '返回上一步重新选择地址')
    }
  }

  @Builder private pinCard() {
    Text('请在主机端输入此 PIN').fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%').textAlign(TextAlign.Center)
    Text(this.flow.verification === null ? '' : this.flow.verification.serverName)
      .fontSize(11).fontColor(this.pal().text3).width('100%').textAlign(TextAlign.Center)
      .margin({ top: 4, bottom: 12 })
    Row({ space: 8 }) {
      ForEach(moonlightHostAddPinDigits(this.flow), (digit: string, index: number) => {
        Text(digit).width(48).height(56).fontSize(28).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).textAlign(TextAlign.Center)
          .backgroundColor(this.pal().surface).borderRadius(12)
          .accessibilityText(index === 0 ? '4 位主机配对码已生成' : '')
      }, (_digit: string, index: number): string => index.toString())
    }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 10 })
    Text('配对码不会复制到剪贴板；离开或取消后立即清除。')
      .fontSize(11).fontColor(this.pal().text3).width('100%').textAlign(TextAlign.Center)
    Text('剩余 ' + this.pairingSecondsRemaining().toString() + ' 秒')
      .fontSize(11).fontColor(this.pal().text3).width('100%').textAlign(TextAlign.Center)
      .margin({ top: 5 })
    // 配对码朗读入口暂不开放，PIN 仅在当前 BindSheet 中显示。
  }

  @Builder private pairingStep() {
    if (!this.flow.paired) {
      if (this.flow.pairingPin !== '') {
        this.pinCard()
        Row() {
          Button('取消配对').layoutWeight(1).height(40).borderRadius(10)
            .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
            .onClick((): void => {
              this.cancelActiveOperation();
              void this.onDiscardTemporaryState();
            })
          Button('重新生成').layoutWeight(1).height(40).borderRadius(10).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White)
            .onClick((): void => { this.startPairing(); })
        }.width('100%').margin({ top: 12 })
      } else {
        this.statusCard('需要与主机配对', '配对码将在本机生成，请在 Sunshine 主机端输入')
        this.primaryButton(this.flow.activeOperation === 'pair' ? '正在等待主机确认…' : '生成配对码',
          (): void => { this.startPairing(); }, this.flow.activeOperation === 'none')
      }
    } else if (this.flow.trustState === 'changed') {
      Text('主机证书已变化').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().danger).width('100%').margin({ bottom: 6 })
      Text('为保护配对身份，当前流程不能覆盖旧证书。请返回重新验证或稍后从主机详情重新配对。')
        .fontSize(12).fontColor(this.pal().text3).width('100%')
    } else if (this.flow.trustState === 'trusted') {
      this.statusCard('身份已验证', '主机证书与本次配对一致', true)
      this.primaryButton('继续', (): void => {
        const transition: MoonlightHostAddTransitionResult =
          advanceMoonlightHostAddStep(this.flow);
        this.flow = transition.state;
        if (transition.ok) { this.loadCatalog(); }
      })
    } else {
      this.statusCard('确认主机身份', '该指纹将用于识别这台主机')
      Column({ space: 7 }) {
        Text(this.flow.verification === null ? '未知主机' : this.flow.verification.serverName)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text('SHA-256  ' + this.fingerprintSummary()).fontSize(12)
          .fontColor(this.pal().text2)
      }.alignItems(HorizontalAlign.Start).width('100%').padding(12)
        .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 12 })
      Row() {
        Button('拒绝并取消配对').layoutWeight(1).height(44).borderRadius(12)
          .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
          .onClick((): void => { this.rejectTrust(); })
        Button(this.flow.activeOperation === 'trust' ? '正在保存…' : '信任并继续')
          .layoutWeight(1).height(44).borderRadius(12).margin({ left: 12 })
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .enabled(this.flow.activeOperation === 'none')
          .onClick((): void => { this.trustAndContinue(); })
      }.width('100%')
    }
  }

  @Builder private completionStep() {
    this.statusCard('主机已准备好', '保存范围：仅当前账号的本地数据', true)
    Column({ space: 8 }) {
      Row() {
        Text('名称').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        Text(this.flow.displayName).fontSize(12).fontColor(this.pal().text)
      }.width('100%')
      Row() {
        Text('主机类型').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        Text(this.flow.verification !== null && this.flow.verification.hostType === 'sunshine' ?
          'Sunshine' : '兼容 GameStream').fontSize(12).fontColor(this.pal().text)
      }.width('100%')
      Row() {
        Text('首选地址').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        Text(this.addressSummary()).fontSize(12).fontColor(this.pal().text)
      }.width('100%')
      Row() {
        Text('配对与信任').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        Text('已完成').fontSize(12).fontColor(this.pal().success)
      }.width('100%')
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      .margin({ bottom: 12 })
    if (this.flow.activeOperation === 'catalog') {
      Row() {
        LoadingProgress().width(18).height(18).color(this.accentColor)
        Text('正在读取应用目录…').fontSize(12).fontColor(this.pal().text3).margin({ left: 8 })
      }.width('100%').margin({ bottom: 12 })
    } else if (this.flow.catalog !== null) {
      Text(this.flow.catalog.errorText !== '' ? this.flow.catalog.errorText :
        '已找到 ' + this.flow.catalog.appCount.toString() + ' 个应用')
        .fontSize(12).fontColor(this.flow.catalog.errorText === '' ?
          this.pal().text2 : this.pal().editColor).width('100%').margin({ bottom: 8 })
      ForEach(this.flow.catalog.titles.slice(0, 3), (title: string) => {
        Row() {
          SymbolGlyph($r('sys.symbol.gamecontroller_fill')).fontSize(18)
            .fontColor([this.accentColor]).margin({ right: 10 })
          Text(title).fontSize(13).fontColor(this.pal().text).layoutWeight(1)
        }.width('100%').height(40).padding({ left: 10, right: 10 })
          .backgroundColor(this.pal().surface).borderRadius(9).margin({ bottom: 6 })
      }, (title: string): string => title)
    }
    Text('不会上传到云端；目录加载失败也不会丢失已完成的配对。')
      .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 12 })
    if (this.flow.saveRecoveryRequired) {
      Text('本地保存状态需要先刷新主机列表确认，当前不会重复写入。')
        .fontSize(11).fontColor(this.pal().editColor).width('100%').margin({ bottom: 10 })
    }
    Row({ space: 12 }) {
      Button(this.flow.activeOperation === 'save' ? '正在保存…' : '保存')
        .layoutWeight(1).height(44).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.accentColor)
        .enabled(this.flow.activeOperation === 'none' && !this.flow.saveRecoveryRequired)
        .onClick((): void => { this.save(false); })
      Button(this.flow.activeOperation === 'save' ? '正在保存…' : '保存并打开应用目录')
        .layoutWeight(1).height(44).borderRadius(12)
        .backgroundColor(this.accentColor).fontColor(Color.White)
        .enabled(this.flow.activeOperation === 'none' && !this.flow.saveRecoveryRequired)
        .onClick((): void => { this.save(true); })
    }.width('100%')
  }

  @Builder private discardConfirmation() {
    Column() {
      Text('保留当前添加进度？').fontSize(15).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).width('100%')
      Text('手动地址、已选主机或临时配对身份尚未完成保存。')
        .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ top: 4, bottom: 10 })
      Row() {
        Button('丢弃草稿').layoutWeight(1).height(40).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
          .onClick((): void => { void this.discardAndBack(); })
        Button('继续添加').layoutWeight(1).height(40).borderRadius(10).margin({ left: 12 })
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.showDiscardConfirmation = false; })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(12).backgroundColor(this.pal().surface)
      .margin({ top: 12 })
  }

  build() {
    Column() {
      Column() {
        this.header()
        if (this.flow.step === 1) {
          this.discoveryStep()
        } else if (this.flow.step === 2) {
          this.verificationStep()
        } else if (this.flow.step === 3) {
          this.pairingStep()
        } else {
          this.completionStep()
        }
        if (this.flow.errorText !== '') {
          Text(this.flow.errorText).fontSize(12).fontColor(this.pal().danger)
            .width('100%').margin({ top: 10 })
        }
        if (this.showDiscardConfirmation) { this.discardConfirmation() }
      }.width('100%').padding({
        left: this.breakpoint === 'sm' ? 20 : 24,
        right: this.breakpoint === 'sm' ? 20 : 24,
        top: 20,
        bottom: this.breakpoint === 'sm' ? 28 : 24
      })
        .backgroundColor(this.pal().sheetBg)
    }.width('100%')
  }
}
