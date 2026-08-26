import {
  SshSessionLogDocumentV1,
  SshSessionLogSearchHitV1
} from '../../../services/ssh/log/SshSessionLogPolicy';

/**
 * Local SSH session-log surface. It only renders sanitized policy output and
 * emits actions; persistence and export authorization stay in SshTerminal.
 */
@Component
export struct SshSessionLogSheet {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop document: SshSessionLogDocumentV1;
  @Prop results: Array<SshSessionLogSearchHitV1>;
  @Prop ready: boolean = false;
  @Prop hostLabel: string = '';
  @Prop query: string = '';
  @State bookmarkNote: string = '';
  onClose: () => void = (): void => {};
  onSearchChange: (value: string) => void = (_value: string): void => {};
  onToggleEnabled: (value: boolean) => void = (_value: boolean): void => {};
  onTogglePaused: (value: boolean) => void = (_value: boolean): void => {};
  onToggleBookmark: (hit: SshSessionLogSearchHitV1, note: string) => void =
    (_hit: SshSessionLogSearchHitV1, _note: string): void => {};
  onExport: () => void = (): void => {};

  @Builder
  private SettingRow(label: string, detail: string, enabled: boolean,
    onChange: (value: boolean) => void) {
    Row() {
      Column() {
        Text(label).fontSize(12).fontColor('#F2F4F7')
        Text(detail).fontSize(10).fontColor('rgba(242,244,247,0.48)').margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor).onChange(onChange)
    }
    .width('100%').constraintSize({ minHeight: 48 })
    .padding({ left: 12, right: 8, top: 6, bottom: 6 })
    .borderRadius(10).backgroundColor('rgba(255,255,255,0.055)')
  }

  @Builder
  private ResultList() {
    Column({ space: 6 }) {
      ForEach(this.results.slice(0, 80), (hit: SshSessionLogSearchHitV1): void => {
        Row({ space: 8 }) {
          Column() {
            Text(hit.record.text).fontSize(11).fontFamily('monospace')
              .fontColor('#F2F4F7').maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            Text(new Date(hit.record.timestamp).toLocaleTimeString() + ' · ' + hit.record.direction)
              .fontSize(9).fontColor('rgba(242,244,247,0.45)').margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(hit.bookmarked ? '取消书签' : '书签').height(32).fontSize(10)
            .padding({ left: 8, right: 8 }).backgroundColor('rgba(255,255,255,0.08)')
            .onClick((): void => {
              this.onToggleBookmark(hit, this.bookmarkNote.slice(0, 256));
              this.bookmarkNote = '';
            })
        }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 10, right: 7 })
          .borderRadius(8).backgroundColor('rgba(255,255,255,0.035)')
      }, (hit: SshSessionLogSearchHitV1): string => hit.record.id)
      if (this.results.length === 0) {
        Text(this.ready ? '暂无匹配日志；日志默认关闭。' : '加密存储未解锁，日志功能已禁用')
          .fontSize(10).fontColor('rgba(242,244,247,0.45)').padding(10)
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('会话日志').fontSize(18).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
          Text(this.hostLabel.length > 0 ? this.hostLabel : '本地加密 · 默认关闭')
            .fontSize(10).fontColor('rgba(242,244,247,0.50)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('关闭').height(36).fontSize(11).backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
      TextInput({ text: this.query, placeholder: '搜索当前主机的脱敏日志' })
        .height(42).fontSize(12).fontColor('#F2F4F7')
        .placeholderColor('rgba(242,244,247,0.40)').backgroundColor('rgba(255,255,255,0.07)')
        .borderRadius(9).margin({ left: 16, right: 16, bottom: 10 })
        .enableAutoFill(false)
        .onChange((value: string): void => { this.onSearchChange(value.slice(0, 256)); })
      Scroll() {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Button('保存脱敏日志').height(40).fontSize(11).layoutWeight(1)
              .backgroundColor('rgba(255,255,255,0.08)').onClick(this.onExport)
            Text(this.document.chunks.length.toString() + ' 个分块')
              .fontSize(10).fontColor('rgba(242,244,247,0.48)')
          }.width('100%')
          TextInput({ text: this.bookmarkNote, placeholder: '书签备注（可选）' })
            .height(38).fontSize(11).fontColor('#F2F4F7')
            .placeholderColor('rgba(242,244,247,0.40)')
            .backgroundColor('rgba(255,255,255,0.07)').borderRadius(9)
            .onChange((value: string): void => { this.bookmarkNote = value.slice(0, 256); })
          this.SettingRow('记录会话日志', '仅本机加密保存；认证、密码和 raw/fullscreen 会自动暂停',
            this.document.settings.enabled, this.onToggleEnabled)
          this.SettingRow('暂停记录', '暂停期间不写入新内容，已有日志仍可搜索',
            this.document.settings.paused, this.onTogglePaused)
          Text('日志结果').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .width('100%')
          this.ResultList()
        }.width('100%').padding({ left: 16, right: 16, bottom: 18 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor('#171D25')
  }
}
