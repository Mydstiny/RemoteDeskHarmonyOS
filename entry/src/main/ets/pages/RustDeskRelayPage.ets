/**
 * RustDeskRelayPage.ets — RustDesk 中继服务器管理页面 v2
 *
 * v2 改进:
 * - 卡片样式对齐 HostCard/SshKeyCard/TotpCodeCard (圆角14, 无阴影, padding 12)
 * - 顶部概览条: 中继/在线/异常/账户统计
 * - PC端 ⋯ popup 菜单替代4个文字按钮 (对齐 SshKeyCard)
 * - 移动端 swipeAction 右滑测试+编辑, 左滑删除 (对齐 KeyVaultPage)
 * - 空状态引导式设计
 * - 展开/折叠动画 + 服务器信息区
 * - 账户行样式对齐 TotpCodeCard
 * - FAB + bindSheet 添加/编辑流程保持不变
 */
import { promptAction, curves } from '@kit.ArkUI';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RustDeskProAccountState } from '../model/RustDeskProModels';
import { HostSyncService } from '../services/HostSyncService';
import { RustDeskProSyncService } from '../services/RustDeskProSyncService';
import { snapshotSelectedRelay } from '../services/RustDeskRelayHealthPolicy';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { ResourceFabPicker } from '../components/resourceadd/ResourceFabPicker';
import { RustDeskRelayImportService, RustDeskRelayImportResult } from '../services/RustDeskRelayImportService';
import { RustDeskRelayKeyMode, resolveRustDeskRelayKey } from '../services/RustDeskRelayKeyPolicy';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT,
  rustDeskControlPlaneProfileDescription,
  rustDeskControlPlaneProfileLabel
} from '../services/RustDeskControlPlanePolicy';
import { RustDeskRelayConfigPasteSheet } from '../components/resourceadd/modern/RustDeskRelayConfigPasteSheet';
import { VncGatewayAddFlow } from '../components/resourceadd/VncGatewayAddFlow';
import { VncCertificateTrustManagerSheet } from '../components/VncCertificateTrustManagerSheet';
import { VncGatewayService, VncGatewayView } from '../services/VncGatewayService';
import { VncGatewayValues } from '../services/VncModelPolicy';
import { VncHostValues } from '../services/VncModelPolicy';
import { vncGatewayAvailability } from '../services/VncGatewayProtocolPolicy';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { ExtensionLoader } from '../services/ExtensionLoader';
import {
  VncTrustEndpoint,
  VncTrustView,
  VncTrustService,
  vncStoreIdentityFingerprint
} from '../services/VncTrustService';
import {
  resolveVncTlsEndpoint,
  vncTlsGatewayInput,
  vncTlsHostInput,
  VncTlsEndpointResolution
} from '../services/VncTlsEndpointPolicy';
import {
  classifyVncGatewayHealth,
  VncGatewayHealthResult
} from '../services/VncGatewayHealthPolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  RustDeskRelayCloudSyncOutcome,
  RustDeskRelayCloudSyncState,
  rustDeskRelayCloudSyncMessage,
  rustDeskRelayIdFingerprint,
  RustDeskRelaySaveRecovery,
  RustDeskRelaySaveResult
} from '../services/RustDeskRelaySavePolicy';
import {
  RustDeskRelaySetupCoordinator,
  RustDeskRelaySetupDraft
} from '../services/RustDeskRelaySetupCoordinator';
import { DataMutationStage } from '../services/DataMutationResult';
import {
  rustDeskRelayDirectoryBottomClearance,
  rustDeskRelaySheetUsesResizeOnly
} from '../services/RustDeskRelayLayoutPolicy';

class TcpTestResult {
  ok: boolean = false;
  lat: number = 0;
}

interface ProSyncToastResult {
  message: string;
  capabilityReady: boolean;
}

interface VncDeepCheckBinding {
  gatewayId: string;
  ownerId: string;
  userId: string;
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
  accountGeneration: number;
  tlsRequired: boolean;
  enabled: boolean;
  repeaterTarget: string;
}

