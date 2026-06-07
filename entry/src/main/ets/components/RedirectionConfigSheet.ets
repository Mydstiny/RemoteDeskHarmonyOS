import { GlassmorphicCard } from './GlassmorphicCard';
import { RedirectionConfig } from '../models/RemoteHost';

interface RedirectOption {
  key: keyof RedirectionConfig;
  label: string;
  description: string;
  icon: Resource;
  hasPath: boolean;
}

@Component
export struct RedirectionConfigSheet {
  @Prop config: RedirectionConfig = {
    clipboard: true, printer: false, microphone: false,
    camera: false, folder: false, folderPath: '', smartcard: false
  };
  @State currentConfig: RedirectionConfig = {
    clipboard: true, printer: false, microphone: false,
    camera: false, folder: false, folderPath: '', smartcard: false
  };
  @State folderPath: string = '';
  onChange?: (config: RedirectionConfig) => void;

  private options: RedirectOption[] = [
    { key: 'clipboard', label: '剪贴板', description: '共享剪贴板内容', icon: $r('app.media.ic_clipboard'), hasPath: false },
    { key: 'printer', label: '打印机', description: '远程打印机重定向', icon: $r('app.media.ic_printer'), hasPath: false },
    { key: 'microphone', label: '麦克风', description: '远程语音输入', icon: $r('app.media.ic_mic'), hasPath: false },
    { key: 'camera', label: '摄像头', description: '远程摄像头重定向', icon: $r('app.media.ic_camera'), hasPath: false },
    { key: 'folder', label: '文件夹', description: '共享本地文件夹', icon: $r('app.media.ic_folder'), hasPath: true },
    { key: 'smartcard', label: '智能卡', description: '智能卡设备重定向', icon: $r('app.media.ic_smartcard'), hasPath: false },
  ];

  aboutToAppear(): void {
    this.currentConfig = { ...this.config };
    this.folderPath = this.config.folderPath;
  }

  build() {
    Column() {
      Text('设备与资源重定向')
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .margin({ bottom: 16 })

      ForEach(this.options, (opt: RedirectOption) => {
        GlassmorphicCard({ borderRadius: 14, paddingSize: 14 }) {
          Column() {
            Row() {
              Column() {
                Image(opt.icon)
                  .width(28).height(28)
                  .fillColor('rgba(255,255,255,0.8)')
              }
              .width(40).height(40)
              .borderRadius(10)
              .backgroundColor('rgba(255,255,255,0.08)')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)

              Column() {
                Text(opt.label)
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
                  .margin({ left: 12 })
                Text(opt.description)
                  .fontSize(11).fontColor('rgba(255,255,255,0.4)')
                  .margin({ left: 12, top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({
                type: ToggleType.Switch,
                isOn: this.getToggleValue(opt.key)
              })
                .onChange((isOn: boolean) => {
                  this.setToggleValue(opt.key, isOn);
                  this.emitChange();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (opt.hasPath && this.getToggleValue(opt.key)) {
              Row() {
                TextInput({ placeholder: '选择文件夹路径...', text: this.folderPath })
                  .layoutWeight(1)
                  .height(36)
                  .backgroundColor('rgba(255,255,255,0.08)')
                  .fontColor('#FFFFFF')
                  .borderRadius(8)
                  .onChange((value: string) => {
                    this.folderPath = value;
                    this.currentConfig.folderPath = value;
                    this.emitChange();
                  })

                Button('浏览')
                  .height(36)
                  .borderRadius(8)
                  .backgroundColor('rgba(102,119,255,0.3)')
                  .fontColor('#6677ff')
                  .fontSize(12)
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.pickFolder();
                  })
              }
              .width('100%')
              .margin({ top: 10 })
            }
          }
          .width('100%')
        }
        .margin({ bottom: 8 })
      })
    }
    .width('100%')
    .padding(16)
  }

  private getToggleValue(key: keyof RedirectionConfig): boolean {
    if (key === 'folderPath') return false;
    return this.currentConfig[key] as boolean;
  }

  private setToggleValue(key: keyof RedirectionConfig, value: boolean): void {
    if (key === 'folderPath') return;
    (this.currentConfig[key] as boolean) = value;
  }

  private async pickFolder(): Promise<void> {
    try {
      const picker = await import('@kit.FileKit');
      const documentPicker = new picker.DocumentViewPicker();
      const result = await documentPicker.select([{ mimeType: '*' }]);
      if (result && result.length > 0) {
        this.folderPath = result[0];
        this.currentConfig.folderPath = result[0];
        this.emitChange();
      }
    } catch (err) {
      console.error('Folder picker failed: ' + err);
    }
  }

  private emitChange(): void {
    this.onChange?.({ ...this.currentConfig, folderPath: this.folderPath });
  }
}
