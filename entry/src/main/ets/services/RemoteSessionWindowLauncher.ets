import { bundleManager, common, StartOptions, Want } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteSessionWindowCoordinator,
  RemoteSessionWindowNativeHandoff
} from './RemoteSessionWindowCoordinator';
import {
  RemoteSessionWindowRequest,
  REMOTE_SESSION_WINDOW_MIN_HEIGHT_VP,
  REMOTE_SESSION_WINDOW_MIN_WIDTH_VP,
  remoteSessionWindowPlacement,
  remoteSessionWindowRequestIsValid
} from './RemoteSessionWindowPolicy';
import {
  RemoteSessionWindowAuthorizationProof,
  RemoteSessionWindowAuthorizationService,
  remoteSessionWindowAuthorizationRequiresLiveHandoff
} from './RemoteSessionWindowAuthorization';
import { REMOTE_SESSION_WINDOW_READY_TIMEOUT_MS } from './RemoteSessionWindowReadiness';

const DOMAIN: number = 0x0025;
const TAG: string = 'SessionWindowLaunch';

export class RemoteSessionWindowLauncher {
  static async open(context: common.UIAbilityContext,
    request: RemoteSessionWindowRequest,
    nativeHandoff: RemoteSessionWindowNativeHandoff | null = null): Promise<boolean> {
    if (!remoteSessionWindowRequestIsValid(request)) { return false; }
    const proof: RemoteSessionWindowAuthorizationProof | null =
      RemoteSessionWindowAuthorizationService.getInstance().consume(
        request.authorizationToken, request.protocol, request.hostId);
    if (proof === null) {
      hilog.warn(DOMAIN, TAG,
        'independent session window rejected: missing/expired authorization');
      return false;
    }
    const liveHandoffRequired: boolean =
      remoteSessionWindowAuthorizationRequiresLiveHandoff(proof.kind);
    if (liveHandoffRequired && nativeHandoff === null) {
      hilog.warn(DOMAIN, TAG,
        'independent session window rejected: authenticated native handoff missing');
      return false;
    }
    const coordinator: RemoteSessionWindowCoordinator =
      RemoteSessionWindowCoordinator.getInstance();
    const record = coordinator.reserve(request, nativeHandoff);
    if (record === null) { return false; }
    let densityPixels: number = 1;
    try {
      densityPixels = Math.max(1, display.getDefaultDisplaySync().densityPixels);
    } catch (_err) {}
    const placement = remoteSessionWindowPlacement(
      coordinator.nextPlacementSequence() - 1, densityPixels);
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      moduleName: context.abilityInfo.moduleName,
      abilityName: 'RemoteSessionAbility',
      parameters: { sessionWindowId: record.id }
    };
    const options: StartOptions = {
      // The system launch scale races the first native surface geometry on
      // PC/2-in-1. Start at its final rect and let later window operations use
      // the platform title-bar animation.
      withAnimation: false,
      windowLeft: placement.left,
      windowTop: placement.top,
      windowWidth: placement.width,
      windowHeight: placement.height,
      minWindowWidth: REMOTE_SESSION_WINDOW_MIN_WIDTH_VP,
      minWindowHeight: REMOTE_SESSION_WINDOW_MIN_HEIGHT_VP,
      supportWindowModes: [
        bundleManager.SupportWindowMode.FULL_SCREEN,
        bundleManager.SupportWindowMode.SPLIT,
        bundleManager.SupportWindowMode.FLOATING
      ]
    };
    try {
      await context.startAbility(want, options);
      hilog.info(DOMAIN, TAG,
        'independent session window requested protocol=%{public}s target=%{public}s',
        request.protocol, request.target);
      // Every target must cross the real route/content-ready boundary before
      // the source page releases its launch ownership.  Moonlight starts its
      // native session before opening the window but does not use the generic
      // nativeHandoff structure; returning immediately here used to orphan the
      // Sunshine launch when loadContent/replaceUrl failed.
      const ready: boolean = await coordinator.waitUntilContentReady(
        record.id, REMOTE_SESSION_WINDOW_READY_TIMEOUT_MS);
      // A timeout and a target ready callback can land on adjacent event-loop
      // turns. Recheck the committed record before attempting rollback.
      if (ready || coordinator.isContentReady(record.id)) {
        void coordinator.promoteTargetWindow(record.id);
        // The source route closes immediately after open() resolves. Reassert
        // the new native window once after that ArkUI transaction so the host
        // list cannot retain a stale input owner.
        setTimeout((): void => {
          void coordinator.promoteTargetWindow(record.id);
        }, 180);
        hilog.info(DOMAIN, TAG,
          'independent session window interactive protocol=%{public}s target=%{public}s',
          request.protocol, request.target);
        return true;
      }
      coordinator.failBeforeReady(record.id, 'target-readiness-timeout');
      hilog.error(DOMAIN, TAG,
        'independent session window readiness timeout protocol=%{public}s target=%{public}s',
        request.protocol, request.target);
      return false;
    } catch (err) {
      coordinator.rollbackReservation(record.id);
      hilog.error(DOMAIN, TAG, 'independent session window failed: %{public}s',
        JSON.stringify(err));
      return false;
    }
  }
}
