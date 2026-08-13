import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightConnectStageOverlay } from '../components/moonlight/MoonlightConnectStageOverlay';
import { MoonlightControlCenter, MoonlightControlMode } from '../components/moonlight/MoonlightControlCenter';
import { MoonlightControllerOverlay, MoonlightControllerSemanticState } from '../components/moonlight/MoonlightControllerOverlay';
import { MoonlightDiagnosticsHud } from '../components/moonlight/MoonlightDiagnosticsHud';
import { MoonlightSessionToolbar } from '../components/moonlight/MoonlightSessionToolbar';
import { RemoteModifierHandle } from '../components/RemoteModifierHandle';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import { AccountScopeToken } from '../services/AccountScopePolicy';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { MoonlightSessionCoordinator } from '../services/MoonlightSessionCoordinator';
import {
  MoonlightSessionErrorCode,
  MoonlightSessionPhase,
  MoonlightSessionStateSnapshot
} from '../services/MoonlightSessionState';
import {
  MoonlightDiagnosticsSnapshot,
  MoonlightRouteIdentity,
  MoonlightToolbarLayout,
  MoonlightToolbarAction,
  moonlightRouteIdentity,
  moonlightToolbarLayout
} from '../services/MoonlightUiPolicy';
import rdpnapi from 'librdpnapi.so';
import { MoonlightNativeRequestKey } from '../services/MoonlightHostService';

class MoonlightStreamXComponentController extends XComponentController {
  onSurface: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onSurfaceCreated(surfaceId: string): void { this.onSurface(surfaceId); }
}

type MoonlightSessionSheetMode = 'none' | 'control' | 'stop';

const EMPTY_SNAPSHOT: MoonlightDiagnosticsSnapshot = {
  available: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  packetLossPercent: -1, codec: '', width: 0, height: 0,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  audioUnderruns: -1, inputDrops: -1
};