@Component
export struct RustDeskRelayPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop @Watch('onAddTrigger') addTrigger: number = 0;
  @Prop @Watch('onRustDeskAddTrigger') rustDeskAddTrigger: number = 0;
  @Prop @Watch('onVncAddTrigger') vncAddTrigger: number = 0;
  @Prop hideTabBar: boolean = false;
  @Prop returnToHostAdd: boolean = false;
  onReturnToHostAdd: (relayId: string) => void =
    (_relayId: string): void => {};
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @State relays: RustDeskRelayConfig[] = [];
  @State vncGateways: VncGatewayView[] = [];
  @State expandedRelayIds: string[] = [];
  @State showSheet: boolean = false;
  @State sheetContent: number = 1;  // 1/3/4=RustDesk, 5=protocol picker, 10=VNC Gateway
  @State savedRelayId: string = '';
  @State relayKind: string = 'oss';
  @State editingRelayId: string = '';
  // PC: selected relay object for detail panel (reference change = guaranteed re-render)
  @State selectedPcRelay: RustDeskRelayConfig | null = null;
  @State selectedPcVncGateway: VncGatewayView | null = null;
  // PC popup menu
  @State menuVisibleRelayId: string = '';
  // Relay form
  @State formIdServer: string = '';
  @State formIdPortText: string = '21116';
  @State formRelayServer: string = '';
  @State formRelayPortText: string = '21117';
  @State formApiServer: string = '';
  @State formKey: string = '';
  @State formKeyMode: RustDeskRelayKeyMode = 'server_public_key';
  @State formControlPlaneProfile: RustDeskControlPlaneProfile = RUSTDESK_CONTROL_PLANE_DEFAULT;
  @State showRelayAdvanced: boolean = false;
  @State formTestResult: string = '';
  @State importingRelayConfig: boolean = false;
  @State relaySaving: boolean = false;
  @State relaySaveError: string = '';
  @State relaySaveRecovery: RustDeskRelaySaveRecovery = 'none';
  @State relaySaveDiagnostic: string = '';
  @State relaySaveStage: DataMutationStage = 'idle';
  @State relayCloudSyncState:
    RustDeskRelayCloudSyncState = 'not_configured';
  @State relayCloudFailureKind: string = '';
  @State relayDraftId: string = '';
  @State relaySaveRevision: number = 0;
  // Server Pro account form and local-only account state
  @State proAccounts: RustDeskProAccountState[] = [];
  @State proRelayId: string = '';
  @State proAccountId: string = '';
  @State proCreateNewAccount: boolean = false;
  @State formProServer: string = '';
  @State formProUser: string = '';
  @State formProPwd: string = '';
  @State formProError: string = '';
  @State proBusy: boolean = false;
  @State testingRelayId: string = '';
  @State relaySheetClosing: boolean = false;
  @State relayViewRevision: number = 0;
  @State proViewRevision: number = 0;
  @State vncViewRevision: number = 0;
  @State editingVncGateway: VncGatewayView | null = null;
  @State testingVncGatewayId: string = '';
  @State testingVncGatewayRequestId: number = 0;
  @State vncTestResultId: string = '';
  @State vncTestResult: string = '';
  private pendingHostAddReturnRelayId: string = '';
  private srv: HostSyncService = HostSyncService.getInstance();
  private proSync: RustDeskProSyncService = RustDeskProSyncService.getInstance();
  private vncGatewayService: VncGatewayService = VncGatewayService.getInstance();
  private vncTrustService: VncTrustService = VncTrustService.getInstance();
  private extensionLoader: ExtensionLoader = ExtensionLoader.getInstance();
  private relayImporter: RustDeskRelayImportService = new RustDeskRelayImportService();
  private relaySetup: RustDeskRelaySetupCoordinator =
    RustDeskRelaySetupCoordinator.getInstance();
  private dataUnsubscribe: (() => void) | null = null;
  private proDataUnsubscribe: (() => void) | null = null;
  private vncDataUnsubscribe: (() => void) | null = null;
  private vncDeepBinding: VncDeepCheckBinding | null = null;
  private pendingVncTrustEndpoint: VncTrustEndpoint | null = null;
  private pendingVncTrustFingerprint: string = '';
  private pendingVncTrustBinding: VncDeepCheckBinding | null = null;
  private vncDeepAttemptGeneration: number = 0;
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }
  private font(): string { return AppTheme.fontFamily; }
  private topSafeH(): number { return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH; }
  private titleBarH(): number { return this.topSafeH() + 66; }
  private titleOffsetY(): number { return 8; }
  private contentTopSpacer(): number { return this.titleBarH() + 14; }

  aboutToAppear(): void {
    this.pageActive = true;
    const context = getContext(this) as common.Context;
    this.vncGatewayService.init(context);
    this.vncTrustService.init(context);
    this.proSync.init(getContext(this) as common.Context);
    this.registerDataRefreshListener();
    this.load();
    this.loadProAccounts();
    this.srv.whenReady().then((): void => {
      if (this.pageActive) { this.load(); }
    });
  }
  onPageShow(): void { this.load(); }
  aboutToDisappear(): void {
    this.pageActive = false;
    this.vncDeepAttemptGeneration += 1;
    if (this.testingVncGatewayRequestId > 0) {
      this.extensionLoader.cancelVncGatewayDeep(this.testingVncGatewayRequestId);
      this.testingVncGatewayRequestId = 0;
    }
    this.testingVncGatewayId = '';
    this.vncDeepBinding = null;
    this.vncTestResultId = '';
    this.vncTestResult = '';
    this.pendingVncTrustEndpoint = null;
    this.pendingVncTrustFingerprint = '';
    this.pendingVncTrustBinding = null;
    if (this.dataUnsubscribe) {
      this.dataUnsubscribe();
      this.dataUnsubscribe = null;
    }
    if (this.proDataUnsubscribe) {
      this.proDataUnsubscribe();
      this.proDataUnsubscribe = null;
    }
    if (this.vncDataUnsubscribe) {
      this.vncDataUnsubscribe();
      this.vncDataUnsubscribe = null;
    }
  }
  private registerDataRefreshListener(): void {
    if (!this.dataUnsubscribe) {
      this.dataUnsubscribe = this.srv.onDataChange((): void => {
        this.load();
        this.loadProAccounts();
      });
    }
    if (!this.proDataUnsubscribe) {
      this.proDataUnsubscribe = this.proSync.onDataChange((): void => {
        if (this.pageActive) { this.loadProAccounts(); }
      });
    }
    if (!this.vncDataUnsubscribe) {
      this.vncDataUnsubscribe = this.vncGatewayService.onChange((): void => {
        this.invalidateVncDeepCheck();
        if (this.pageActive) { this.loadVncGateways(); }
      });
    }
  }
  private load(): void {
    const selectedRelayId = this.selectedPcRelay ? this.selectedPcRelay.id : '';
    const nextRelays = this.srv.getAllRelays().map((relay: RustDeskRelayConfig): RustDeskRelayConfig =>
      RustDeskRelayConfig.fromJSON(relay.toJSON()));
    this.relays = nextRelays;
    this.relayViewRevision += 1;
    if (selectedRelayId !== '') {
      this.selectedPcRelay = snapshotSelectedRelay(nextRelays, selectedRelayId);
    }
    this.loadVncGateways();
  }

  private loadVncGateways(): void {
    const selectedGatewayId: string = this.selectedPcVncGateway ? this.selectedPcVncGateway.id : '';
    this.vncGateways = this.vncGatewayService.list().map((gateway: VncGatewayView): VncGatewayView => ({
      id: gateway.id, userId: gateway.userId, label: gateway.label, transport: gateway.transport,
      host: gateway.host, port: gateway.port, path: gateway.path, repeaterMode: gateway.repeaterMode,
      targetId: gateway.targetId, tls: gateway.tls, enabled: gateway.enabled,
      createdAt: gateway.createdAt, updatedAt: gateway.updatedAt, syncVersion: gateway.syncVersion,
      tokenConfigured: gateway.tokenConfigured
    }));
    this.vncViewRevision += 1;
    if (selectedGatewayId !== '') {
      const next: VncGatewayView | undefined = this.vncGateways.find(
        (gateway: VncGatewayView): boolean => gateway.id === selectedGatewayId);
      this.selectedPcVncGateway = next === undefined ? null : next;
    }
  }
  private loadProAccounts(): void {
    this.proAccounts = this.proSync.getAccounts();
    this.proViewRevision += 1;
  }
  onAddTrigger(): void {
    if (this.addTrigger > 0) { this.openAddRelaySheet(); }
  }

  onRustDeskAddTrigger(): void {
    if (this.rustDeskAddTrigger > 0) { this.openRustDeskRelaySheet(); }
  }

  onVncAddTrigger(): void {
    if (this.vncAddTrigger > 0) { this.openVncGatewaySheet(); }
  }

  // ==================== Stats ====================

  private onlineCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { if (r.healthStatus === 'online') { c++; } });
    return c;
  }
  private errorCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { if (r.healthStatus === 'offline' || r.healthStatus === 'error') { c++; } });
    return c;
  }
  private totalAccountCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { c += this.accountCountForRelay(r.id); });
    return c;
  }
  private totalHostCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { c += this.hostCountForRelay(r.id); });
    return c;
  }
  private totalRelayCount(): number {
    return this.relays.length + this.vncGateways.length;
  }

  // ==================== Expand / Collapse ====================

  private isRelayExpanded(id: string): boolean { return this.expandedRelayIds.includes(id); }
  private toggleRelayExpanded(id: string): void {
    animateTo({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) }, () => {
      if (this.isRelayExpanded(id)) {
        this.expandedRelayIds = this.expandedRelayIds.filter((relayId: string): boolean => relayId !== id);
      } else {
        const ids: string[] = this.expandedRelayIds.slice();
        ids.push(id);
        this.expandedRelayIds = ids;
      }
    });
  }

  // ==================== Status helpers ====================

  private relayStatusColor(relay: RustDeskRelayConfig): string {
    if (relay.healthStatus === 'online') { return this.pal().success; }
    if (relay.healthStatus === 'offline' || relay.healthStatus === 'error') { return this.pal().danger; }
    return this.pal().text3;
  }

  private relayStatusLabel(relay: RustDeskRelayConfig): string {
    if (this.testingRelayId === relay.id) { return '检测中'; }
    if (relay.healthStatus === 'online') {
      return relay.healthLatency > 0 ? '在线 · ' + relay.healthLatency + 'ms' : '在线';
    }
    if (relay.healthStatus === 'offline') { return '离线'; }
    if (relay.healthStatus === 'error') { return '异常'; }
    return '未检测';
  }

  private relayKindForProfile(profile: RustDeskControlPlaneProfile): string {
    if (profile === 'official_server_pro_token') { return 'pro'; }
    if (profile === 'third_party_control_plane' ||
      profile === 'third_party_api_only') { return 'advanced'; }
    return 'oss';
  }

  private relayCheckedAtLabel(relay: RustDeskRelayConfig): string {
    if (relay.healthCheckedAt <= 0) { return ''; }
    const diff: number = Date.now() - relay.healthCheckedAt;
    if (diff < 60000) { return '刚刚'; }
    if (diff < 3600000) { return Math.floor(diff / 60000) + '分钟前'; }
    if (diff < 86400000) { return Math.floor(diff / 3600000) + '小时前'; }
    return Math.floor(diff / 86400000) + '天前';
  }

  private vncGatewayStatusLabel(gateway: VncGatewayView): string {
    if (!gateway.enabled) { return '已停用'; }
    if (this.testingVncGatewayId === gateway.id) { return '检测中'; }
    const availability = vncGatewayAvailability(gateway.transport, gateway.tls,
      gateway.tokenConfigured, gateway.repeaterMode);
    if (!availability.enabled) { return '不可用'; }
    if (this.vncTestResultId === gateway.id && this.vncTestResult.startsWith('✓')) {
      return this.vncTestResult;
    }
    if (this.vncTestResultId === gateway.id && this.vncTestResult.startsWith('✗')) {
      return '端口异常';
    }
    return '未检测 · 协议未验证';
  }

  private vncGatewayStatusColor(gateway: VncGatewayView): string {
    if (!gateway.enabled) { return this.pal().text3; }
    const availability = vncGatewayAvailability(gateway.transport, gateway.tls,
      gateway.tokenConfigured, gateway.repeaterMode);
    if (!availability.enabled) { return this.pal().danger; }
    if (this.vncTestResultId === gateway.id && this.vncTestResult.startsWith('✓')) {
      return this.pal().success;
    }
    if (this.vncTestResultId === gateway.id && this.vncTestResult.startsWith('✗')) {
      return this.pal().danger;
    }
    return this.pal().text3;
  }

  private gatewayAvailability(gateway: VncGatewayView) {
    return vncGatewayAvailability(gateway.transport, gateway.tls,
      gateway.tokenConfigured, gateway.repeaterMode);
  }

  private redactedVncTarget(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 4) { return normalized === '' ? '未填写' : '•••'; }
    return normalized.substring(0, 2) + '…' + normalized.substring(normalized.length - 2);
  }

  private hostCountForRelay(relayId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId) { count++; }
    });
    return count;
  }

  private hostCountForAccount(relayId: string, accountId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId && h.rustdeskAccountId === accountId) { count++; }
    });
    return count;
  }

  private accountCountForRelay(relayId: string): number {
    return this.proAccountsForRelay(relayId).length;
  }

  // ==================== Sheet openers ====================

  private openAddRelaySheet(): void {
    if (this.relaySheetClosing) { return; }
    this.resetRelayForm();
    this.relayKind = 'oss';
    // Keep the released RustDesk entry contract while exposing VNC as a
    // separate add action. The directory itself has no protocol filter.
    this.sheetContent = 5;
    this.showSheet = true;
  }

  private openRustDeskRelaySheet(): void {
    if (this.relaySheetClosing) { return; }
    this.resetRelayForm();
    this.relayKind = 'oss';
    this.sheetContent = 1;
    this.showSheet = true;
  }

  private openVncGatewaySheet(): void {
    if (this.relaySheetClosing) { return; }
    this.editingVncGateway = null;
    this.sheetContent = 10;
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.relaySheetClosing = true;
    this.showSheet = false;
  }

  private finishSheetDismiss(): void {
    const returnToHostAdd: boolean =
      this.returnToHostAdd;
    const returnRelayId: string =
      this.pendingHostAddReturnRelayId;
    this.pendingHostAddReturnRelayId = '';
    this.relaySheetClosing = false;
    this.sheetContent = 1;
    this.resetRelayForm();
    this.proRelayId = '';
    this.proAccountId = '';
    this.proCreateNewAccount = false;
    this.formProServer = '';
    this.formProUser = '';
    this.formProPwd = '';
    this.formProError = '';
    this.proBusy = false;
    this.savedRelayId = '';
    this.editingVncGateway = null;
    this.testingVncGatewayId = '';
    this.vncTestResultId = '';
    this.vncTestResult = '';
    this.load();
    this.loadProAccounts();
    if (returnToHostAdd) {
      this.onReturnToHostAdd(returnRelayId);
    }
  }

  private openEditRelaySheet(relay: RustDeskRelayConfig): void {
    if (this.relaySheetClosing) { return; }
    this.menuVisibleRelayId = '';
    this.editingRelayId = relay.id;
    this.relayDraftId = relay.id;
    this.formIdServer = relay.idServer;
    this.formIdPortText = relay.idServerPort.toString();
    this.formRelayServer = relay.relayServer;
    this.formRelayPortText = relay.relayPort.toString();
    this.formApiServer = relay.apiServer;
    this.formKey = relay.key;
    this.formKeyMode = resolveRustDeskRelayKey(relay.key, relay.keyMode, false).mode;
    this.formControlPlaneProfile = relay.controlPlaneProfile;
    this.relayKind = this.relayKindForProfile(relay.controlPlaneProfile);
    this.showRelayAdvanced = true;
    this.formTestResult = '';
    this.relaySaveError = '';
    this.relaySaveRecovery = 'none';
    this.relaySaveDiagnostic = '';
    this.relaySaving = false;
    this.relaySaveStage = 'idle';
    this.relayCloudSyncState = 'not_configured';
    this.relayCloudFailureKind = '';
    this.sheetContent = 1;
    this.showSheet = true;
  }

  private openEditVncGatewaySheet(gateway: VncGatewayView): void {
    if (this.relaySheetClosing) { return; }
    this.editingVncGateway = gateway;
    this.sheetContent = 10;
    this.showSheet = true;
  }


  private proAccountsForRelay(relayId: string): RustDeskProAccountState[] {
    return this.proAccounts.filter((account: RustDeskProAccountState): boolean => account.relayId === relayId);
  }

  private preferredProAccountForRelay(relayId: string): RustDeskProAccountState | undefined {
    const accounts = this.proAccountsForRelay(relayId);
    if (accounts.length === 0) { return undefined; }
    let preferred = accounts[0];
    for (let i = 1; i < accounts.length; i++) {
      const candidate = accounts[i];
      if (candidate.lastLoginAt > preferred.lastLoginAt ||
        (candidate.lastLoginAt === preferred.lastLoginAt && candidate.lastSyncAt > preferred.lastSyncAt)) {
        preferred = candidate;
      }
    }
    return preferred;
  }

  private proStatusLabel(account: RustDeskProAccountState): string {
    if (account.loginStatus === 'logged_in') { return '已登录'; }
    if (account.loginStatus === 'expired') { return '登录过期'; }
    return '未登录';
  }

  private proStatusColor(account: RustDeskProAccountState): string {
    if (account.loginStatus === 'logged_in') { return this.pal().success; }
    if (account.loginStatus === 'expired') { return this.pal().danger; }
    return this.pal().text3;
  }

  private openProAccountSheet(relay: RustDeskRelayConfig, account?: RustDeskProAccountState): void {
    if (this.relaySheetClosing) { return; }
    // A relay normally has one Pro identity.  The compact header used to
    // open a fresh account every time, leaving the first endpoint/token in
    // the credential store and making later syncs look stale.  Reuse the
    // existing account when the caller did not provide one explicitly.
    const storedAccount = account ?? this.preferredProAccountForRelay(relay.id);
    this.proRelayId = relay.id;
    this.proAccountId = storedAccount ? storedAccount.id : '';
    this.proCreateNewAccount = false;
    this.formProServer = storedAccount ? storedAccount.serverUrl : relay.apiServer;
    this.formProUser = storedAccount ? storedAccount.username : '';
    this.formProPwd = '';
    this.formProError = '';
    this.proBusy = false;
    this.sheetContent = 3;
    this.showSheet = true;
  }

  private openNewProAccountSheet(relay: RustDeskRelayConfig): void {
    if (this.relaySheetClosing) { return; }
    this.proRelayId = relay.id;
    this.proAccountId = '';
    this.proCreateNewAccount = true;
    this.formProServer = relay.apiServer;
    this.formProUser = '';
    this.formProPwd = '';
    this.formProError = '';
    this.proBusy = false;
    this.sheetContent = 3;
    this.showSheet = true;
  }

  private proSyncToastResult(
    accountId: string,
    count: number,
    loginFlow: boolean
  ): ProSyncToastResult {
    const status = this.proSync.getConnectionCapabilityStatus(accountId);
    if (status !== undefined && status.tokenProjected) {
      return {
        capabilityReady: true,
        message: loginFlow
          ? (count > 0
            ? 'Pro 已同步 ' + count.toString() + ' 台设备，控制面绑定校验通过'
            : '登录成功，地址簿为空；控制面绑定校验通过')
          : (count > 0
            ? 'Pro 已同步 ' + count.toString() + ' 台设备，控制面绑定校验通过'
            : '同步完成，控制面绑定校验通过')
      };
    }
    if (status !== undefined && !status.requiresAccount) {
      return {
        capabilityReady: false,
        message: '地址簿同步成功；当前连接配置为' +
          rustDeskControlPlaneProfileLabel(status.profile) +
          '，仅使用地址簿 HTTP 会话，不向控制面发送地址簿令牌'
      };
    }
    return {
      capabilityReady: false,
      message: '地址簿同步成功；控制面绑定尚未满足，连接不会发送地址簿令牌。' +
        '请检查账号、API、ID/Relay 端点和服务器 Key 是否属于同一部署'
    };
  }

  // ==================== Relay CRUD ====================

  private resetRelayForm(): void {
    this.editingRelayId = ''; this.formIdServer = ''; this.formIdPortText = '21116';
    this.formRelayServer = ''; this.formRelayPortText = '21117';
    this.formApiServer = ''; this.formKey = ''; this.formKeyMode = 'server_public_key';
    this.formControlPlaneProfile = RUSTDESK_CONTROL_PLANE_DEFAULT; this.formTestResult = '';
    this.showRelayAdvanced = false;
    this.relayDraftId = this.relaySetup.nextDraftId();
    this.relaySaving = false; this.relaySaveError = ''; this.relaySaveRecovery = 'none';
    this.relaySaveDiagnostic = ''; this.relaySaveStage = 'idle';
    this.relayCloudSyncState = 'not_configured';
    this.relayCloudFailureKind = '';
  }

  private relayPortFromText(value: string, defaultPort: number): number {
    const normalized: string = value.trim();
    if (normalized === '') { return defaultPort; }
    const port: number = Number(normalized);
    return Number.isInteger(port) ? port : 0;
  }

  private async doSaveRelay(): Promise<void> {
    if (this.relaySaving) { return; }
    this.relaySaveError = '';
    this.relaySaveRecovery = 'none';
    const isNew: boolean = this.editingRelayId === '';
    const draft = new RustDeskRelaySetupDraft();
    draft.operation = isNew ? 'create' : 'update';
    draft.editingRelayId =
      isNew ? '' : this.editingRelayId;
    draft.relayId = isNew ? this.relayDraftId : this.editingRelayId;
    draft.idServer = this.formIdServer;
    draft.idServerPort = this.relayPortFromText(this.formIdPortText, 21116);
    draft.relayServer = this.formRelayServer;
    draft.relayPort = this.relayPortFromText(this.formRelayPortText, 21117);
    draft.apiServer = this.formApiServer;
    draft.key = this.formKey;
    draft.keyMode = this.formKeyMode;
    draft.controlPlaneProfile = this.formControlPlaneProfile;
    this.relaySaveRevision++;
    const attemptId: string = 'relay-save-' + Date.now().toString(36) + '-' +
      this.relaySaveRevision.toString(36);
    const existing: RustDeskRelayConfig | null = isNew ? null :
      (this.relays.find((x: RustDeskRelayConfig): boolean =>
        x.id === this.editingRelayId) ?? null);
    this.relaySaving = true;
    this.relaySaveStage = 'validating';
    const result: RustDeskRelaySaveResult =
      await this.relaySetup.saveAsync(
        draft, existing, attemptId,
        (stage: DataMutationStage): void => {
          this.relaySaveStage = stage;
        },
        (state: RustDeskRelayCloudSyncState,
          failureKind: string): void => {
          this.relayCloudSyncState = state;
          this.relayCloudFailureKind =
            state === 'failed' ? failureKind : '';
          this.relaySaveDiagnostic =
            'attempt=' + attemptId +
            ' stage=completed code=ok committed=true cloud=' +
            state +
            (failureKind === ''
              ? '' : ' cloud_failure=' + failureKind);
        });
    this.relaySaving = false;
    this.relayDraftId = draft.relayId;
    this.relaySaveDiagnostic = result.diagnosticSummary();
    if (!result.ok) {
      this.relaySaveError = result.message;
      this.relaySaveRecovery = result.recovery;
      if (result.localCommitted) { this.load(); }
      return;
    }
    this.relaySaveStage = 'completed';
    this.relayCloudSyncState = result.cloudSyncState;
    this.relayCloudFailureKind =
      result.cloudSyncFailureKind;
    this.load();
    this.savedRelayId = result.relayId;
    if (this.returnToHostAdd) {
      this.pendingHostAddReturnRelayId =
        result.relayId;
      this.closeSheet();
      return;
    }
    this.sheetContent = 4;
  }

  private async retryRelayCloudSync(): Promise<void> {
    this.relayCloudSyncState = 'pending';
    this.relayCloudFailureKind = '';
    const outcome: RustDeskRelayCloudSyncOutcome =
      await this.srv.retryRelayCloudSync();
    this.relayCloudSyncState = outcome.state;
    this.relayCloudFailureKind = outcome.failureKind;
    this.relaySaveDiagnostic =
      this.relaySaveDiagnostic.replace(
        /cloud=[^ ]+/, 'cloud=' + outcome.state) +
      (outcome.failureKind === ''
        ? '' : ' cloud_failure=' + outcome.failureKind);
  }

  private applyRelayImport(result: RustDeskRelayImportResult): void {
    this.formIdServer = result.idServer; this.formIdPortText = result.idServerPort.toString();
    this.formRelayServer = result.relayServer; this.formRelayPortText = result.relayPort.toString();
    this.formApiServer = result.apiServer; this.formKey = result.key;
    this.formKeyMode = resolveRustDeskRelayKey(result.key, 'auto', false).mode;
    this.showRelayAdvanced = result.apiServer !== '' ||
      result.idServerPort !== 21116 || result.relayPort !== 21117 ||
      result.relayServer !== result.idServer || this.formKeyMode === 'shared_access_key';
  }

  private importAndSavePastedRelay(result: RustDeskRelayImportResult): string {
    this.applyRelayImport(result);
    this.sheetContent = 1;
    return '';
  }

  private async importRelayConfig(): Promise<void> {
    if (this.importingRelayConfig) { return; }
    this.importingRelayConfig = true;
    const result: RustDeskRelayImportResult | null = await this.relayImporter.pickAndParse();
    this.importingRelayConfig = false;
    if (result === null) { return; }
    if (!result.ok) {
      promptAction.showToast({ message: result.error, duration: 2400 });
      return;
    }
    this.applyRelayImport(result);
    this.formTestResult = '✓ 已导入 ' + result.fileName + '，请确认后保存';
  }

  // TCP socket 连通性测试
  private async tcpTest(host: string, port: number): Promise<TcpTestResult> {
    const start = Date.now();
    const result: TcpTestResult = new TcpTestResult();
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      const addr: socket.NetAddress = { address: host, port: port, family: 1 };
      await tcp.connect({ address: addr, timeout: 5000 });
      result.ok = true;
      result.lat = Date.now() - start;
    } catch (_e) {
      result.ok = false;
      result.lat = 0;
    }
    try { tcp?.close(); } catch (_e2) { /* ignore */ }
    return result;
  }

  private async doTestRelay(relay: RustDeskRelayConfig): Promise<void> {
    const target = RustDeskRelayConfig.fromJSON(relay.toJSON());
    this.testingRelayId = target.id;
    const relayId: string =
      rustDeskRelayIdFingerprint(target.id);
    hilog.info(0x0001, 'RustDeskRelay',
      'health test start relayId=' + relayId +
      ' relayEndpoint=configured');
    target.healthStatus = 'unknown';
    const pendingSaved = this.srv.updateRelay(target);
    hilog.info(0x0001, 'RustDeskRelay', 'health test pending saved=' + pendingSaved.toString());
    this.load();
    try {
      const r1 = await this.tcpTest(target.relayServer, target.relayPort);
      if (r1.ok) {
        target.healthStatus = 'online';
        target.healthLatency = r1.lat;
      } else {
        const r2 = await this.tcpTest(target.idServer, target.idServerPort);
        if (r2.ok) {
          target.healthStatus = 'error';
          target.healthLatency = r2.lat;
        } else {
          target.healthStatus = 'offline';
          target.healthLatency = 0;
        }
      }
      target.healthCheckedAt = Date.now();
      const saved = this.srv.updateRelay(target);
      hilog.info(0x0001, 'RustDeskRelay', 'health test result relayId=' + relayId +
        ' status=' + target.healthStatus + ' latency=' + target.healthLatency.toString() +
        ' saved=' + saved.toString());
      this.load();
    } finally {
      this.testingRelayId = '';
    }
  }

  // ==================== VNC Gateway owner ====================

  private saveVncGateway(values: VncGatewayValues, id: string, accessToken: string,
    plainStorageConfirmed: boolean = false): void {
    if (!this.vncGatewayService.isReady()) {
      promptAction.showToast({ message: 'VNC 服务尚未完成云同步初始化，请稍后重试', duration: 2200 });
      return;
    }
    const result = this.vncGatewayService.save(values, id, accessToken, plainStorageConfirmed);
    if (!result.ok) {
      promptAction.showToast({ message: result.message || 'VNC Gateway 保存失败', duration: 2400 });
      return;
    }
    this.loadVncGateways();
    promptAction.showToast({ message: id === '' ? 'VNC Gateway 已保存' : 'VNC Gateway 已更新', duration: 1800 });
    this.closeSheet();
  }

  private doDeleteVncGateway(gateway: VncGatewayView): void {
    promptAction.showDialog({
      title: '删除 VNC Gateway',
      message: '确定删除“' + gateway.label + '”吗？其 VNC 令牌也会一并删除。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const values: Record<string, number> = result as Record<string, number>;
      if (values['index'] === 1 && this.vncGatewayService.remove(gateway.id)) {
        this.vncGateways = this.vncGateways.filter((item: VncGatewayView): boolean => item.id !== gateway.id);
        if (this.selectedPcVncGateway && this.selectedPcVncGateway.id === gateway.id) {
          this.selectedPcVncGateway = null;
        }
        this.vncViewRevision += 1;
      }
    });
  }

  private async doTestVncGateway(gateway: VncGatewayView): Promise<void> {
    const availability = vncGatewayAvailability(gateway.transport, gateway.tls,
      gateway.tokenConfigured, gateway.repeaterMode);
    if (!availability.enabled) {
      this.vncTestResultId = gateway.id;
      this.vncTestResult = '✗ ' + availability.message;
      return;
    }
    this.testingVncGatewayId = gateway.id;
    this.vncTestResultId = gateway.id;
    this.vncTestResult = '⏳ TCP 端口检测中…';
    const result = await this.tcpTest(gateway.host, gateway.port);
    if (result.ok) {
      const health: VncGatewayHealthResult = classifyVncGatewayHealth({
        transport: gateway.transport,
        enabled: gateway.enabled,
        repeaterMode: gateway.repeaterMode,
        target: gateway.targetId,
        tcpReachable: true,
        tlsRequired: gateway.tls,
        certificateConfirmed: false,
        pinMatched: false,
        repeaterBannerOk: false,
        targetPaired: false,
        rfbBannerReady: false,
        deepCheckAttempted: false,
        errorCode: ''
      });
      this.vncTestResult = '✓ ' + health.message + ' (' + result.lat.toString() + 'ms)';
    } else {
      const health: VncGatewayHealthResult = classifyVncGatewayHealth({
        transport: gateway.transport,
        enabled: gateway.enabled,
        repeaterMode: gateway.repeaterMode,
        target: gateway.targetId,
        tcpReachable: false,
        tlsRequired: gateway.tls,
        certificateConfirmed: false,
        pinMatched: false,
        repeaterBannerOk: false,
        targetPaired: false,
        rfbBannerReady: false,
        deepCheckAttempted: false,
        errorCode: 'E-VNC-GATEWAY-TCP'
      });
      this.vncTestResult = '✗ ' + health.message;
    }
    this.testingVncGatewayId = '';
  }

  /** Resolve the exact gateway endpoint used by trust and native deep checks. */
  private resolveVncGatewayEndpoint(gateway: VncGatewayView): VncTlsEndpointResolution {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const store: string = vncStoreIdentityFingerprint(scope.storeIdentity);
    const hostValues: VncHostValues = {
      label: gateway.label,
      host: gateway.host,
      port: gateway.port,
      username: '',
      gatewayId: gateway.id,
      transport: 'ultravnc_repeater',
      repeaterMode: 'mode12',
      rememberPassword: false,
      viewOnly: false,
      displayOverrideEnabled: false,
      scalingMode: 'fit',
      clipboardEnabled: false,
      securityPolicy: gateway.tls ? 'secure_only' : 'trusted_network',
      tls: gateway.tls,
      locked: false,
      lockType: 0
    };
    return resolveVncTlsEndpoint(
      vncTlsHostInput(gateway.id, scope.ownerScopeId, hostValues, gateway.targetId, store),
      vncTlsGatewayInput(gateway.id, scope.ownerScopeId, gateway, store));
  }

  private sameVncDeepBinding(left: VncDeepCheckBinding | null,
    right: VncDeepCheckBinding | null): boolean {
    if (left === null || right === null) { return false; }
    return left.gatewayId === right.gatewayId && left.ownerId === right.ownerId &&
      left.userId === right.userId && left.storeIdentityFingerprint === right.storeIdentityFingerprint &&
      left.endpointBindingFingerprint === right.endpointBindingFingerprint &&
      left.accountGeneration === right.accountGeneration && left.tlsRequired === right.tlsRequired &&
      left.enabled === right.enabled && left.repeaterTarget === right.repeaterTarget;
  }

  private deepBindingStillCurrent(binding: VncDeepCheckBinding): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (scope.ownerScopeId !== binding.userId || scope.generation !== binding.accountGeneration) {
      return false;
    }
    const store = vncStoreIdentityFingerprint(scope.storeIdentity);
    if (store !== binding.storeIdentityFingerprint) { return false; }
    const gateway = this.vncGatewayService.find(binding.gatewayId);
    if (gateway === null || gateway.userId !== binding.userId || gateway.enabled !== binding.enabled ||
      gateway.tls !== binding.tlsRequired || gateway.targetId !== binding.repeaterTarget) { return false; }
    const endpoint = this.resolveVncGatewayEndpoint(gateway);
    return endpoint.ok && endpoint.endpointBindingFingerprint === binding.endpointBindingFingerprint;
  }

  private invalidateVncDeepCheck(): void {
    const binding = this.vncDeepBinding === null ? this.pendingVncTrustBinding : this.vncDeepBinding;
    if (binding === null || this.deepBindingStillCurrent(binding)) { return; }
    this.vncDeepAttemptGeneration += 1;
    if (this.testingVncGatewayRequestId > 0) {
      this.extensionLoader.cancelVncGatewayDeep(this.testingVncGatewayRequestId);
    }
    this.testingVncGatewayRequestId = 0;
    this.testingVncGatewayId = '';
    this.vncDeepBinding = null;
    this.pendingVncTrustBinding = null;
    this.pendingVncTrustEndpoint = null;
    this.pendingVncTrustFingerprint = '';
    this.vncTestResultId = binding.gatewayId;
    this.vncTestResult = '✗ E-VNC-GATEWAY-BINDING · 账号、存储或端点已变化，请重新检查';
  }

  private async doDeepTestVncGateway(gateway: VncGatewayView): Promise<void> {
    const availability = vncGatewayAvailability(gateway.transport, gateway.tls,
      gateway.tokenConfigured, gateway.repeaterMode);
    if (!availability.enabled) {
      this.vncTestResultId = gateway.id;
      this.vncTestResult = '✗ ' + availability.message;
      return;
    }
    const endpoint = this.resolveVncGatewayEndpoint(gateway);
    if (!endpoint.ok || endpoint.trustOwner === null) {
      this.vncTestResultId = gateway.id;
      this.vncTestResult = '✗ ' + (endpoint.errorCode || 'E-VNC-ENDPOINT-INVALID');
      return;
    }
    const trustEndpoint: VncTrustEndpoint = {
      ownerType: endpoint.trustOwner.ownerType,
      ownerId: endpoint.trustOwner.ownerId,
      userId: endpoint.trustOwner.userId,
      storeIdentityFingerprint: endpoint.trustOwner.storeIdentityFingerprint,
      endpointBindingFingerprint: endpoint.trustOwner.endpointBindingFingerprint,
      localOnly: endpoint.trustOwner.localOnly
    };
    const expectedFingerprint: string = gateway.tls
      ? this.vncTrustService.trustedFingerprintForEndpoint(trustEndpoint) : '';
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const binding: VncDeepCheckBinding = {
      gatewayId: gateway.id,
      ownerId: endpoint.trustOwner.ownerId,
      userId: endpoint.trustOwner.userId,
      storeIdentityFingerprint: endpoint.trustOwner.storeIdentityFingerprint,
      endpointBindingFingerprint: endpoint.trustOwner.endpointBindingFingerprint,
      accountGeneration: scope.generation,
      tlsRequired: endpoint.tlsRequired,
      enabled: gateway.enabled,
      repeaterTarget: endpoint.repeaterTarget
    };
    if (!this.deepBindingStillCurrent(binding)) {
      this.vncTestResultId = gateway.id;
      this.vncTestResult = '✗ E-VNC-GATEWAY-BINDING · 当前 Gateway 已变化';
      return;
    }
    this.pendingVncTrustEndpoint = null;
    this.pendingVncTrustFingerprint = '';
    this.pendingVncTrustBinding = null;
    this.vncDeepBinding = binding;
    const attemptGeneration: number = ++this.vncDeepAttemptGeneration;
    this.testingVncGatewayId = gateway.id;
    this.vncTestResultId = gateway.id;
    this.vncTestResult = '⏳ VNC 深度协议检查中…';
    let requestId: number = 0;
    try {
      const probe = this.extensionLoader.probeVncGatewayDeepAsync(
        endpoint.connectHost, endpoint.connectPort, endpoint.transport,
        gateway.repeaterMode, endpoint.repeaterTarget, endpoint.tlsRequired,
        expectedFingerprint, 10000, endpoint.trustOwner.ownerType, endpoint.trustOwner.ownerId,
        endpoint.trustOwner.userId, endpoint.trustOwner.storeIdentityFingerprint,
        endpoint.trustOwner.endpointBindingFingerprint, scope.generation, gateway.enabled);
      requestId = probe.requestId;
      this.testingVncGatewayRequestId = requestId;
      const result = await probe;
      if (!this.pageActive || this.vncDeepAttemptGeneration !== attemptGeneration ||
        this.testingVncGatewayRequestId !== requestId || this.vncTestResultId !== gateway.id ||
        !this.sameVncDeepBinding(this.vncDeepBinding, binding) ||
        !this.deepBindingStillCurrent(binding) || result.ownerId !== binding.ownerId ||
        result.userId !== binding.userId || result.storeIdentityFingerprint !== binding.storeIdentityFingerprint ||
        result.endpointBindingFingerprint !== binding.endpointBindingFingerprint ||
        result.accountGeneration !== binding.accountGeneration) {
        return;
      }
      if (result.code === 'E-VNC-CERT-TRUST-REQUIRED' || result.code === 'E-VNC-CERT-CHANGED') {
        this.pendingVncTrustEndpoint = trustEndpoint;
        this.pendingVncTrustFingerprint = result.certificateFingerprintSha256;
        this.pendingVncTrustBinding = binding;
        this.vncTestResult = '✗ ' + result.code + ' · 请在证书信任 Sheet 中确认当前指纹';
        if (result.certificateFingerprintSha256 !== '') {
          this.sheetContent = 11;
          this.showSheet = true;
        }
        return;
      }
      this.vncTestResult = result.protocolReady
        ? '✓ ' + result.message
        : '✗ ' + result.code + (result.message === '' ? '' : ' · ' + result.message);
    } catch (_error) {
      if (this.pageActive && this.vncDeepAttemptGeneration === attemptGeneration &&
        this.testingVncGatewayRequestId === requestId && this.vncTestResultId === gateway.id) {
        this.vncTestResult = '✗ E-VNC-GATEWAY-DEEP · 深度检查失败';
      }
    } finally {
      if (this.vncDeepAttemptGeneration === attemptGeneration &&
        this.testingVncGatewayRequestId === requestId &&
        this.vncTestResultId === gateway.id && this.sameVncDeepBinding(this.vncDeepBinding, binding)) {
        this.testingVncGatewayRequestId = 0;
        this.testingVncGatewayId = '';
        this.vncDeepBinding = null;
      }
    }
  }

  private cancelDeepTestVncGateway(): void {
    if (this.testingVncGatewayRequestId <= 0) { return; }
    const requestId: number = this.testingVncGatewayRequestId;
    this.vncDeepAttemptGeneration += 1;
    this.extensionLoader.cancelVncGatewayDeep(requestId);
    this.testingVncGatewayRequestId = 0;
    this.testingVncGatewayId = '';
    this.vncDeepBinding = null;
    this.vncTestResult = '⏳ 正在取消 VNC 深度检查…';
  }

  private canConfirmPendingVncTrust(): boolean {
    const binding = this.pendingVncTrustBinding;
    const pending = this.pendingVncTrustEndpoint;
    if (binding === null || pending === null || this.pendingVncTrustFingerprint === '') { return false; }
    if (!this.deepBindingStillCurrent(binding)) {
      this.pendingVncTrustBinding = null;
      this.pendingVncTrustEndpoint = null;
      this.pendingVncTrustFingerprint = '';
      this.vncTestResult = '✗ E-VNC-GATEWAY-BINDING · endpoint 已变化，请重新检查';
      return false;
    }
    const gateway = this.vncGatewayService.find(binding.gatewayId);
    if (gateway === null) { return false; }
    const endpoint = this.resolveVncGatewayEndpoint(gateway);
    const owner = endpoint.trustOwner;
    if (!endpoint.ok || owner === null || owner.endpointBindingFingerprint !== binding.endpointBindingFingerprint ||
      owner.storeIdentityFingerprint !== pending.storeIdentityFingerprint || owner.userId !== pending.userId ||
      owner.ownerId !== pending.ownerId || owner.ownerType !== pending.ownerType) {
      this.pendingVncTrustBinding = null;
      this.pendingVncTrustEndpoint = null;
      this.pendingVncTrustFingerprint = '';
      this.vncTestResult = '✗ E-VNC-GATEWAY-BINDING · endpoint 已变化，请重新检查';
      return false;
    }
    this.pendingVncTrustEndpoint = {
      ownerType: owner.ownerType,
      ownerId: owner.ownerId,
      userId: owner.userId,
      storeIdentityFingerprint: owner.storeIdentityFingerprint,
      endpointBindingFingerprint: owner.endpointBindingFingerprint,
      localOnly: owner.localOnly
    };
    return true;
  }

  private openPendingVncCertificateTrust(): void {
    if (this.pendingVncTrustEndpoint === null || this.pendingVncTrustFingerprint === '') { return; }
    this.sheetContent = 11;
    this.showSheet = true;
  }

  private doDeleteRelay(id: string): void {
    promptAction.showDialog({
      title: '确认删除', message: '确定要删除此中继服务器及其所有账户吗？',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        animateTo({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) }, () => {
          this.srv.removeRelay(id);
          this.expandedRelayIds = this.expandedRelayIds.filter((relayId: string): boolean => relayId !== id);
          this.relays = this.relays.filter((relay: RustDeskRelayConfig): boolean => relay.id !== id);
        });
      }
    });
  }

  private async doProLogin(): Promise<void> {
    const serverUrl = this.formProServer.trim();
    const username = this.formProUser.trim();
    const password = this.formProPwd;
    if (this.proRelayId === '' || serverUrl === '' || username === '' || password === '') {
      this.formProError = '服务器地址、用户名和密码不能为空';
      return;
    }
    this.proBusy = true;
    this.formProError = '';
    this.formProServer = serverUrl;
    this.formProUser = username;
    const existing = this.proCreateNewAccount ? undefined : this.preferredProAccountForRelay(this.proRelayId);
    const accountId = this.proAccountId !== ''
      ? this.proAccountId
      : (existing ? existing.id : 'rdpro_' + Date.now().toString(36));
    try {
      const result = await this.proSync.loginAndSync({
        id: accountId,
        relayId: this.proRelayId,
        serverUrl,
        username,
        password
      });
      this.loadProAccounts();
      this.formProPwd = '';
      const count = result.addedIds.length + result.updatedIds.length;
      const toast = this.proSyncToastResult(accountId, count, true);
      promptAction.showToast({
        message: toast.message,
        duration: toast.capabilityReady ? 2200 : 3600
      });
      this.closeSheet();
    } catch (err) {
      this.formProError = err instanceof Error ? err.message : 'Pro 登录失败';
    } finally {
      this.proBusy = false;
    }
  }

  private async doProSync(accountId: string): Promise<void> {
    try {
      const result = await this.proSync.sync(accountId);
      this.loadProAccounts();
      const count = result.addedIds.length + result.updatedIds.length;
      const toast = this.proSyncToastResult(accountId, count, false);
      promptAction.showToast({
        message: toast.message,
        duration: toast.capabilityReady ? 2200 : 3600
      });
    } catch (err) {
      this.formProError = err instanceof Error ? err.message : 'Pro 同步失败';
      promptAction.showToast({ message: this.formProError, duration: 2200 });
    }
  }

  private async doProLogout(accountId: string): Promise<void> {
    await this.proSync.logout(accountId);
    this.loadProAccounts();
    this.closeSheet();
  }

  // ==================== Layout helpers ====================

  private cardColumns(): number {
    if (this.breakpoint === 'xl') { return this.isDesktopDevice ? 1 : 3; }
    if (this.breakpoint === 'lg') { return 3; }
    if (this.breakpoint === 'md') { return 2; }
    return 1;
  }
  private cardGap(): number { return 10; }
  private gridColumnsTemplate(): string {
    const columns: number = this.cardColumns();
    if (columns >= 4) { return '1fr 1fr 1fr 1fr'; }
    if (columns === 3) { return '1fr 1fr 1fr'; }
    if (columns === 2) { return '1fr 1fr'; }
    return '1fr';
  }
  private contentSidePadding(): number {
    if (this.breakpoint === 'xl') { return 24; }
    if (this.breakpoint === 'lg') { return 22; }
    return 16;
  }

  private isPC(): boolean {
    return this.isDesktopDevice && this.breakpoint === 'xl';
  }

  private relaySheetHeight(): SheetSize { return SheetSize.FIT_CONTENT; }

  private relaySheetKeyboardAvoidMode(): SheetKeyboardAvoidMode {
    return rustDeskRelaySheetUsesResizeOnly(this.sheetContent, this.breakpoint)
      ? SheetKeyboardAvoidMode.RESIZE_ONLY
      : SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL;
  }

  // ==================== Build ====================

  build() {
    Stack() {
      if (this.isPC()) {
        // PC: fixed-height layout — left list + right detail each scroll independently
        Column() {
          Column().height(this.contentTopSpacer())
          if (this.totalRelayCount() > 0) {
            this.statsBar()
          }
          if (this.totalRelayCount() === 0) {
            Column() {
              this.emptyState()
            }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start)
          } else {
            this.pcLayout()
          }
        }
        .width('100%').height('100%')
        .padding({ left: this.contentSidePadding(), right: this.contentSidePadding() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        // Mobile/tablet: scrollable content
        Scroll() {
          Column() {
            Column().height(this.contentTopSpacer())
            if (this.totalRelayCount() > 0) {
              this.statsBar()
            }
            if (this.totalRelayCount() === 0) {
              Column() {
                this.emptyState()
              }.width('100%').alignItems(HorizontalAlign.Start)
            } else {
              if (this.breakpoint === 'sm') {
                this.mobileList()
              } else {
                this.tabletGrid()
              }
            }
            if (this.breakpoint !== 'sm') {
              Column().height(rustDeskRelayDirectoryBottomClearance(this.breakpoint))
            }
          }.width('100%').padding({ left: this.contentSidePadding(), right: this.contentSidePadding() })
        }
        .width('100%').height('100%').align(Alignment.TopStart)
        .scrollBar(this.breakpoint === 'sm' ? BarState.Off : BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .width('100%').height('100%')
    .overlay(this.TitleBarOverlay(), { align: Alignment.Top })
    .bindSheet($$this.showSheet, this.relaySheetBuilder(), {
      height: this.relaySheetHeight(),
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: false,
      keyboardAvoidMode: this.relaySheetKeyboardAvoidMode(),
      backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE, showClose: false,
      onDisappear: () => { this.finishSheetDismiss(); }
    })
  }

  // ==================== Stats Bar ====================

  @Builder statsBar() {
    Scroll() {
      Row() {
        this._statChip('中继', this.totalRelayCount().toString(), this.pal().text)
        this._statChip('在线', this.onlineCount().toString(), this.pal().success)
        this._statChip('异常', this.errorCount().toString(), this.pal().danger)
        this._statChip('账户', this.totalAccountCount().toString(), this.pal().text)
        this._statChip('主机', this.totalHostCount().toString(), this.pal().text)
      }
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    .width('100%').padding({ bottom: 14 }).align(Alignment.Start)
  }

  @Builder _statChip(label: string, value: string, color: string) {
    Row() {
      Text(label).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      Text(value).fontSize(11).fontWeight(FontWeight.Bold).fontColor(color).fontFamily(this.font()).margin({ left: 3 })
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .borderRadius(10)
    .backgroundColor(this.pal().surface)
    .margin({ right: 8 })
  }

  // ==================== Empty State ====================

  @Builder emptyState() {
    Column() {
      SymbolGlyph(protocolIcon('rustdesk_relay'))
        .fontSize(48)
        .fontColor([this.pal().text3])
      Text('还没有中继服务器')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
        .margin({ top: 16 })
      Text('点击底部 + 添加中继服务器')
        .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
        .textAlign(TextAlign.Center).margin({ top: 6 })
        .lineHeight(20)
    }
    .width('100%').constraintSize({ minHeight: 420 })
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  // ==================== Mobile List (swipeAction) ====================

  @Builder mobileList() {
    List() {
      ForEach(this.relays, (relay: RustDeskRelayConfig) => {
        ListItem() {
          this.relayCardContent(relay, false)
        }
        .swipeAction({
          start: {
            builder: () => { this.rightSwipeActions(relay) },
            actionAreaDistance: 100
          },
          end: {
            builder: () => { this.leftSwipeActions(relay) },
            actionAreaDistance: 112
          },
          edgeEffect: SwipeEdgeEffect.Spring
        })
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (relay: RustDeskRelayConfig): string => relay.id + ':' + this.relayViewRevision.toString())
      ForEach(this.vncGateways, (gateway: VncGatewayView) => {
        ListItem() {
          this.vncGatewayCardContent(gateway)
        }
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (gateway: VncGatewayView): string => gateway.id + ':' + this.vncViewRevision.toString())
      ListItem() {
        Column().height(rustDeskRelayDirectoryBottomClearance(this.breakpoint))
      }
    }
    .width('100%')
    .listDirection(Axis.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .divider({ strokeWidth: this.cardGap(), color: Color.Transparent })
  }

  // Right swipe: test + edit (same pattern as KeyVaultPage editLockRow)
  @Builder rightSwipeActions(relay: RustDeskRelayConfig) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.accentColor)
      .onClick(() => { this.doTestRelay(relay); })

      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().editColor)
      .margin({ left: 4 })
      .onClick(() => { this.openEditRelaySheet(relay); })
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // Left swipe: delete — square 60×60 all breakpoints
  @Builder leftSwipeActions(relay: RustDeskRelayConfig) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.accentColor)
      .onClick(() => { void this.doTestRelay(relay); })
      Button() {
        SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().danger)
      .margin({ left: 4 })
      .onClick(() => { this.doDeleteRelay(relay.id); })
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // Legacy single-action builder retained for compatibility with callers.
  @Builder leftSwipeDelete(relay: RustDeskRelayConfig) {
    Column() {
      SymbolGlyph($r('sys.symbol.ohos_trash'))
        .fontSize(24)
        .fontColor([Color.White])
        .symbolEffect(new PulseSymbolEffect(), true)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), true)
      Text('删除')
        .fontSize(9)
        .fontColor(Color.White)
        .margin({ top: 2 })
    }
    .width(60).height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.pal().danger)
    .onClick(() => { this.doDeleteRelay(relay.id); })
  }

  // ==================== Tablet Grid ====================

  @Builder tabletGrid() {
    Grid() {
      ForEach(this.relays, (relay: RustDeskRelayConfig) => {
        GridItem() {
          this.relayCardContent(relay, true)
        }
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (relay: RustDeskRelayConfig): string => relay.id + ':' + this.relayViewRevision.toString())
      ForEach(this.vncGateways, (gateway: VncGatewayView) => {
        GridItem() {
          this.vncGatewayCardContent(gateway)
        }
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (gateway: VncGatewayView): string => gateway.id + ':' + this.vncViewRevision.toString())
    }
    .columnsTemplate(this.gridColumnsTemplate())
    .columnsGap(this.cardGap())
    .rowsGap(this.cardGap())
    .width('100%')
    .align(Alignment.TopStart)
  }

  // ==================== PC Layout (左侧列表 + 右侧详情) ====================

  @Builder pcLayout() {
    Row() {
      // Left: relay list
      Column() {
        List() {
          ForEach(this.relays, (relay: RustDeskRelayConfig) => {
            ListItem() {
              this.pcListItem(relay)
            }
          }, (relay: RustDeskRelayConfig): string => relay.id + ':' + this.relayViewRevision.toString())
          ForEach(this.vncGateways, (gateway: VncGatewayView) => {
            ListItem() {
              this.pcVncGatewayListItem(gateway)
            }
          }, (gateway: VncGatewayView): string => gateway.id + ':' + this.vncViewRevision.toString())
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .divider({ strokeWidth: 4, color: Color.Transparent })
      }
      .width(300).padding({ right: 12 })

      // Right: detail panel — card with explicit height constraint
      Column() {
        if (this.selectedPcRelay !== null) {
          ForEach([(this.selectedPcRelay as RustDeskRelayConfig).id], (id: string) => {
            Column() {
              this.pcDetailPanelContent()
            }
            .width('100%').height('100%')
            .borderRadius(20).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.10)', offsetY: 8 })
            .transition(
              TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })
                  .animation({ duration: 280, curve: Curve.FastOutSlowIn }))
            )
          }, (id: string): string => id)
        } else if (this.selectedPcVncGateway !== null) {
          ForEach([(this.selectedPcVncGateway as VncGatewayView).id], (id: string) => {
            Column() {
              this.vncGatewayDetailPanelContent()
            }
            .width('100%').height('100%')
            .borderRadius(20).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.10)', offsetY: 8 })
          }, (id: string): string => id)
        } else {
          Column() {
            SymbolGlyph(protocolIcon('rustdesk_relay'))
              .fontSize(36).fontColor([this.pal().text3])
            Text('选择一个服务器').fontSize(14).fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 8 })
            Text('查看详细信息').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
          }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        }
      }.layoutWeight(1).height('100%')
    }.width('100%').layoutWeight(1).constraintSize({ minHeight: 420 })
  }

  @Builder pcListItem(relay: RustDeskRelayConfig) {
    Row() {
      SymbolGlyph(protocolIcon('rustdesk_relay'))
        .fontSize(22)
        .fontColor([this.relayStatusColor(relay)])
        .margin({ right: 10 })
      Column() {
        Row() {
          this.relayTypeBadge('RustDesk 中继')
          Text(relay.displayName()).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 6 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Row() {
          Column().width(6).height(6).borderRadius(3).backgroundColor(this.relayStatusColor(relay))
          Text(this.relayStatusLabel(relay)).fontSize(12).fontColor(this.relayStatusColor(relay)).margin({ left: 4 })
          Text(' · ' + this.hostCountForRelay(relay.id) + '台').fontSize(11).fontColor(this.pal().text3)
          Text(' · ' + this.accountCountForRelay(relay.id) + '账户').fontSize(11).fontColor(this.pal().text3)
        }.margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      // ⋯ menu
      Button() {
        Text('⋯').fontSize(20).fontColor(this.pal().text)
      }
      .width(40).height(40).borderRadius(20)
      .backgroundColor(this.pal().surface)
      .bindPopup(this.menuVisibleRelayId === relay.id, {
        builder: this.pcMenuBuilder(relay),
        placement: Placement.BottomRight,
        enableArrow: true,
        popupColor: this.pal().card,
        width: this.pcMenuWidth(),
        onStateChange: (e: Object) => {
          const ev: Record<string, boolean> = e as Record<string, boolean>;
          if (!ev['isVisible']) { this.menuVisibleRelayId = ''; }
        }
      })
      .onClick(() => {
        animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
          this.menuVisibleRelayId = (this.menuVisibleRelayId === relay.id) ? '' : relay.id;
        });
      })
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor(this.selectedPcRelay !== null && (this.selectedPcRelay as RustDeskRelayConfig).id === relay.id ? this.pal().surface : Color.Transparent)
    .onClick(() => {
      this.selectedPcRelay = relay;
      this.selectedPcVncGateway = null;
    })
  }

  @Builder pcVncGatewayListItem(gateway: VncGatewayView) {
    Row() {
      SymbolGlyph(protocolIcon('vnc_gateway'))
        .fontSize(22).fontColor([this.vncGatewayStatusColor(gateway)]).margin({ right: 10 })
      Column() {
        Row() {
          this.relayTypeBadge('VNC Gateway')
          Text(gateway.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(this.font()).margin({ left: 6 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.vncGatewayStatusLabel(gateway)).fontSize(12).fontColor(this.vncGatewayStatusColor(gateway))
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).backgroundColor(this.pal().surface)
        .onClick((): void => { this.openEditVncGatewaySheet(gateway); })
    }
    .width('100%').padding({ left: 12, right: 8, top: 10, bottom: 10 }).borderRadius(10)
    .backgroundColor(this.selectedPcVncGateway !== null && this.selectedPcVncGateway.id === gateway.id
      ? this.pal().surface : Color.Transparent)
    .onClick((): void => {
      this.selectedPcVncGateway = gateway;
      this.selectedPcRelay = null;
    })
  }

  private pcMenuWidth(): number {
    const labels: string[] = ['测试连接', '编辑', '删除'];
    let longestTextVp: number = 0;
    const uiContext = this.getUIContext();
    labels.forEach((label: string): void => {
      const measuredPx: number = uiContext.getMeasureUtils().measureText({
        textContent: label,
        fontSize: 13
      });
      longestTextVp = Math.max(longestTextVp, uiContext.px2vp(measuredPx));
    });
    // Popup shell padding + button padding + 16vp icon + 8vp text gap.
    return Math.ceil(longestTextVp + 56);
  }

  @Builder pcMenuBuilder(relay: RustDeskRelayConfig) {
    Column() {
      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(16).fontColor([this.pal().text])
          Text('测试连接').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').constraintSize({ minHeight: 42 }).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.doTestRelay(relay); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text])
          Text('编辑').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').constraintSize({ minHeight: 42 }).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.openEditRelaySheet(relay); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
          Text('删除').fontSize(13).fontColor(this.pal().danger).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').constraintSize({ minHeight: 42 }).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.doDeleteRelay(relay.id); })
    }
    .width('100%').padding(4).borderRadius(12)
  }

  @Builder vncGatewayDetailPanelContent() {
    if (this.selectedPcVncGateway !== null) {
      Column() {
        Row() {
          Column() {
            Row() {
              SymbolGlyph(protocolIcon('vnc_gateway')).fontSize(25).fontColor([this.accentColor])
              Text('VNC Gateway').fontSize(11).fontColor(this.accentColor).margin({ left: 8 })
            }
            Text((this.selectedPcVncGateway as VncGatewayView).label)
              .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              .margin({ top: 8 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.vncGatewayStatusLabel(this.selectedPcVncGateway as VncGatewayView))
              .fontSize(14).fontColor(this.vncGatewayStatusColor(this.selectedPcVncGateway as VncGatewayView))
              .margin({ top: 5 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row() {
            Button(this.testingVncGatewayId === (this.selectedPcVncGateway as VncGatewayView).id ? '检测中…' : '测试 TCP')
              .fontSize(13).height(36).backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(8)
              .padding({ left: 14, right: 14 }).enabled(this.testingVncGatewayId === '')
              .onClick((): void => { void this.doTestVncGateway(this.selectedPcVncGateway as VncGatewayView); })
            Button(this.testingVncGatewayId === (this.selectedPcVncGateway as VncGatewayView).id
              && this.testingVncGatewayRequestId > 0 ? '取消深度' : '深度测试')
              .fontSize(13).height(36).backgroundColor(this.pal().surface)
              .fontColor(this.accentColor).borderRadius(8).margin({ left: 8 })
              .padding({ left: 14, right: 14 })
              .enabled(this.testingVncGatewayId === '' ||
                (this.testingVncGatewayId === (this.selectedPcVncGateway as VncGatewayView).id &&
                this.testingVncGatewayRequestId > 0))
              .onClick((): void => {
                if (this.testingVncGatewayRequestId > 0) {
                  this.cancelDeepTestVncGateway();
                } else {
                  void this.doDeepTestVncGateway(this.selectedPcVncGateway as VncGatewayView);
                }
              })
            Button('编辑').fontSize(13).height(36).backgroundColor(this.pal().surface).fontColor(this.pal().text2)
              .borderRadius(8).margin({ left: 8 }).padding({ left: 14, right: 14 })
              .onClick((): void => { this.openEditVncGatewaySheet(this.selectedPcVncGateway as VncGatewayView); })
          }
        }.width('100%').padding({ bottom: 16 }).border({ width: { bottom: 0.5 }, color: this.pal().divider })
          .margin({ bottom: 16 })
        Text('服务器').fontSize(13).fontColor(this.pal().text3).fontWeight(FontWeight.Medium)
          .width('100%').margin({ bottom: 8 })
        Column() {
          this._pcEndpointRow('端点', (this.selectedPcVncGateway as VncGatewayView).host,
            (this.selectedPcVncGateway as VncGatewayView).port)
          if ((this.selectedPcVncGateway as VncGatewayView).path !== '') {
            Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
            this._pcEndpointRow('路径', (this.selectedPcVncGateway as VncGatewayView).path, 0)
          }
          if ((this.selectedPcVncGateway as VncGatewayView).targetId !== '') {
            Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
            this._pcEndpointRow('目标', this.redactedVncTarget((this.selectedPcVncGateway as VncGatewayView).targetId), 0)
          }
          Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
          this._pcEndpointRow('安全', (this.selectedPcVncGateway as VncGatewayView).tls ? 'TLS' : '明文', 0)
        }.width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(14).margin({ bottom: 14 })
        Text('健康诊断').fontSize(13).fontColor(this.pal().text3).fontWeight(FontWeight.Medium)
          .width('100%').margin({ bottom: 8 })
        if (this.vncTestResultId === (this.selectedPcVncGateway as VncGatewayView).id && this.vncTestResult !== '') {
          Text(this.vncTestResult).fontSize(12)
            .fontColor(this.vncTestResult.startsWith('✓') ? this.pal().success : this.pal().danger)
            .width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface)
        } else {
          Text(vncGatewayAvailability((this.selectedPcVncGateway as VncGatewayView).transport,
            (this.selectedPcVncGateway as VncGatewayView).tls,
            (this.selectedPcVncGateway as VncGatewayView).tokenConfigured,
            (this.selectedPcVncGateway as VncGatewayView).repeaterMode).message ||
            '尚未执行 Gateway 检查；TCP 端口测试不等于协议链路就绪')
            .fontSize(12).fontColor(this.pal().text3).width('100%').padding(12)
            .borderRadius(10).backgroundColor(this.pal().surface)
        }
        Blank().layoutWeight(1)
        Button('删除此 VNC Gateway').width('100%').height(40).borderRadius(10)
          .backgroundColor(Color.Transparent).fontColor(this.pal().danger)
          .onClick((): void => { this.doDeleteVncGateway(this.selectedPcVncGateway as VncGatewayView); })
      }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 20 })
    }
  }

  // PC detail panel — horizontal landscape layout with two columns (no scroll)
  @Builder pcDetailPanelContent() {
    Column() {
        if (this.selectedPcRelay !== null) {
          // ===== Header bar: name + status + actions =====
          Row() {
            Column() {
              Text('RustDesk 中继').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
              Text((this.selectedPcRelay as RustDeskRelayConfig).displayName())
                .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
                .margin({ top: 4 })
              Row() {
                Column().width(8).height(8).borderRadius(4)
                  .backgroundColor(this.relayStatusColor(this.selectedPcRelay as RustDeskRelayConfig))
                Text(this.relayStatusLabel(this.selectedPcRelay as RustDeskRelayConfig))
                  .fontSize(14).fontColor(this.relayStatusColor(this.selectedPcRelay as RustDeskRelayConfig))
                  .fontFamily(this.font()).margin({ left: 5 })
                if ((this.selectedPcRelay as RustDeskRelayConfig).healthCheckedAt > 0) {
                  Text(' · ' + this.relayCheckedAtLabel(this.selectedPcRelay as RustDeskRelayConfig))
                    .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                }
              }.margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Row() {
              Button('测试连接').fontSize(14).height(36)
                .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
                .padding({ left: 16, right: 16 }).fontWeight(FontWeight.Medium)
                .onClick(() => { this.doTestRelay(this.selectedPcRelay as RustDeskRelayConfig); })
              Button('编辑').fontSize(14).height(36)
                .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(8)
                .margin({ left: 8 }).padding({ left: 16, right: 16 })
                .onClick(() => { this.openEditRelaySheet(this.selectedPcRelay as RustDeskRelayConfig); })
            }
          }.width('100%').padding({ bottom: 16 })
          .border({ width: { bottom: 0.5 }, color: this.pal().divider }).margin({ bottom: 16 })

          // ===== Two-column body =====
          Row() {
            // Left column: 服务器 + 健康诊断
            Column() {
              // 服务器信息
              Text('服务器').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              Column() {
                this._pcEndpointRow('ID', (this.selectedPcRelay as RustDeskRelayConfig).idServer,
                  (this.selectedPcRelay as RustDeskRelayConfig).idServerPort)
                Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                this._pcEndpointRow('Relay', (this.selectedPcRelay as RustDeskRelayConfig).relayServer,
                  (this.selectedPcRelay as RustDeskRelayConfig).relayPort)
                if ((this.selectedPcRelay as RustDeskRelayConfig).apiServer !== '') {
                  Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                  this._pcEndpointRow('API', (this.selectedPcRelay as RustDeskRelayConfig).apiServer, 0)
                }
                Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                Row() {
                  Text('控制面').fontSize(14).fontColor(this.pal().text3).fontFamily(this.font()).width(48)
                  Text(rustDeskControlPlaneProfileLabel(
                    (this.selectedPcRelay as RustDeskRelayConfig).controlPlaneProfile))
                    .fontSize(14).fontColor(this.pal().text2).fontFamily(this.font())
                  Blank()
                }.width('100%').padding({ top: 4, bottom: 2 })
                Text(rustDeskControlPlaneProfileDescription(
                  (this.selectedPcRelay as RustDeskRelayConfig).controlPlaneProfile))
                  .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                  .lineHeight(16).width('100%').margin({ bottom: 3 })
                Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                Row() {
                  Text('密钥').fontSize(14).fontColor(this.pal().text3).fontFamily(this.font()).width(48)
                  Text((this.selectedPcRelay as RustDeskRelayConfig).key !== '' ? '已配置' : '默认 (官方)')
                    .fontSize(14).fontColor((this.selectedPcRelay as RustDeskRelayConfig).key !== '' ? this.pal().success : this.pal().text3)
                    .fontFamily(this.font())
                  Blank()
                }.width('100%').padding({ top: 4, bottom: 4 })
              }
              .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(14).margin({ bottom: 14 })

              // 健康诊断
              Text('健康诊断').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              this._pcHealthCard('ID TCP',
                (this.selectedPcRelay as RustDeskRelayConfig).idServer + ':' + (this.selectedPcRelay as RustDeskRelayConfig).idServerPort,
                (this.selectedPcRelay as RustDeskRelayConfig).healthStatus)
              Blank().height(8)
              this._pcHealthCard('Relay TCP',
                (this.selectedPcRelay as RustDeskRelayConfig).relayServer + ':' + (this.selectedPcRelay as RustDeskRelayConfig).relayPort,
                (this.selectedPcRelay as RustDeskRelayConfig).healthStatus)
              if ((this.selectedPcRelay as RustDeskRelayConfig).apiServer !== '') {
                Blank().height(8)
                this._pcHealthCard('API', (this.selectedPcRelay as RustDeskRelayConfig).apiServer, 'unknown')
              }
            }.width('50%').padding({ right: 10 }).alignItems(HorizontalAlign.Start)

            // Right column: 账户 + 绑定主机 — top-aligned
            Column() {
              this.proAccountSection(this.selectedPcRelay as RustDeskRelayConfig)

              // 绑定主机
              Text('绑定主机').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              Column() {
                Row() {
                  SymbolGlyph($r('sys.symbol.desktop_fill')).fontSize(18).fontColor([this.pal().text3])
                  Text((this.hostCountForRelay((this.selectedPcRelay as RustDeskRelayConfig).id)) + ' 台主机已绑定')
                    .fontSize(15).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
                  Blank()
                  Text('查看 →').fontSize(13).fontColor(this.accentColor).fontFamily(this.font())
                }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
              }
              .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(10)

              Blank().layoutWeight(1)
            }.width('50%').padding({ left: 10 })
          }.width('100%').alignItems(VerticalAlign.Top)

          Blank().height(32)
        }
      }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 20 })
  }

  @Builder _pcEndpointRow(label: string, host: string, port: number) {
    Row() {
      Text(label).fontSize(14).fontColor(this.pal().text3).fontFamily(this.font()).width(48)
      Text(host).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).layoutWeight(1)
      if (port > 0) {
        Text(':' + port.toString()).fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          .margin({ left: 4 })
      }
    }.width('100%').padding({ top: 3, bottom: 3 })
  }

  @Builder _pcHealthCard(label: string, endpoint: string, status: string) {
    Column() {
      Row() {
        Text(label).fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
        Blank()
        if (status === 'online') {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.pal().success])
        } else if (status === 'offline' || status === 'error') {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().danger])
        } else {
          Text('未检测').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
        }
      }.width('100%')
      Text(endpoint).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).margin({ top: 4 })
    }
    .width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface)
  }

  @Builder vncGatewayCardContent(gateway: VncGatewayView) {
    Column() {
      Row() {
        SymbolGlyph(protocolIcon('vnc_gateway')).fontSize(this.breakpoint === 'sm' ? 22 : 24)
          .fontColor([this.vncGatewayStatusColor(gateway)])
        Column() {
          Row() {
            this.relayTypeBadge('VNC Gateway')
            Text(gateway.label).fontSize(this.breakpoint === 'sm' ? 15 : 17)
              .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              .margin({ left: 7 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.vncGatewayStatusLabel(gateway)).fontSize(this.breakpoint === 'sm' ? 11 : 13)
            .fontColor(this.vncGatewayStatusColor(gateway)).fontFamily(this.font()).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        Button() { SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(15).fontColor([this.pal().text2]) }
          .width(32).height(32).borderRadius(16).backgroundColor(this.pal().surface)
          .onClick((): void => { this.openEditVncGatewaySheet(gateway); })
      }.width('100%')
      Column() {
        this._cardInfoRow('端点', gateway.host + ':' + gateway.port.toString())
        if (gateway.path !== '') { this._cardInfoRow('路径', gateway.path) }
        if (gateway.targetId !== '') {
          this._cardInfoRow('目标', this.redactedVncTarget(gateway.targetId) + ' · ' + gateway.repeaterMode)
        }
        this._cardInfoRow('安全', (gateway.tls ? 'TLS' : '明文') +
          (gateway.tokenConfigured ? ' · 令牌已配置' : ' · 无令牌'))
        if (!this.gatewayAvailability(gateway).enabled) {
          Text(this.gatewayAvailability(gateway).message).fontSize(10).fontColor(this.pal().danger).lineHeight(16)
            .width('100%').margin({ top: 5 })
        }
        if (this.vncTestResultId === gateway.id && this.vncTestResult !== '') {
          Text(this.vncTestResult).fontSize(10)
            .fontColor(this.vncTestResult.startsWith('✓') ? this.pal().success : this.pal().danger)
            .width('100%').margin({ top: 5 })
        }
      }.width('100%').borderRadius(10).backgroundColor(this.pal().surface)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ top: 9 })
      Row() {
        Button(this.testingVncGatewayId === gateway.id ? '检测中…' : '测试 TCP')
          .layoutWeight(1).height(32).fontSize(11).borderRadius(8)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .enabled(this.testingVncGatewayId === '')
          .onClick((): void => { void this.doTestVncGateway(gateway); })
        Button(this.testingVncGatewayId === gateway.id && this.testingVncGatewayRequestId > 0
          ? '取消深度' : '深度测试')
          .layoutWeight(1).height(32).fontSize(11).borderRadius(8)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .enabled(this.testingVncGatewayId === '' ||
            (this.testingVncGatewayId === gateway.id && this.testingVncGatewayRequestId > 0))
          .onClick((): void => {
            if (this.testingVncGatewayRequestId > 0) {
              this.cancelDeepTestVncGateway();
            } else {
              void this.doDeepTestVncGateway(gateway);
            }
          })
        Button('删除').layoutWeight(1).height(32).fontSize(11).borderRadius(8)
          .backgroundColor(this.pal().surface).fontColor(this.pal().danger).margin({ left: 7 })
          .onClick((): void => { this.doDeleteVncGateway(gateway); })
      }.width('100%').margin({ top: 9 })
    }
    .width('100%').constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? 12 : 14).borderRadius(14)
    .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  // ==================== Relay Card Content (shared by mobile & tablet) ====================

  @Builder relayTypeBadge(label: string) {
    Text(label).fontSize(10).fontColor(this.accentColor).fontFamily(this.font())
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(6).backgroundColor(this.pal().surface).margin({ right: 6 })
  }

  @Builder relayProtocolChoiceSheet() {
    ResourceFabPicker({
      kind: 'gateway',
      onSelect: (option: string): void => {
        if (option === 'rustdesk') {
          this.relayKind = 'oss';
          this.formControlPlaneProfile = RUSTDESK_CONTROL_PLANE_DEFAULT;
          this.sheetContent = 1;
        }
        if (option === 'vnc') { this.openVncGatewaySheet(); }
      },
      onClose: (): void => { this.closeSheet(); }
    })
  }

  @Builder relayCardContent(relay: RustDeskRelayConfig, enableTap: boolean) {
    Column() {
      // Card header.  Keep the health action and overflow menu outside the
      // expand hit target so a tap expands while a horizontal swipe can still
      // be handled continuously by ListItem.swipeAction.
      Row() {
        SymbolGlyph(protocolIcon('rustdesk_relay'))
          .fontSize(this.breakpoint === 'sm' ? 22 : 24)
          .fontColor([this.accentColor])
        // The title/status/chevron region is the expand hit target.  A click
        // is delivered only after a tap; ListItem.swipeAction keeps ownership
        // of horizontal drags, so swipe-to-reveal remains continuous.
        Row() {
          Column() {
            Row() {
              this.relayTypeBadge('RustDesk 中继')
              Text(relay.displayName())
                .fontSize(this.breakpoint === 'sm' ? 15 : 17).fontWeight(FontWeight.Medium)
                .fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 7 })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.width('100%')
            Row() {
              Column().width(this.breakpoint === 'sm' ? 6 : 7)
                .height(this.breakpoint === 'sm' ? 6 : 7)
                .borderRadius(this.breakpoint === 'sm' ? 3 : 4)
                .backgroundColor(this.relayStatusColor(relay))
              Text(this.relayStatusLabel(relay))
                .fontSize(this.breakpoint === 'sm' ? 11 : 13)
                .fontColor(this.relayStatusColor(relay)).fontFamily(this.font())
                .margin({ left: this.breakpoint === 'sm' ? 4 : 5 })
              Text(' · ' + this.hostCountForRelay(relay.id) + '台')
                .fontSize(this.breakpoint === 'sm' ? 11 : 12)
                .fontColor(this.pal().text3).fontFamily(this.font())
              Text(' · ' + this.accountCountForRelay(relay.id) + '账户')
                .fontSize(this.breakpoint === 'sm' ? 11 : 12)
                .fontColor(this.pal().text3).fontFamily(this.font())
            }.margin({ top: this.breakpoint === 'sm' ? 2 : 3 })
            Text(rustDeskControlPlaneProfileLabel(relay.controlPlaneProfile))
              .fontSize(this.breakpoint === 'sm' ? 10 : 11).fontColor(this.pal().text3)
              .fontFamily(this.font()).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          if (!this.isPC()) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14).fontColor([this.pal().text3])
              .rotate({ angle: this.isRelayExpanded(relay.id) ? 90 : 0 })
              .animation({ duration: 250, curve: Curve.FastOutSlowIn })
              .margin({ left: 8, right: this.breakpoint !== 'sm' ? 10 : 0 })
          }
        }
        .layoutWeight(1)
        .margin({ left: this.breakpoint === 'sm' ? 10 : 12 })
        .onClick(() => {
          if (enableTap || !this.isPC()) { this.toggleRelayExpanded(relay.id); }
        })

        // Controls outside the expand hit target.
        if (!this.isPC() && this.breakpoint === 'sm') {
          Button() {
            SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(15).fontColor([this.accentColor])
          }
          .width(32).height(32).borderRadius(16)
          .backgroundColor(this.pal().surface)
          .enabled(this.testingRelayId !== relay.id)
          .onClick(() => { void this.doTestRelay(relay); })
          .margin({ left: 6 })
        }
        if (this.breakpoint !== 'sm') {
          Button() {
            Text('⋯').fontSize(18).fontColor(this.pal().text)
          }
          .width(32).height(32).borderRadius(16)
          .backgroundColor(this.pal().surface)
          .bindPopup(this.menuVisibleRelayId === relay.id, {
            builder: this.pcMenuBuilder(relay),
            placement: Placement.BottomRight,
            enableArrow: true,
            popupColor: this.pal().card,
            width: this.pcMenuWidth(),
            onStateChange: (e: Object) => {
              const ev: Record<string, boolean> = e as Record<string, boolean>;
              if (!ev['isVisible']) { this.menuVisibleRelayId = ''; }
            }
          })
          .onClick(() => {
            animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
              this.menuVisibleRelayId = (this.menuVisibleRelayId === relay.id) ? '' : relay.id;
            });
          })
          .margin({ left: 6 })
        }
      }
      .width('100%')

      // Expanded: server info
      if (this.isRelayExpanded(relay.id)) {
        Column() {
          // Server endpoints
          Column() {
            this._cardInfoRow('ID', relay.idServer + ':' + relay.idServerPort)
            this._cardInfoRow('Relay', relay.relayServer + ':' + relay.relayPort)
            if (relay.apiServer !== '') {
              this._cardInfoRow('API', relay.apiServer)
            }
          }
          .width('100%').borderRadius(10).backgroundColor(this.pal().surface)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ top: 8 })

          // Account directory: keep manual credentials and Server Pro in one
          // clearly grouped surface so they read as different sources, not
          // two competing login cards.
          this.compactAccountDirectory(relay)
        }
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: 250, curve: Curve.FastOutSlowIn })
            .combine(
              TransitionEffect.translate({ y: -8 })
                .animation({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) })
            )
        )
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? 12 : 14)
    .borderRadius(14)
    .backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder _cardInfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).width(32)
      Text(value).fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).layoutWeight(1)
    }.width('100%').padding({ top: 2, bottom: 2 })
  }

  @Builder compactAccountDirectory(relay: RustDeskRelayConfig) {
    Column() {
      Row() {
        Text('账户与地址簿').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.proAccountsForRelay(relay.id).length + ' 个 Pro 账户')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
        Text('新增账户').fontSize(11).fontColor(this.accentColor).fontFamily(this.font()).margin({ left: 10 })
          .onClick((): void => { this.openNewProAccountSheet(relay); })
      }.width('100%').margin({ bottom: 9 })

      Row() {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(16).fontColor([this.accentColor])
        Column() {
          Text('Server Pro 地址簿').fontSize(12).fontColor(this.pal().text).fontFamily(this.font())
          Text(this.proAccountsForRelay(relay.id).length > 0 ? '同步云端主机并显示设备平台' : '用于同步云端主机与平台信息')
            .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 8 })
        Text(this.proAccountsForRelay(relay.id).length > 0 ? '管理' : '登录')
          .fontSize(12).fontColor(this.accentColor).fontFamily(this.font())
          .onClick(() => { this.openProAccountSheet(relay); })
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(9).backgroundColor(this.pal().card)

      if (this.proAccountsForRelay(relay.id).length === 0) {
        Text('尚未连接 Server Pro 地址簿')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 2 })
      }
      ForEach(this.proAccountsForRelay(relay.id), (account: RustDeskProAccountState) => {
        Row() {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(15).fontColor([this.proStatusColor(account)])
          Column() {
            Text(account.displayName.length > 0 ? account.displayName : account.username)
              .fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
            Text(this.proStatusLabel(account) + ' · ' + account.serverUrl)
              .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 7 })
          if (account.loginStatus === 'logged_in') {
            Text('同步').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
              .margin({ right: 8 }).onClick(() => { this.doProSync(account.id); })
          }
          Text('管理').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
            .onClick(() => { this.openProAccountSheet(relay, account); })
        }
        .width('100%').padding({ left: 9, right: 9, top: 7, bottom: 7 })
        .borderRadius(9).backgroundColor(this.pal().surface).margin({ top: 4 })
      }, (account: RustDeskProAccountState): string =>
        account.id + ':' + this.proViewRevision.toString())
    }
    .width('100%').borderRadius(12).backgroundColor(this.pal().surface)
    .padding(10).margin({ top: 12, bottom: 14 })
  }

  @Builder proAccountSection(relay: RustDeskRelayConfig) {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(16).fontColor([this.accentColor])
          Text('Server Pro 地址簿').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 6 })
        }
        Blank()
        Text('新增账户').fontSize(13).fontColor(this.accentColor).fontFamily(this.font())
          .onClick(() => { this.openNewProAccountSheet(relay); })
      }.width('100%').margin({ bottom: 7 })
      if (this.proAccountsForRelay(relay.id).length === 0) {
        Text('Server Pro 地址簿未连接').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
          .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
      }
      ForEach(this.proAccountsForRelay(relay.id), (account: RustDeskProAccountState) => {
        Row() {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(15).fontColor([this.proStatusColor(account)])
          Column() {
            Text(account.displayName.length > 0 ? account.displayName : account.username)
              .fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
            Text(this.proStatusLabel(account) + ' · ' + account.serverUrl)
              .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 7 })
          if (account.loginStatus === 'logged_in') {
            Text('同步').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
              .margin({ right: 8 }).onClick(() => { this.doProSync(account.id); })
          }
          Text('管理').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
            .onClick(() => { this.openProAccountSheet(relay, account); })
        }
        .width('100%').padding({ left: 9, right: 9, top: 7, bottom: 7 })
        .borderRadius(9).backgroundColor(this.pal().card).margin({ bottom: 3 })
      }, (account: RustDeskProAccountState): string =>
        account.id + ':' + this.proViewRevision.toString())
    }
    .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(10).margin({ bottom: 14 })
  }

  // ==================== Title Bar ====================

  @Builder TitleBarOverlay() {
    Stack() {
      Column() {
        Row().width('100%').height(this.topSafeH() + this.titleOffsetY())
        Row() {
          Text('中继服务器').fontSize(27).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Blank()
        }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
      }.width('100%').backgroundColor(Color.Transparent)
    }.width('100%').height(this.titleBarH()).hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== Sheets (unchanged from original) ====================

  @Builder relayEditSheet() {
    Column() {
      Text(this.editingRelayId !== '' ? '编辑 RustDesk 中继' : '添加 RustDesk 中继')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%')
      Text('默认只需服务器地址和公钥；保存后再测试连接或登录地址簿。')
        .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
        .width('100%').lineHeight(17).margin({ top: 5, bottom: 14 })
      Column() {
        Column() {
          Button('粘贴 RustDesk 加密配置')
            .width('100%').height(36).fontSize(13).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).borderRadius(8).enabled(!this.importingRelayConfig)
            .margin({ bottom: 6 }).onClick((): void => { this.sheetContent = 9; })
          Button('从文件导入配置')
            .width('100%').height(32).fontSize(12).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text2).borderRadius(8).enabled(!this.importingRelayConfig)
            .margin({ bottom: 10 }).onClick((): void => { void this.importRelayConfig(); })
          this._f('服务器地址', 'hbbs.example.com', this.formIdServer,
            (v: string): void => { this.formIdServer = v; })
          this._f(this.formKeyMode === 'shared_access_key' ? '共享 Key（原样发送）' : '服务器公钥',
            this.formKeyMode === 'shared_access_key' ? '与 hbbs/hbbr -k 完全一致' : 'Base64 32 字节 Ed25519 公钥',
            this.formKey, (v: string) => { this.formKey = v; }, this.formKeyMode === 'shared_access_key')
          Text(this.formKeyMode === 'shared_access_key' ?
            '不会删除空格或 =；此模式不能验证服务器身份。' :
            '请填写服务商提供的服务器公钥；留空仅适用于使用 RustDesk 默认公钥的服务器。')
            .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).width('100%')
            .lineHeight(15).margin({ top: -5, bottom: 8 })

          Button(this.showRelayAdvanced ? '收起高级设置' : '展开高级设置')
            .width('100%').height(34).fontSize(12).borderRadius(8)
            .backgroundColor(this.pal().surface).fontColor(this.accentColor)
            .onClick((): void => { this.showRelayAdvanced = !this.showRelayAdvanced; })

          if (this.showRelayAdvanced) {
            Column() {
              Text('连接端点').fontSize(11).fontWeight(FontWeight.Medium)
                .fontColor(this.pal().text2).width('100%').margin({ bottom: 8 })
              this._f('ID 服务器端口', '21116', this.formIdPortText,
                (v: string): void => { this.formIdPortText = v; })
              this._f('独立中继服务器地址（留空则同上）', 'hbbr.example.com', this.formRelayServer,
                (v: string): void => { this.formRelayServer = v; })
              this._f('中继端口', '21117', this.formRelayPortText,
                (v: string): void => { this.formRelayPortText = v; })
              this._f('地址簿 / Server Pro API 地址（可选）', 'https://api.example.com',
                this.formApiServer, (v: string): void => { this.formApiServer = v; })

              Text('Key 类型').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
              Row() {
                Button('服务器公钥').layoutWeight(1).height(32).fontSize(12).borderRadius(8)
                  .backgroundColor(this.formKeyMode === 'server_public_key' ? this.accentColor : this.pal().surface)
                  .fontColor(this.formKeyMode === 'server_public_key' ? Color.White : this.pal().text2)
                  .onClick((): void => {
                    this.formKeyMode = 'server_public_key';
                    if (this.formControlPlaneProfile === 'oss_shared_access_key') {
                      this.formControlPlaneProfile = 'oss_key_only';
                    }
                  })
                Button('共享 -k').layoutWeight(1).height(32).fontSize(12).borderRadius(8).margin({ left: 8 })
                  .backgroundColor(this.formKeyMode === 'shared_access_key' ? this.accentColor : this.pal().surface)
                  .fontColor(this.formKeyMode === 'shared_access_key' ? Color.White : this.pal().text2)
                  .onClick((): void => {
                    this.formKeyMode = 'shared_access_key';
                    if (this.formControlPlaneProfile === 'oss_key_only') {
                      this.formControlPlaneProfile = 'oss_shared_access_key';
                    }
                  })
              }.width('100%').margin({ bottom: 10 })

              Text('控制面配置').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
              Row() {
                Button('OSS / 仅 Key').layoutWeight(1).height(32).fontSize(11).borderRadius(8)
                  .backgroundColor(this.formControlPlaneProfile === 'oss_key_only' ||
                    this.formControlPlaneProfile === 'oss_shared_access_key' ?
                    this.accentColor : this.pal().surface)
                  .fontColor(this.formControlPlaneProfile === 'oss_key_only' ||
                    this.formControlPlaneProfile === 'oss_shared_access_key' ?
                    Color.White : this.pal().text2)
                  .onClick((): void => { this.formControlPlaneProfile = 'oss_key_only'; this.relayKind = 'oss'; })
                Button('仅地址簿 API').layoutWeight(1).height(32).fontSize(11).borderRadius(8).margin({ left: 6 })
                  .backgroundColor(this.formControlPlaneProfile === 'third_party_api_only' ?
                    this.accentColor : this.pal().surface)
                  .fontColor(this.formControlPlaneProfile === 'third_party_api_only' ?
                    Color.White : this.pal().text2)
                  .onClick((): void => {
                    this.formControlPlaneProfile = 'third_party_api_only'; this.relayKind = 'advanced';
                  })
              }.width('100%').margin({ bottom: 5 })
              Row() {
                Button('官方 Server Pro').layoutWeight(1).height(32).fontSize(11).borderRadius(8)
                  .backgroundColor(this.formControlPlaneProfile === 'official_server_pro_token' ?
                    this.accentColor : this.pal().surface)
                  .fontColor(this.formControlPlaneProfile === 'official_server_pro_token' ?
                    Color.White : this.pal().text2)
                  .onClick((): void => {
                    this.formControlPlaneProfile = 'official_server_pro_token'; this.relayKind = 'pro';
                  })
                Button('第三方控制面').layoutWeight(1).height(32).fontSize(11)
                  .borderRadius(8).margin({ left: 6 })
                  .backgroundColor(this.formControlPlaneProfile === 'third_party_control_plane' ?
                    this.accentColor : this.pal().surface)
                  .fontColor(this.formControlPlaneProfile === 'third_party_control_plane' ?
                    Color.White : this.pal().text2)
                  .onClick((): void => {
                    this.formControlPlaneProfile = 'third_party_control_plane'; this.relayKind = 'advanced';
                  })
              }.width('100%').margin({ bottom: 4 })
              Text('第三方控制面会在账号、API 地址、ID/中继端点和服务器 Key 与登录绑定一致时，复用同一 HTTP 登录令牌；不一致时拒绝发送令牌（fail-closed）。')
                .fontSize(10).fontColor(this.pal().text3).width('100%').lineHeight(15)
                .margin({ bottom: 5 })
              Text(rustDeskControlPlaneProfileLabel(this.formControlPlaneProfile) + '：' +
                rustDeskControlPlaneProfileDescription(this.formControlPlaneProfile))
                .fontSize(10).fontColor(this.pal().text3).width('100%').lineHeight(15)
            }.width('100%').padding({ top: 12 })
          }

          if (this.formTestResult !== '') {
            Text(this.formTestResult).fontSize(12)
              .fontColor(this.formTestResult.startsWith('✓') ? this.pal().success : this.pal().danger)
              .width('100%').margin({ top: 10 })
          }
          if (this.relaySaveError !== '') {
            Column() {
              Text(this.relaySaveError).fontSize(12).fontColor(this.pal().danger)
                .fontFamily(this.font()).width('100%')
              if (this.relaySaveRecovery === 'unlock') {
                Text('请先在“数据安全”中解锁；返回后草稿仍会保留。')
                  .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
                  .width('100%').margin({ top: 4 })
              } else if (this.relaySaveRecovery === 'wait_for_restore') {
                Text('等待恢复完成后点击重试；无需重新填写。')
                  .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
                  .width('100%').margin({ top: 4 })
              } else if (this.relaySaveRecovery === 'review_account') {
                Text('该记录属于另一账号；请切回原账号，或关闭后重新添加。')
                  .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
                  .width('100%').margin({ top: 4 })
              }
              if (this.relaySaveDiagnostic !== '') {
                Text(this.relaySaveDiagnostic).fontSize(10).fontColor(this.pal().text3)
                  .fontFamily(this.font()).width('100%').margin({ top: 5 })
                  .copyOption(CopyOptions.InApp)
              }
            }.width('100%').padding(10).borderRadius(8)
              .backgroundColor(this.pal().danger + '12').margin({ top: 6 })
          }
          if (this.relaySaving) {
            Text('保存阶段：' + this.relaySaveStage)
              .fontSize(11).fontColor(this.accentColor)
              .fontFamily(this.font()).width('100%')
              .margin({ top: 8 })
          }
          Column().height(18)
        }.width('100%')
      }.width('100%')

      Row() {
        Button('取消').layoutWeight(1).height(44).fontSize(14).borderRadius(11)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .enabled(!this.relaySaving).onClick((): void => { this.closeSheet(); })
        Button(this.relaySaving ? '保存中…' :
          (this.relaySaveError === '' ? '保存到本机' : '重试保存'))
          .layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.relaySaving ? this.pal().text3 : this.accentColor)
          .fontColor(Color.White).borderRadius(11).margin({ left: 10 })
          .enabled(!this.relaySaving).onClick((): void => { this.doSaveRelay(); })
      }.width('100%').margin({ top: 10 })
    }.width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: this.breakpoint === 'sm' ? 24 : 30 })
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().sheetBg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder relaySavedSheet() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(42).fontColor([this.pal().success])
      Text('已保存到本机').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(this.font()).margin({ top: 12 })
      Text('现在可以完成，也可以继续登录 Server Pro 或兼容地址簿；连接测试可从中继卡片发起。')
        .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).textAlign(TextAlign.Center)
        .lineHeight(19).margin({ top: 8, bottom: 18 })
      Column() {
        Text(rustDeskRelayCloudSyncMessage(
          this.relayCloudSyncState))
          .fontSize(12)
          .fontColor(this.relayCloudSyncState === 'failed'
            ? this.pal().danger
            : (this.relayCloudSyncState === 'completed'
              ? this.pal().success : this.pal().text2))
          .fontFamily(this.font()).width('100%')
        if (this.relaySaveDiagnostic !== '') {
          Text(this.relaySaveDiagnostic)
            .fontSize(10).fontColor(this.pal().text3)
            .fontFamily(this.font()).width('100%')
            .margin({ top: 5 })
            .copyOption(CopyOptions.InApp)
        }
        if (this.relayCloudSyncState === 'failed' ||
          this.relayCloudSyncState === 'pending') {
          Button(this.relayCloudSyncState === 'pending'
            ? '再次请求云端上传' : '重试云端上传')
            .width('100%').height(38).fontSize(12)
            .borderRadius(9).margin({ top: 10 })
            .backgroundColor(this.pal().surface)
            .fontColor(this.accentColor)
            .onClick((): void => {
              void this.retryRelayCloudSync();
            })
        }
      }.width('100%').padding(10).borderRadius(9)
        .backgroundColor(this.pal().surface)
        .margin({ bottom: 14 })
      Row() {
        Button('完成').layoutWeight(1).height(42).borderRadius(11)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.closeSheet(); })
        Button('登录并同步地址簿').layoutWeight(1).height(42).borderRadius(11).margin({ left: 10 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => {
            const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays().find(
              (item: RustDeskRelayConfig): boolean => item.id === this.savedRelayId);
            if (relay !== undefined) { this.openProAccountSheet(relay); }
          })
      }.width('100%')
    }.width('100%').padding({ left: 24, right: 24, top: 30, bottom: 40 })
      .borderRadius(this.breakpoint === 'sm' ? 0 : 20).backgroundColor(this.pal().sheetBg)
  }

  @Builder proAccountEditSheet() {
    Column() {
      Text(this.proCreateNewAccount ? '添加 RustDesk Server Pro 账户' :
        (this.proAccountId === '' ? '登录 RustDesk Server Pro' : '管理 Pro 账号'))
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%').margin({ bottom: 8 })
      Text('Pro API 地址独立于中继配置；修改地址后请重新登录并同步。访问令牌仅保存在本机，不参与华为云同步。')
        .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(18)
        .width('100%').margin({ bottom: 14 })
      this._f('Server Pro API 地址', 'http://pro.example.com:21114', this.formProServer, (v: string) => { this.formProServer = v; })
      this._f('用户名', 'user@example.com', this.formProUser, (v: string) => { this.formProUser = v; })
      this._f('密码', '不会保存密码', this.formProPwd, (v: string) => { this.formProPwd = v; })
      if (this.formProError !== '') {
        Text(this.formProError).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font())
          .width('100%').margin({ top: 2, bottom: 4 })
      }
      Button(this.proBusy ? '登录中…' : '登录并同步设备')
        .width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.proBusy ? this.pal().text3 : this.accentColor).fontColor('#FFFFFF').borderRadius(10)
        .enabled(!this.proBusy).onClick(() => { this.doProLogin(); })
      if (this.proAccountId !== '') {
          Button('删除此 Pro 账户').width('100%').height(40).fontSize(14)
          .backgroundColor(Color.Transparent).fontColor(this.pal().danger).borderRadius(10).margin({ top: 8 })
          .onClick(() => { this.doProLogout(this.proAccountId); })
      }
      Blank().height(24)
    }.width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().sheetBg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder relaySheetBuilder() {
    if (this.sheetContent === 1) {
      this.relayEditSheet()
    } else if (this.sheetContent === 3) {
      this.proAccountEditSheet()
    } else if (this.sheetContent === 4) {
      this.relaySavedSheet()
    } else if (this.sheetContent === 5) {
      this.relayProtocolChoiceSheet()
    } else if (this.sheetContent === 10) {
      VncGatewayAddFlow({
        initialGateway: this.editingVncGateway,
        editingId: this.editingVncGateway === null ? '' : this.editingVncGateway.id,
        onClose: (): void => { this.closeSheet(); },
        onSave: (values: VncGatewayValues, id: string, accessToken: string,
          plainStorageConfirmed: boolean): void => {
          this.saveVncGateway(values, id, accessToken, plainStorageConfirmed);
        }
      })
    } else if (this.sheetContent === 11) {
      VncCertificateTrustManagerSheet({
        pendingEndpoint: this.pendingVncTrustEndpoint,
        pendingFingerprintSha256: this.pendingVncTrustFingerprint,
        canConfirmPending: (): boolean => this.canConfirmPendingVncTrust(),
        onClose: (): void => { this.closeSheet(); },
        onConfirmed: (): void => {
          this.pendingVncTrustEndpoint = null;
          this.pendingVncTrustFingerprint = '';
          this.pendingVncTrustBinding = null;
          this.closeSheet();
        },
        onRecheck: (_trust: VncTrustView, _hostId: string): void => { this.closeSheet(); }
      })
    } else if (this.sheetContent === 9) {
      RustDeskRelayConfigPasteSheet({
        onCancel: (): void => { this.sheetContent = 1; },
        onImported: (result: RustDeskRelayImportResult): string => this.importAndSavePastedRelay(result)
      })
    }
  }

  @Builder _f(l: string, h: string, v: string, cb: (v: string) => void, password: boolean = false) {
    Column() {
      Text(l).fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
      TextInput({ placeholder: h, text: v }).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font()).fontSize(13)
        .type(password ? InputType.Password : InputType.Normal).padding({ left: 10, right: 10 }).onChange(cb)
    }.width('100%').margin({ bottom: 10 })
  }
}
