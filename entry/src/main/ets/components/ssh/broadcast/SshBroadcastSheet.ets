import {
  sshBroadcastTargetBlockReason,
  sshBroadcastTargetEligible,
  sshBroadcastTargetReasonText,
  SshBroadcastMode,
  SshBroadcastTargetV1
} from '../../../services/ssh/broadcast/SshBroadcastPolicy';

/**
 * High-risk, explicit multi-session input surface. It never owns native
 * sessions; the page revalidates every target before enqueueing bytes.
 */
@Component
export struct SshBroadcastSheet {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop targets: Array<SshBroadcastTargetV1> = [];
  @Prop selectedHostIds: Array<string> = [];
  @Prop text: string = '';
  @Prop mode: SshBroadcastMode = 'insert';
  @Prop active: boolean = false;
  onClose: () => void = (): void => {};
  onStop: () => void = (): void => {};
  onToggleTarget: (hostId: string, selected: boolean) => void =
    (_hostId: string, _selected: boolean): void => {};
  onTextChange: (value: string) => void = (_value: string): void => {};
  onModeChange: (mode: SshBroadcastMode) => void = (_mode: SshBroadcastMode): void => {};
  onSend: () => void = (): void => {};

  private targetSelected(hostId: string): boolean {
    return this.selectedHostIds.indexOf(hostId) >= 0;
  }

  @Builder
  private TargetList() {
    Column({ space: 6 }) {
      ForEach(this.targets, (target: SshBroadcastTargetV1): void => {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.targetSelected(target.hostId) })
            .selectedColor(this.accentColor)
            .enabled(sshBroadcastTargetEligible(target))
            .onChange((value: boolean): void => {
              this.onToggleTarget(target.hostId, value);
            })
          Column() {
            Text(target.label.length > 0 ? target.label : 'SSH 会话')
              .fontSize(12).fontColor('#F2F4F7').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(sshBroadcastTargetReasonText(
              sshBroadcastTargetBlockReason(target)))
              .fontSize(9)
              .fontColor(sshBroadcastTargetEligible(target) ? '#72D69A' : '#FFB56B')
              .margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%').constraintSize({ minHeight: 48 })
        .padding({ left: 10, right: 8 })
        .borderRadius(9)
        .backgroundColor(this.targetSelected(target.hostId) ?
          this.accentColor + '38' : 'rgba(255,255,255,0.045)')
      }, (target: SshBroadcastTargetV1): string => target.hostId)
      if (this.targets.length === 0) {
        Text('没有可见的 SSH 工作台会话；请先连接至少一个标签。')
          .fontSize(11).fontColor('rgba(242,244,247,0.50)').padding(10)
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('安全广播输入').fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor('#FFF3F0')
          Text('红色模式 · 新目标必须显式勾选 · 最多 16 个会话')
            .fontSize(10).fontColor('rgba(255,220,210,0.64)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('关闭').height(36).fontSize(11).backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
      Row({ space: 8 }) {
        Text('广播目标').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFF3F0')
          .layoutWeight(1)
        Button('立即停止').height(34).fontSize(10).fontColor('#FFFFFF')
          .backgroundColor('#B83B3B').onClick((): void => { this.onStop(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      Scroll() {
        Column({ space: 10 }) {
          this.TargetList()
          TextInput({ text: this.text, placeholder: '输入要插入或执行的内容' })
            .height(88).fontSize(12).fontColor('#F2F4F7')
            .placeholderColor('rgba(242,244,247,0.40)')
            .backgroundColor('rgba(255,255,255,0.07)').borderRadius(9)
            .enableAutoFill(false)
            .onChange((value: string): void => { this.onTextChange(value.slice(0, 4096)); })
          Row({ space: 8 }) {
            Button('只插入').height(40).layoutWeight(1).fontSize(11)
              .fontColor(this.mode === 'insert' ? '#FFFFFF' : 'rgba(242,244,247,0.72)')
              .backgroundColor(this.mode === 'insert' ? this.accentColor : 'rgba(255,255,255,0.08)')
              .onClick((): void => { this.onModeChange('insert'); })
            Button('确认执行').height(40).layoutWeight(1).fontSize(11)
              .fontColor(this.mode === 'execute' ? '#FFFFFF' : 'rgba(242,244,247,0.72)')
              .backgroundColor(this.mode === 'execute' ? '#B83B3B' : 'rgba(255,255,255,0.08)')
              .onClick((): void => { this.onModeChange('execute'); })
          }.width('100%')
          Text('认证、密码提示、raw/fullscreen 和非连接会话会自动排除。广播只提交到当前精确 sessionId/generation。')
            .fontSize(10).fontColor('rgba(255,220,210,0.64)').width('100%')
          Button('发送到已选会话').height(48).width('100%').fontSize(12)
            .fontColor('#FFFFFF').backgroundColor('#B83B3B')
            .enabled(this.selectedHostIds.length > 0 && this.text.trim().length > 0)
            .onClick((): void => { this.onSend(); })
        }.width('100%').padding({ left: 16, right: 16, bottom: 18 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor('#341A1A')
  }
}