@Entry
@Component
struct MoonlightStreamPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageProp('liveViewEnabled') liveViewEnabled: boolean = true;
  @StorageProp('liveViewMode') liveViewMode: number = 1;
  @StorageProp('remoteDisplayScaleMode') commonDisplayScaleMode: string = 'fit';
  @State hostId: string = '';
  @State appId: string = '';
  @State phase: MoonlightSessionPhase = 'failed';
  @State errorCode: MoonlightSessionErrorCode = 'internal';
  @State degradationReasons: string[] = [];
  @State elapsedMs: number = 0;
  @State firstFrameSeen: boolean = false;
  @State showConnectStage: boolean = true;
  @State showSessionSheet: boolean = false;
  @State sheetMode: MoonlightSessionSheetMode = 'none';
  @State pendingSheetMode: MoonlightSessionSheetMode = 'none';
  @State controlMode: MoonlightControlMode = 'touch';
  @State muted: boolean = false;
  @State volume: number = 100;
  @State scaleMode: string = 'fit';
  @State latencyMode: string = 'lowLatency';
  @State sessionChanges: number = 0;
  @State showDiagnostics: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticsX: number = 18;
  @State diagnosticsY: number = 90;
  @State showController: boolean = false;
  @State controllerEditing: boolean = false;
  @State showModifierPanel: boolean = false;
  @State showShortcutPanel: boolean = false;
  @State ctrlLatch: string = 'off';
  @State altLatch: string = 'off';
  @State shiftLatch: string = 'off';
  @State winLatch: string = 'off';
  @State fnLayer: boolean = false;
  @State showReconnectMask: boolean = false;
  @State showAudioBanner: boolean = false;
  @State showNetworkBanner: boolean = false;
  @State inputFlushCount: number = 0;
  private readonly pipRuntimeAvailable: boolean = false;
  private readonly sessionCoordinator: MoonlightSessionCoordinator =
    MoonlightSessionCoordinator.getInstance();
  private accountScopeUnsubscribe: (() => void) | null = null;
  private snapshotUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;
  private sessionGeneration: number = 0;
  private sessionStartedAtMs: number = 0;
  private elapsedTimer: number = -1;
  private sheetReopenGeneration: number = 0;
  private sheetReopenTimer: number = -1;
  private readonly xcId: string = 'MoonlightStreamSurface';
  private readonly xComponentController: MoonlightStreamXComponentController =
    new MoonlightStreamXComponentController();
  private launchKey: MoonlightNativeRequestKey = { requestId: 0, generation: 0, ownerToken: 0 };
  private serverUuid: string = '';
  private numericAppId: number = 0;
  private hostAddress: string = '';
  private surfaceId: string = '';
  private surfaceWidthPx: number = 1920;
  private surfaceHeightPx: number = 1080;
  private rendererHandle: number = -1;
  private streamStartAttempted: boolean = false;
  private surfacePollTimer: number = -1;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private toolbarLayout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.sheetReopenGeneration += 1;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params, true);
    this.hostId = route.valid ? route.hostId : '';
    this.appId = route.valid ? route.appId : '';
    this.launchKey = {
      requestId: params['launchRequestId'] as number,
      generation: params['launchGeneration'] as number,
      ownerToken: params['launchOwnerToken'] as number
    };
    this.serverUuid = typeof params['serverUuid'] === 'string' ? params['serverUuid'] as string : '';
    this.numericAppId = typeof params['numericAppId'] === 'number' ? params['numericAppId'] as number : 0;
    this.hostAddress = typeof params['hostAddress'] === 'string' ? params['hostAddress'] as string : '';
    this.xComponentController.onSurface = (surfaceId: string): void => {
      this.onMoonlightSurface(surfaceId);
    };
    this.scaleMode = this.commonDisplayScaleMode;
    this.phase = 'failed';
    this.errorCode = 'internal';
    this.degradationReasons = [];
    this.elapsedMs = 0;
    this.firstFrameSeen = false;
    this.sessionGeneration = 0;
    this.sessionStartedAtMs = 0;
    this.clearElapsedTimer();
    this.showConnectStage = true;
    this.phase = 'discovering';
    this.streamStartAttempted = false;
    const scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
    this.sessionCoordinator.bindScope(scope.ownerScopeId, scope.generation);
    this.bindSessionSnapshot(scope);
    this.accountScopeUnsubscribe = AccountSessionCoordinator.getInstance().onChange(
      (next: AccountScopeToken): void => {
        this.sessionCoordinator.bindScope(next.ownerScopeId, next.generation);
        this.bindSessionSnapshot(next);
      });
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.pendingSheetMode = 'none';
    this.showSessionSheet = false;
    this.flushInput('page_disappear');
    this.sessionCoordinator.cancelForRoute(this.hostId, this.appId, 'stream-page-disappear');
    this.stopSurfacePoll();
    this.destroyMoonlightRenderer();
    this.clearElapsedTimer();
    if (this.snapshotUnsubscribe !== null) {
      this.snapshotUnsubscribe();
      this.snapshotUnsubscribe = null;
    }
    if (this.accountScopeUnsubscribe !== null) {
      this.accountScopeUnsubscribe();
      this.accountScopeUnsubscribe = null;
    }
  }

  private routeLeaseValid(): boolean {
    return Number.isSafeInteger(this.launchKey.requestId) && this.launchKey.requestId > 0 &&
      Number.isSafeInteger(this.launchKey.generation) && this.launchKey.generation > 0 &&
      Number.isSafeInteger(this.launchKey.ownerToken) && this.launchKey.ownerToken > 0 &&
      this.serverUuid.trim() !== '' && Number.isSafeInteger(this.numericAppId) &&
      this.numericAppId > 0 && this.hostAddress.trim() !== '';
  }

  private onMoonlightXComponentLoad = (): void => {
    try { rdpnapi.registerNativeXComponent(); } catch (_) {}
    this.pollMoonlightSurface(0);
  }

  private pollMoonlightSurface(attempt: number): void {
    this.stopSurfacePoll();
    if (!this.pageActive || this.streamStartAttempted || attempt >= 80) { return; }
    try {
      const surface: string = this.xComponentController.getXComponentSurfaceId();
      if (surface.trim() !== '') { this.onMoonlightSurface(surface); return; }
    } catch (_) {}
    this.surfacePollTimer = setTimeout((): void => {
      this.surfacePollTimer = -1;
      this.pollMoonlightSurface(attempt + 1);
    }, 50);
  }

  private stopSurfacePoll(): void {
    if (this.surfacePollTimer >= 0) {
      clearTimeout(this.surfacePollTimer);
      this.surfacePollTimer = -1;
    }
  }

  private onMoonlightSurface(surfaceId: string): void {
    if (!this.pageActive || this.streamStartAttempted || !this.routeLeaseValid() ||
        surfaceId.trim() === '') { return; }
    this.surfaceId = surfaceId;
    try {
      if (!rdpnapi.setXComponentSurfaceId(
          surfaceId, this.surfaceWidthPx, this.surfaceHeightPx)) { return; }
      this.rendererHandle = rdpnapi.initRenderer(
        this.xcId, this.surfaceWidthPx, this.surfaceHeightPx);
    } catch (_) {
      this.rendererHandle = -1;
    }
    if (this.rendererHandle <= 0) {
      this.phase = 'failed'; this.errorCode = 'decoder_failed'; return;
    }
    this.streamStartAttempted = true;
    const scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
    const result = this.sessionCoordinator.start({
      ownerScopeId: scope.ownerScopeId, accountGeneration: scope.generation,
      hostId: this.hostId, appId: this.appId, hostAddress: this.hostAddress,
      runtimeAvailable: true, hostControlReady: true, streamingTransportReady: true,
      hostControlAlreadyLaunched: true, launchKey: this.launchKey,
      serverUuid: this.serverUuid, numericAppId: this.numericAppId,
      rendererHandle: this.rendererHandle, surfaceWidth: this.surfaceWidthPx,
      surfaceHeight: this.surfaceHeightPx, surfaceId: this.surfaceId
    });
    if (!result.accepted) {
      this.phase = 'failed'; this.errorCode = 'internal';
      promptAction.showToast({ message: '串流启动失败（' + result.code + '）', duration: 2200 });
      this.destroyMoonlightRenderer();
    }
  }

  private destroyMoonlightRenderer(): void {
    const handle: number = this.rendererHandle;
    this.rendererHandle = -1;
    if (handle > 0) {
      try { rdpnapi.destroyRenderer(handle); } catch (_) {}
    }
  }

  private bindSessionSnapshot(scope: AccountScopeToken): void {
    if (this.snapshotUnsubscribe !== null) {
      this.snapshotUnsubscribe();
      this.snapshotUnsubscribe = null;
    }
    if (this.hostId === '' || this.appId === '') {
      this.applySessionSnapshot(null);
      return;
    }
    this.snapshotUnsubscribe = this.sessionCoordinator.subscribeForRoute(
      scope.ownerScopeId, scope.generation, this.hostId, this.appId,
      (snapshot: MoonlightSessionStateSnapshot | null): void => {
        this.applySessionSnapshot(snapshot);
      });
  }

  private applySessionSnapshot(snapshot: MoonlightSessionStateSnapshot | null): void {
    if (!this.pageActive) { return; }
    if (snapshot === null) {
      this.phase = 'failed';
      this.errorCode = 'internal';
      this.degradationReasons = [];
      this.elapsedMs = 0;
      this.firstFrameSeen = false;
      this.sessionGeneration = 0;
      this.sessionStartedAtMs = 0;
      this.showConnectStage = true;
      this.clearElapsedTimer();
      return;
    }
    if (snapshot.generation !== this.sessionGeneration) {
      this.sessionGeneration = snapshot.generation;
      this.sessionStartedAtMs = Date.now();
      this.elapsedMs = 0;
    }
    this.phase = snapshot.phase;
    this.errorCode = snapshot.errorCode;
    this.degradationReasons = snapshot.degradationReasons.slice();
    this.firstFrameSeen = snapshot.firstFrameSeen;
    this.showConnectStage = !snapshot.firstFrameSeen && snapshot.phase !== 'streaming';
    if (this.sessionStartedAtMs > 0) {
      this.elapsedMs = Math.max(0, Date.now() - this.sessionStartedAtMs);
    }
    if (this.showConnectStage && snapshot.phase !== 'failed' && snapshot.phase !== 'disconnected') {
      this.scheduleElapsedTick();
    } else {
      this.clearElapsedTimer();
    }
  }

  private scheduleElapsedTick(): void {
    if (!this.pageActive || this.elapsedTimer >= 0 || this.sessionStartedAtMs <= 0 ||
      this.firstFrameSeen || this.phase === 'failed' || this.phase === 'disconnected') {
      return;
    }
    this.elapsedTimer = setTimeout((): void => {
      this.elapsedTimer = -1;
      if (!this.pageActive || this.sessionStartedAtMs <= 0) { return; }
      this.elapsedMs = Math.max(0, Date.now() - this.sessionStartedAtMs);
      this.scheduleElapsedTick();
    }, 250);
  }

  private clearElapsedTimer(): void {
    if (this.elapsedTimer >= 0) {
      clearTimeout(this.elapsedTimer);
      this.elapsedTimer = -1;
    }
  }

  private cancelConnection(): void {
    const result = this.sessionCoordinator.cancelForRoute(
      this.hostId, this.appId, 'connect-stage-cancel');
    if (result.code === 'stop_requested') {
      promptAction.showToast({ message: '正在安全取消连接', duration: 1400 });
    }
    this.flushInput('cancel_connect');
    router.back();
  }

  private retryConnection(): void {
    promptAction.showToast({ message: '请返回应用目录重新建立安全启动租约', duration: 2000 });
  }

  private flushInput(reason: string): void {
    this.inputFlushCount += 1;
    this.ctrlLatch = 'off'; this.altLatch = 'off'; this.shiftLatch = 'off'; this.winLatch = 'off';
    this.fnLayer = false;
    hilog.info(0x0014, 'MoonlightStreamUi',
      'dormant UI input flush reason=' + reason + ' count=' + this.inputFlushCount.toString());
  }

  private pipAvailable(): boolean {
    return this.pipRuntimeAvailable && this.liveViewEnabled && this.liveViewMode === 1;
  }

  private openSheet(mode: MoonlightSessionSheetMode): void {
    this.flushInput('open_l5_' + mode);
    if (this.showSessionSheet) {
      this.pendingSheetMode = mode;
      this.showSessionSheet = false;
      return;
    }
    this.sheetMode = mode;
    this.showSessionSheet = true;
  }

  private closeSheet(): void {
    this.pendingSheetMode = 'none';
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.showSessionSheet = false;
  }

  private cancelSheetReopen(): void {
    if (this.sheetReopenTimer >= 0) {
      clearTimeout(this.sheetReopenTimer);
      this.sheetReopenTimer = -1;
    }
  }

  private onSheetDisappear(): void {
    if (this.pendingSheetMode !== 'none') {
      const next: MoonlightSessionSheetMode = this.pendingSheetMode;
      this.pendingSheetMode = 'none';
      this.sheetMode = next;
      const generation: number = this.sheetReopenGeneration;
      this.cancelSheetReopen();
      this.sheetReopenTimer = setTimeout((): void => {
        this.sheetReopenTimer = -1;
        if (this.pageActive && generation === this.sheetReopenGeneration) {
          this.showSessionSheet = true;
        }
      }, 0);
      return;
    }
    this.sheetMode = 'none';
  }

  private toolbarAction(action: MoonlightToolbarAction): void {
    if (action === 'more') { this.openSheet('control'); return; }
    if (action === 'disconnect') { this.openSheet('stop'); return; }
    if (action === 'controller') {
      this.flushInput('open_controller'); this.showController = true; return;
    }
    if (action === 'keyboard') {
      this.flushInput('open_keyboard');
      promptAction.showToast({ message: '虚拟键盘将在真实会话输入 owner 就绪后打开', duration: 1800 });
      return;
    }
    if (action === 'control') {
      this.controlMode = this.controlMode === 'touch' ? 'trackpad' : 'touch';
      this.sessionChanges += 1;
      promptAction.showToast({ message: '已切换为' + (this.controlMode === 'touch' ? '直接触控' : '触控板'),
        duration: 1400 });
      return;
    }
    if (action === 'audio') { this.muted = !this.muted; this.sessionChanges += 1; return; }
    if (action === 'display') {
      promptAction.showToast({ message: '首帧与系统 PIP 能力通过后可用', duration: 1800 });
    }
  }

  private modifierNext(current: string): string {
    if (current === 'off') { return 'once'; }
    if (current === 'once') { return 'locked'; }
    return 'off';
  }

  private toggleModifier(mod: string): void {
    if (mod === 'ctrl') { this.ctrlLatch = this.modifierNext(this.ctrlLatch); }
    else if (mod === 'alt') { this.altLatch = this.modifierNext(this.altLatch); }
    else if (mod === 'shift') { this.shiftLatch = this.modifierNext(this.shiftLatch); }
    else if (mod === 'win') { this.winLatch = this.modifierNext(this.winLatch); }
  }

  @Builder private controlCenterSheet() {
    MoonlightControlCenter({
      hostName: this.hostId || '未绑定主机', appName: this.appId || 'Moonlight UI',
      durationLabel: '00:00', negotiatedSummary: '运行时未开放',
      controlMode: this.controlMode, muted: this.muted, volume: this.volume,
      scaleMode: this.scaleMode, latencyMode: this.latencyMode,
      diagnosticsEnabled: this.showDiagnostics, sessionChangeCount: this.sessionChanges,
      pipAvailable: this.pipAvailable(), controllerAvailable: false,
      onClose: (): void => { this.closeSheet(); },
      onOpenKeyboard: (): void => { this.closeSheet(); this.toolbarAction('keyboard'); },
      onOpenModifiers: (): void => {
        this.closeSheet(); this.flushInput('open_modifier_panel'); this.showModifierPanel = true;
      },
      onCopyDiagnostics: (): void => {
        this.closeSheet();
        promptAction.showToast({ message: '暂无真实会话指标，未复制任何敏感信息', duration: 1600 });
      },
      onOpenController: (): void => { this.closeSheet(); this.toolbarAction('controller'); },
      onControlMode: (mode: MoonlightControlMode): void => {
        this.controlMode = mode; this.sessionChanges += 1;
      },
      onToggleMute: (): void => { this.muted = !this.muted; this.sessionChanges += 1; },
      onVolume: (value: number): void => { this.volume = value; this.sessionChanges += 1; },
      onScaleMode: (mode: string): void => { this.scaleMode = mode; this.sessionChanges += 1; },
      onLatencyMode: (mode: string): void => { this.latencyMode = mode; this.sessionChanges += 1; },
      onToggleDiagnostics: (): void => { this.showDiagnostics = !this.showDiagnostics; },
      onReconnect: (): void => { this.closeSheet(); this.flushInput('reconnect'); this.showReconnectMask = true; },
      onDisconnect: (): void => { this.openSheet('stop'); },
      onQuitHostApp: (): void => { this.openSheet('stop'); },
      onSaveProfile: (): void => {
        promptAction.showToast({ message: '真实会话 profile owner 就绪后可保存', duration: 1800 });
      }
    })
  }

  @Builder private stopSheet() {
    Column() {
      Text('结束 Moonlight 串流？').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
      Text('默认只断开本地串流并保留主机应用。主机退出结果不阻塞本地资源清理。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).margin({ top: 8 })
      Button('仅断开并保留主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 20 })
        .onClick((): void => {
          this.flushInput('disconnect_local'); this.closeSheet(); router.back();
        })
      Button('同时退出主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.pal().danger + '16').fontColor(this.pal().danger).margin({ top: 9 })
        .onClick((): void => {
          this.flushInput('quit_host_app'); this.closeSheet(); router.back();
        })
      Button('取消').height(42).width('100%').borderRadius(12).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).margin({ top: 9 })
        .onClick((): void => { this.closeSheet(); })
    }.width('100%').padding(22).backgroundColor(this.pal().sheetBg)
      .borderRadius({ topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
      .border({ width: 0.5, color: this.pal().cardBorder })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder private sessionSheet() {
    if (this.sheetMode === 'control') { this.controlCenterSheet() }
    else if (this.sheetMode === 'stop') { this.stopSheet() }
    else { Column().width('100%').height(1) }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: this.xcId, type: XComponentType.SURFACE,
        libraryname: 'rdpnapi', controller: this.xComponentController })
        .width('100%').height('100%').backgroundColor('#000000')
        .focusable(false).focusOnTouch(false)
        .onLoad(this.onMoonlightXComponentLoad)
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Math.max(1, Math.round(vp2px(newArea.width as number)));
          const height: number = Math.max(1, Math.round(vp2px(newArea.height as number)));
          this.surfaceWidthPx = width; this.surfaceHeightPx = height;
          if (this.rendererHandle > 0) {
            try { rdpnapi.resizeRenderer(this.rendererHandle, width, height); } catch (_) {}
          }
        })

      if (this.showAudioBanner) {
        Row() {
          SymbolGlyph($r('sys.symbol.speaker_slash_fill')).fontSize(16).fontColor(['#FFFFFF'])
          Text('音频已暂停：其他应用正在播放').fontSize(11).fontColor('#FFFFFF').margin({ left: 8 })
          Button('恢复').height(30).fontSize(10).borderRadius(9).margin({ left: 10 })
            .backgroundColor('rgba(255,255,255,0.14)').fontColor('#FFFFFF')
            .onClick((): void => { this.showAudioBanner = false; })
        }.padding({ left: 12, right: 8, top: 7, bottom: 7 })
          .backgroundColor('rgba(14,18,28,0.86)').borderRadius(13).position({ x: 20, y: 22 })
      }

      if (this.showNetworkBanner) {
        Row() {
          Column() {
            Text('网络持续波动').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            Text('可降低码率或打开诊断').fontSize(10).fontColor('rgba(255,255,255,0.62)').margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start)
          Button('降低码率').height(32).fontSize(10).borderRadius(9).margin({ left: 12 })
            .backgroundColor(this.accentColor).fontColor('#FFFFFF')
            .onClick((): void => { this.sessionChanges += 1; this.showNetworkBanner = false; })
        }.padding(10).backgroundColor('rgba(14,18,28,0.88)').borderRadius(13).position({ x: 20, y: 70 })
      }

      MoonlightSessionToolbar({
        audioAvailable: false, controllerAvailable: false, pipAvailable: this.pipAvailable(),
        menuOpen: this.showSessionSheet,
        qualityColor: this.showReconnectMask ? '#FFCF70' : '#66DD7A',
        qualityLabel: this.showReconnectMask ? '正在重连' : '良好',
        onAction: (action: MoonlightToolbarAction): void => { this.toolbarAction(action); },
        onUnavailable: (reason: string): void => {
          promptAction.showToast({ message: reason, duration: 1800 });
        }
      }).align(this.toolbarLayout().edgeRail ? Alignment.TopEnd : Alignment.Top)
        .margin({ top: this.toolbarLayout().topOffset,
          right: this.toolbarLayout().edgeRail ? 4 : 0 })

      RemoteModifierHandle({
        handleX: 0, handleY: 330, handleSide: 'left', panelVisible: this.showModifierPanel,
        ctrlLocked: this.ctrlLatch === 'locked', altLocked: this.altLatch === 'locked',
        shiftLocked: this.shiftLatch === 'locked', winLocked: this.winLatch === 'locked',
        fnLayer: this.fnLayer,
        onTogglePanel: (): void => { this.flushInput('toggle_modifier'); this.showModifierPanel = !this.showModifierPanel; },
        onLongPress: (): void => { this.flushInput('toggle_shortcuts'); this.showShortcutPanel = !this.showShortcutPanel; }
      })

      RemoteModifierPanel({
        visible: this.showModifierPanel, shortcutVisible: this.showShortcutPanel, attachSide: 'left',
        ctrlLatch: this.ctrlLatch, altLatch: this.altLatch, shiftLatch: this.shiftLatch,
        winLatch: this.winLatch, fnLayer: this.fnLayer, panelX: 60, panelY: 300,
        shortcutX: 60, shortcutY: 180,
        onClose: (): void => { this.flushInput('close_modifier'); this.showModifierPanel = false; },
        onCloseShortcut: (): void => { this.flushInput('close_shortcut'); this.showShortcutPanel = false; },
        onToggleModifier: (mod: string): void => { this.toggleModifier(mod); },
        onLockModifier: (mod: string): void => { this.toggleModifier(mod); this.toggleModifier(mod); },
        onToggleFnLayer: (): void => { this.fnLayer = !this.fnLayer; },
        onKeyTap: (_keyCode: number, label: string): void => {
          promptAction.showToast({ message: label + '：运行时未连接，不发送按键', duration: 1200 });
        },
        onShortcutTap: (_keyCodes: number[], label: string): void => {
          promptAction.showToast({ message: label + '：运行时未连接，不发送组合键', duration: 1200 });
        }
      })

      if (this.showDiagnostics) {
        MoonlightDiagnosticsHud({
          snapshot: EMPTY_SNAPSHOT, expanded: this.diagnosticsExpanded,
          x: this.diagnosticsX, y: this.diagnosticsY,
          onToggle: (): void => { this.diagnosticsExpanded = !this.diagnosticsExpanded; },
          onPositionChange: (x: number, y: number): void => {
            this.diagnosticsX = Math.max(0, x); this.diagnosticsY = Math.max(0, y);
          },
          onCopySanitized: (): void => {
            promptAction.showToast({ message: '暂无真实会话指标', duration: 1600 });
          }
        })
      }

      if (this.showController) {
        MoonlightControllerOverlay({
          inputCapabilityReady: false, editing: this.controllerEditing,
          physicalControllerName: '', physicalControllerSlot: -1, sourceGeneration: 0,
          onSemanticState: (_state: MoonlightControllerSemanticState): void => {},
          onEditToggle: (): void => {
            this.flushInput('controller_edit'); this.controllerEditing = !this.controllerEditing;
          },
          onClose: (): void => {
            this.flushInput('controller_close'); this.showController = false;
          }
        })
      }

      if (this.showReconnectMask) {
        Column() {
          Text('画面已暂停').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Text('正在停止旧 generation，输入已冻结').fontSize(11)
            .fontColor('rgba(255,255,255,0.68)').margin({ top: 6 })
          Row({ space: 10 }) {
            Button('立即重试').height(40).fontSize(12).borderRadius(11)
              .backgroundColor(this.accentColor).fontColor('#FFFFFF')
              .onClick((): void => { this.showReconnectMask = false; })
            Button('退出').height(40).fontSize(12).borderRadius(11)
              .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
              .onClick((): void => { this.openSheet('stop'); })
          }.margin({ top: 14 })
        }.width('82%').constraintSize({ maxWidth: 440 }).padding(20)
          .backgroundColor('rgba(14,18,28,0.92)').borderRadius(20)
          .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
      }

      if (this.showConnectStage) {
        MoonlightConnectStageOverlay({
          phase: this.phase, elapsedMs: this.elapsedMs, firstFrameSeen: this.firstFrameSeen,
          errorCode: this.errorCode, degradationReasons: this.degradationReasons,
          onCancel: (): void => { this.cancelConnection(); },
          onRetry: (): void => { this.retryConnection(); },
          onDowngradeRetry: (): void => { this.retryConnection(); },
          onOpenDiagnostics: (): void => { this.showDiagnostics = true; },
          onBackToCatalog: (): void => { this.flushInput('back_to_catalog'); router.back(); }
        })
      }
    }.width('100%').height('100%').backgroundColor('#000000')
      .bindSheet($$this.showSessionSheet, this.sessionSheet(), {
        height: this.sheetMode === 'control' ? '86%' : SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false, showClose: false,
        onDisappear: (): void => { this.onSheetDisappear(); }
      })
  }
}
