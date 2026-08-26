import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import {
  RemoteSessionWindowCoordinator,
  RemoteSessionWindowRecord
} from '../services/RemoteSessionWindowCoordinator';

@Entry
@Component
struct RemoteSessionWindowBootstrap {
  @State errorMessage: string = '';
  private sessionWindowId: string = '';
  private routing: boolean = false;

  aboutToAppear(): void {
    if (this.routing) { return; }
    this.routing = true;
    const storage: LocalStorage | undefined = this.getUIContext().getSharedLocalStorage();
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

  private closeWindow(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    void context.terminateSelf();
  }

  build() {
    Column({ space: 18 }) {
      if (this.errorMessage.length === 0) {
        LoadingProgress().width(40).height(40)
        Text('正在打开独立会话窗口…').fontSize(16).fontColor('#667085')
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
