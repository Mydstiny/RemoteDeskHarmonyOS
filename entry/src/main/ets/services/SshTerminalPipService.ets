/**
 * SSH terminal PiP owner.
 *
 * SSH renders through ArkUI Canvas, so it cannot share the video PiP surface
 * owned by RemoteSessionPipService. This PiP exposes only a compact public
 * status through customUIController; the SSH socket remains owned by the
 * native detached session.
 */
import { PiPWindow, BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sshDiagnosticErrorCode } from './ssh/observability/SshDiagnosticPolicy';
import { sshPipPublicStatus } from './ssh/observability/SshPipPrivacyPolicy';

const TAG = 'SshTerminalPip';
const DOMAIN = 0x0017;
const PIP_STATE_TIMEOUT_MS = 5000;

export interface SshTerminalPipInfo {
  status: string;
}

type SshPipStoppedHandler = (reason: string) => void;

@Builder
function SshTerminalPipContent(info: SshTerminalPipInfo): void {
  Column() {
    Row() {
      Text('SSH')
        .fontSize(13)
        .fontColor('#9BE7FF')
        .fontWeight(FontWeight.Bold)
      Blank()
      Text(info.status)
        .fontSize(11)
        .fontColor('#A7F3B1')
        .maxLines(1)
    }
    .width('100%')
    .height(24)

    Text('SSH 会话已保留')
      .width('100%')
      .fontSize(16)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .maxLines(1)

    Text('返回应用查看终端内容')
      .width('100%')
      .fontSize(11)
      .fontColor('#AAB4C0')
      .maxLines(1)
  }
  .width('100%')
  .height('100%')
  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
  .backgroundColor('#111820')
}

/** Required PiP component owner; SSH does not attach a video surface. */
class SshTerminalPipComponentController extends XComponentController {
}

class SshTerminalPipUiController extends NodeController {
  private builderNode: BuilderNode<[SshTerminalPipInfo]> | null = null;
  private info: SshTerminalPipInfo;

  constructor(info: SshTerminalPipInfo) {
    super();
    this.info = info;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    const builder: BuilderNode<[SshTerminalPipInfo]> =
      new BuilderNode<[SshTerminalPipInfo]>(uiContext);
    builder.build(wrapBuilder(SshTerminalPipContent), this.info);
    this.builderNode = builder;
    return builder.getFrameNode();
  }

  update(info: SshTerminalPipInfo): void {
    this.info = info;
    if (this.builderNode !== null) {
      this.builderNode.update(this.info);
    }
  }

  dispose(): void {
    if (this.builderNode !== null) {
      try {
        this.builderNode.dispose();
      } catch (_err) {
        // Best effort; WMS may already own the node teardown.
      }
      this.builderNode = null;
    }
  }
}

export class SshTerminalPipService {
  private static instance: SshTerminalPipService | null = null;
  private controller: PiPWindow.PiPController | null = null;
  private componentController: SshTerminalPipComponentController | null = null;
  private customUiController: SshTerminalPipUiController | null = null;
  private prepared: boolean = false;
  private active: boolean = false;
  private lastState: PiPWindow.PiPState | null = null;
  private stateCallback: ((state: PiPWindow.PiPState, reason: string) => void) | null = null;
  private stoppedHandler: SshPipStoppedHandler | null = null;
  private operationGeneration: number = 0;
  private operationTail: Promise<void> = Promise.resolve();
  private prepareRequestCount: number = 0;

  static getInstance(): SshTerminalPipService {
    if (SshTerminalPipService.instance === null) {
      SshTerminalPipService.instance = new SshTerminalPipService();
    }
    return SshTerminalPipService.instance;
  }

