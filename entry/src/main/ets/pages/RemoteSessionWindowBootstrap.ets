import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import {
  RemoteSessionWindowCoordinator,
  RemoteSessionWindowRecord
} from '../services/RemoteSessionWindowCoordinator';
import { ProContinuationService, PRO_CONTINUATION_LIBRARY_PARAM } from '../services/pro/ProContinuationService';

@Entry
@Component
struct RemoteSessionWindowBootstrap {
  @State errorMessage: string = '';
  @State openingContinuation: boolean = false;
  private sessionWindowId: string = '';
  private routing: boolean = false;
  private live: boolean = false;

  aboutToAppear(): void {
    if (this.routing) { return; }
    this.routing = true;
    this.live = true;
    const storage: LocalStorage | undefined = this.getUIContext().getSharedLocalStorage();
    const continuationId: string = storage?.get<string>('proContinuationBootstrapId') ?? '';
    if (continuationId !== '') {
      this.openingContinuation = true;
      if (storage === undefined || !/^[a-f0-9]{32}$/.test(continuationId) ||
          ProContinuationService.getInstance().incomingId() !== continuationId) {
        this.errorMessage = '接续请求已失效，请在源端重新准备。本端没有建立远程连接。';
        return;
      }
      void this.openContinuationLibrary(continuationId, storage);
      return;
    }
    this.sessionWindowId = storage?.get<string>('sessionWindowId') ?? '';
    const record: RemoteSessionWindowRecord | null =
      RemoteSessionWindowCoordinator.getInstance().resolve(this.sessionWindowId);
    if (record === null || record.page.length === 0) {
      this.errorMessage = '会话窗口启动信息已失效，请从主机列表重新连接。';
      return;
    }
    const params: Record<string, Object> = {};
    Object.keys(record.request.routeParams).forEach((key: string): void => {
      params[key] = record.request.routeParams[key];
    });
    params['sessionWindowId'] = record.id;
    this.getUIContext().getRouter().replaceUrl({
      url: record.page,
      params
    }).then((): void => {
      // Route replacement is only the page-mount boundary. Live authenticated
      // sessions commit later from their real renderer/input ready callback.
      RemoteSessionWindowCoordinator.getInstance().markPageReady(record.id);
    }).catch((err: Error): void => {
      this.errorMessage = '无法装载远程会话页面。';
      promptAction.showToast({ message: this.errorMessage, duration: 2200 });
      this.routing = false;
      RemoteSessionWindowCoordinator.getInstance().failBeforeReady(
        record.id, 'target-route-load-failed');
    });
  }

  aboutToDisappear(): void { this.live = false; }

  private async openContinuationLibrary(id: string, storage: LocalStorage): Promise<void> {
    const service = ProContinuationService.getInstance();
    if (!this.live || service.incomingId() !== id) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const parameters: Record<string, Object> = {};
    parameters[PRO_CONTINUATION_LIBRARY_PARAM] = id;
    try {
      await context.startAbility({ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility',
        parameters });
    } catch (_error) {
      if (this.live) { this.errorMessage = '无法打开主机列表，请关闭此窗口后重试接续。源端仍保持连接。'; }
      return;
    }
    if (!this.live || service.incomingId() !== id) {
      if (this.live) { this.errorMessage = '接续请求已失效。源端仍保持连接。'; }
      return;
    }
    // Successful application launch is only a local handoff, never a remote
    // readiness receipt. The host library still requires explicit authentication.
    storage.set<boolean>('proContinuationForwarded', true);
    try { await context.terminateSelf(); }
    catch (_error) {
      if (this.live) { this.errorMessage = '已打开应用，请在主机列表确认接续；此窗口可以关闭。'; }
    }
  }

  private closeWindow(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    void context.terminateSelf();
  }

  build() {
    Column({ space: 18 }) {
      if (this.errorMessage.length === 0) {
        LoadingProgress().width(40).height(40)
        Text(this.openingContinuation ? '正在打开主机列表以确认接续…' : '正在打开独立会话窗口…')
          .fontSize(16).fontColor('#667085')
      } else {
        Text('无法打开会话').fontSize(22).fontWeight(FontWeight.Medium)
        Text(this.errorMessage).fontSize(15).fontColor('#667085').textAlign(TextAlign.Center)
        Button('关闭窗口').onClick((): void => { this.closeWindow(); })
      }
    }
    .width('100%')
    .height('100%')
    .padding(32)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#F7F8FA')
  }
}