  async prepare(context: common.UIAbilityContext, info: SshTerminalPipInfo,
    onStopped: SshPipStoppedHandler | null = null): Promise<boolean> {
    this.prepareRequestCount++;
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      try {
        return await this.prepareInternal(context, info, onStopped);
      } finally {
        this.prepareRequestCount = Math.max(0, this.prepareRequestCount - 1);
      }
    });
  }

  private async prepareInternal(context: common.UIAbilityContext,
    info: SshTerminalPipInfo, onStopped: SshPipStoppedHandler | null): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'SSH PiP unsupported or disabled');
      return false;
    }
    const nextInfo: SshTerminalPipInfo = this.normalizedInfo(info);
    this.stoppedHandler = onStopped;
    if (this.prepared && this.controller !== null) {
      // A controller with no lifecycle transition is still the foreground
      // registration and can be reused for another SSH tab. STARTED and
      // restore/stop states belong to the previous background cycle; reusing
      // that controller makes the next auto-start fail as a repeated or
      // abnormal PiP operation.
      if (!this.active && this.lastState === null) {
        this.customUiController?.update(nextInfo);
        return true;
      }
      hilog.info(DOMAIN, TAG, 'SSH PiP retiring previous cycle state=' +
        (this.lastState === null ? 'none' : this.lastState.toString()) +
        ' active=' + this.active.toString());
      if (!(await this.stopInternal())) {
        return false;
      }
      this.stoppedHandler = onStopped;
    }
    if (this.controller !== null) {
      if (!(await this.stopInternal())) {
        return false;
      }
      this.stoppedHandler = onStopped;
    }

    const generation: number = this.operationGeneration;
    let created: PiPWindow.PiPController | null = null;
    const component: SshTerminalPipComponentController =
      new SshTerminalPipComponentController();
    const customUi: SshTerminalPipUiController = new SshTerminalPipUiController(nextInfo);
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: component,
        // API 23 exposes these PiP templates only. The actual SSH content is
        // custom UI; no video renderer or media session is claimed here.
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: 800,
        contentHeight: 450,
        customUIController: customUi,
        defaultWindowSizeType: 1,
        cornerAdsorptionEnabled: true
      };
      created = await PiPWindow.create(config);
      if (generation !== this.operationGeneration) {
        this.disposeCreatedController(created, customUi);
        return false;
      }
      this.controller = created;
      this.componentController = component;
      this.customUiController = customUi;
      this.prepared = true;
      this.active = false;
      this.lastState = null;
      const callback: (state: PiPWindow.PiPState, reason: string) => void =
        (state: PiPWindow.PiPState, reason: string): void => {
          this.handleStateChange(created as PiPWindow.PiPController, state, reason);
        };
      this.stateCallback = callback;
      created.on('stateChange', callback);
      created.setAutoStartEnabled(true);
      hilog.info(DOMAIN, TAG, 'SSH PiP prepared for background auto-start');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SSH PiP prepare failed code=' + sshDiagnosticErrorCode(err));
      if (created !== null) {
        this.disposeCreatedController(created, customUi);
      } else {
        customUi.dispose();
      }
      this.clearState();
      return false;
    }
  }

  async start(): Promise<boolean> {
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      if (!this.prepared || this.controller === null) {
        hilog.warn(DOMAIN, TAG, 'SSH PiP start skipped: no foreground controller');
        return false;
      }
      if (this.active || this.lastState === PiPWindow.PiPState.STARTED) {
        this.active = true;
        return true;
      }
      const owner: PiPWindow.PiPController = this.controller;
      const startedAt: number = Date.now();
      while (this.controller === owner && !this.active &&
        !this.isTerminalState(this.lastState) &&
        Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 40);
        });
      }
      if (this.controller !== owner || this.active) {
        return this.active;
      }
      hilog.warn(DOMAIN, TAG, 'SSH PiP auto-start did not reach STARTED');
      await this.stopInternal();
      return false;
    });
  }

  update(info: SshTerminalPipInfo): void {
    if (!this.prepared || this.controller === null || this.customUiController === null) {
      return;
    }
    this.customUiController.update(this.normalizedInfo(info));
  }

  async stop(): Promise<boolean> {
    return this.enqueueOperation<boolean>(() => this.stopInternal());
  }

  isPrepared(): boolean {
    return this.prepared && this.controller !== null;
  }

  isPreparedOrPreparing(): boolean {
    return this.isPrepared() || this.prepareRequestCount > 0;
  }

  isActive(): boolean {
    return this.active && this.controller !== null;
  }

  private handleStateChange(owner: PiPWindow.PiPController,
    state: PiPWindow.PiPState, reason: string): void {
    if (this.controller !== owner) {
      return;
    }
    this.lastState = state;
    hilog.info(DOMAIN, TAG, 'SSH PiP state=' + state.toString() + ' reason=' + reason);
    if (state === PiPWindow.PiPState.STARTED) {
      this.active = true;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_START ||
      state === PiPWindow.PiPState.ABOUT_TO_STOP ||
      state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      this.active = false;
      return;
    }
    if (this.isTerminalState(state)) {
      this.cleanupController(owner, reason, true);
    }
  }

  private async stopInternal(): Promise<boolean> {
    this.operationGeneration++;
    const owner: PiPWindow.PiPController | null = this.controller;
    if (owner === null) {
      this.clearState();
      return true;
    }
    this.stoppedHandler = null;
    try {
      owner.setAutoStartEnabled(false);
    } catch (_err) {
      // Continue with best-effort teardown.
    }
    if (this.lastState === null && !this.active) {
      this.cleanupController(owner, 'requestDelete', false);
      return true;
    }
    if (this.isTerminalState(this.lastState)) {
      this.cleanupController(owner, 'requestDelete', false);
      return true;
    }
    if (this.lastState === PiPWindow.PiPState.ABOUT_TO_START) {
      const settled: boolean = await this.reconcileStartedOwner(owner);
      if (!settled) {
        return false;
      }
    }
    if (this.controller !== owner || this.isTerminalState(this.lastState)) {
      return true;
    }
    if (this.lastState === PiPWindow.PiPState.ABOUT_TO_STOP ||
      this.lastState === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      // WMS already owns this transition. Calling stopPiP() again produces
      // 1300012/1300015 on the second foreground/background cycle. Wait for
      // STOPPED, then reconcile a missed callback with API 23 isPiPActive().
      if (await this.waitForTerminal(owner)) {
        if (this.controller === owner) {
          this.cleanupController(owner, 'transitionComplete', false);
        }
        return true;
      }
      if (await this.cleanupInactiveOwner(owner, 'transitionReconciled')) { return true; }
      hilog.warn(DOMAIN, TAG, 'SSH PiP previous transition did not finish');
      return false;
    }
    try {
      await owner.stopPiP();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SSH PiP stop failed code=' + sshDiagnosticErrorCode(err));
      return false;
    }
    const terminal: boolean = await this.waitForTerminal(owner);
    if (!terminal) {
      if (await this.cleanupInactiveOwner(owner, 'stopReconciled')) { return true; }
      return false;
    }
    if (this.controller === owner) {
      this.cleanupController(owner, 'requestDelete', false);
    }
    return true;
  }

  /**
   * API 23 can expose an active custom PiP while its last callback is still
   * ABOUT_TO_START. Probe WMS before waiting so an explicit exit can issue
   * stopPiP() while the foreground page and controller are still alive.
   */
  private async reconcileStartedOwner(owner: PiPWindow.PiPController): Promise<boolean> {
    try {
      if (await owner.isPiPActive()) {
        if (this.controller !== owner) { return true; }
        this.active = true;
        this.lastState = PiPWindow.PiPState.STARTED;
        hilog.info(DOMAIN, TAG, 'SSH PiP start reconciled from active probe');
        return true;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SSH PiP start probe failed code=' +
        sshDiagnosticErrorCode(err));
    }
    return this.waitForStart(owner);
  }

  /** Reconcile API 23 transitions that complete without a terminal callback. */
  private async cleanupInactiveOwner(owner: PiPWindow.PiPController,
    reason: string): Promise<boolean> {
    try {
      if (await owner.isPiPActive()) { return false; }
      if (this.controller === owner) {
        this.cleanupController(owner, reason, false);
      }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SSH PiP inactive probe failed code=' +
        sshDiagnosticErrorCode(err));
      return false;
    }
  }

  private async waitForStart(owner: PiPWindow.PiPController): Promise<boolean> {
    const startedAt: number = Date.now();
    while (this.controller === owner &&
      this.lastState === PiPWindow.PiPState.ABOUT_TO_START &&
      Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    return this.controller !== owner || this.lastState === PiPWindow.PiPState.STARTED ||
      this.isTerminalState(this.lastState);
  }

  private async waitForTerminal(owner: PiPWindow.PiPController): Promise<boolean> {
    const startedAt: number = Date.now();
    while (this.controller === owner && !this.isTerminalState(this.lastState) &&
      Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    return this.controller !== owner || this.isTerminalState(this.lastState);
  }

  private cleanupController(owner: PiPWindow.PiPController,
    reason: string, notifyStopped: boolean): void {
    if (this.controller !== owner) {
      return;
    }
    const handler: SshPipStoppedHandler | null = notifyStopped ? this.stoppedHandler : null;
    const customUi: SshTerminalPipUiController | null = this.customUiController;
    this.clearState();
    try {
      owner.off('stateChange');
    } catch (_err) {
      // Best effort listener cleanup.
    }
    if (handler !== null) {
      handler(reason);
    }
    if (customUi !== null) {
      customUi.dispose();
    }
  }

  private disposeCreatedController(controller: PiPWindow.PiPController,
    customUi: SshTerminalPipUiController): void {
    try {
      controller.setAutoStartEnabled(false);
    } catch (_err) {
      // Best effort.
    }
    try {
      controller.off('stateChange');
    } catch (_err) {
      // Best effort.
    }
    customUi.dispose();
  }

  private clearState(): void {
    this.controller = null;
    this.componentController = null;
    this.customUiController = null;
    this.prepared = false;
    this.active = false;
    this.lastState = null;
    this.stateCallback = null;
    this.stoppedHandler = null;
  }

  private normalizedInfo(info: SshTerminalPipInfo): SshTerminalPipInfo {
    return {
      status: sshPipPublicStatus(info.status)
    };
  }

  private isTerminalState(state: PiPWindow.PiPState | null): boolean {
    return state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR;
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(operation, operation);
    this.operationTail = queued.then((): void => undefined, (): void => undefined);
    return queued;
  }
}
