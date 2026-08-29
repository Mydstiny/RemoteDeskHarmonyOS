import {
  cloneSshTerminalProfile,
  emptySshTerminalProfileSettings,
  SshTerminalCursorStyle,
  SshTerminalFontFamily,
  SshTerminalProfileSettingsV1,
  SshTerminalProfileV1,
  SshTerminalResolvedProfile
} from '../../../services/ssh/profile/SshTerminalProfilePolicy';

const PROFILE_FOREGROUNDS: string[] = ['#33FF33', '#F2F4F7', '#7DD3FC', '#FACC15'];
const PROFILE_BACKGROUNDS: string[] = ['#0D0D0D', '#10151C', '#111827', '#1E1E2E'];
const PROFILE_FONT_FAMILIES: SshTerminalFontFamily[] =
  ['monospace', 'HarmonyOS Sans SC', 'Menlo', 'JetBrains Mono'];
const PROFILE_CURSOR_STYLES: SshTerminalCursorStyle[] = ['block', 'bar', 'underline'];
const PROFILE_SCROLLBACKS: number[] = [5000, 10000, 30000, 100000];

@Component
export struct SshTerminalProfileSheet {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop sheetBackgroundColor: string = '#171D25';
  @Prop profiles: SshTerminalProfileV1[] = [];
  @Prop resolvedProfile: SshTerminalResolvedProfile;
  @Prop globalProfileId: string = '';
  @Prop hostProfileId: string = '';
  @Prop sessionProfileId: string = '';
  @Prop hostLabel: string = '';
  onClose: () => void = (): void => {};
  onSaveProfile: (profile: SshTerminalProfileV1) => void =
    (_profile: SshTerminalProfileV1): void => {};
  onRemoveProfile: (profileId: string) => void = (_profileId: string): void => {};
  onSetGlobalProfile: (profileId: string) => void = (_profileId: string): void => {};
  onSetHostProfile: (profileId: string) => void = (_profileId: string): void => {};
  onSetSessionProfile: (profileId: string) => void = (_profileId: string): void => {};

  @State editing: boolean = false;
  @State draftId: string = '';
  @State draftName: string = '';
  @State draftForeground: string = '#33FF33';
  @State draftBackground: string = '#0D0D0D';
  @State draftFontFamily: SshTerminalFontFamily = 'monospace';
  @State draftFontSize: number = 18;
  @State draftLineSpacing: number = 1.12;
  @State draftCursorStyle: SshTerminalCursorStyle = 'bar';
  @State draftCursorBlink: boolean = true;
  @State draftScrollback: number = 10000;
  @State draftCopyOnSelect: boolean = false;
  private retainedDraftSettings: SshTerminalProfileSettingsV1 =
    emptySshTerminalProfileSettings();

  private scopeBackground(active: boolean): string {
    return active ? this.accentColor + 'CC' : 'rgba(255,255,255,0.08)';
  }

  private beginCreate(): void {
    this.draftId = 'profile-' + Date.now().toString();
    this.draftName = '新终端 Profile';
    this.draftForeground = this.resolvedProfile.foregroundColor;
    this.draftBackground = this.resolvedProfile.backgroundColor;
    this.draftFontFamily = this.resolvedProfile.fontFamily;
    this.draftFontSize = this.resolvedProfile.fontSize;
    this.draftLineSpacing = this.resolvedProfile.lineSpacing;
    this.draftCursorStyle = this.resolvedProfile.cursorStyle;
    this.draftCursorBlink = this.resolvedProfile.cursorBlink;
    this.draftScrollback = this.resolvedProfile.scrollback;
    this.draftCopyOnSelect = this.resolvedProfile.copyOnSelect;
    this.retainedDraftSettings = emptySshTerminalProfileSettings();
    this.editing = true;
  }

  private beginEdit(profile: SshTerminalProfileV1): void {
    const copied: SshTerminalProfileV1 = cloneSshTerminalProfile(profile);
    this.draftId = copied.id;
    this.draftName = copied.name;
    this.draftForeground = copied.settings.foregroundColor ?? this.resolvedProfile.foregroundColor;
    this.draftBackground = copied.settings.backgroundColor ?? this.resolvedProfile.backgroundColor;
    this.draftFontFamily = copied.settings.fontFamily ?? this.resolvedProfile.fontFamily;
    this.draftFontSize = copied.settings.fontSize ?? this.resolvedProfile.fontSize;
    this.draftLineSpacing = copied.settings.lineSpacing ?? this.resolvedProfile.lineSpacing;
    this.draftCursorStyle = copied.settings.cursorStyle ?? this.resolvedProfile.cursorStyle;
    this.draftCursorBlink = copied.settings.cursorBlink ?? this.resolvedProfile.cursorBlink;
    this.draftScrollback = copied.settings.scrollback ?? this.resolvedProfile.scrollback;
    this.draftCopyOnSelect = copied.settings.copyOnSelect ?? this.resolvedProfile.copyOnSelect;
    this.retainedDraftSettings = copied.settings;
    this.editing = true;
  }

  private saveDraft(): void {
    const name: string = this.draftName.trim();
    if (name.length === 0) { return; }
    const settings: SshTerminalProfileSettingsV1 = {
      foregroundColor: this.draftForeground,
      backgroundColor: this.draftBackground,
      palette: this.retainedDraftSettings.palette,
      fontFamily: this.draftFontFamily,
      fontSize: this.draftFontSize,
      lineSpacing: this.draftLineSpacing,
      fontWeight: this.retainedDraftSettings.fontWeight,
      cursorStyle: this.draftCursorStyle,
      cursorBlink: this.draftCursorBlink,
      scrollback: this.draftScrollback,
      bellStyle: this.retainedDraftSettings.bellStyle,
      linkHandling: this.retainedDraftSettings.linkHandling,
      copyOnSelect: this.draftCopyOnSelect,
      rightClickPaste: this.retainedDraftSettings.rightClickPaste,
      bracketedPaste: this.retainedDraftSettings.bracketedPaste,
      mouseReporting: this.retainedDraftSettings.mouseReporting,
      accessoryKeys: this.retainedDraftSettings.accessoryKeys,
      accessoryDensity: this.retainedDraftSettings.accessoryDensity,
      captureGlobalShortcuts: this.retainedDraftSettings.captureGlobalShortcuts
    };
    this.onSaveProfile({
      schemaVersion: 1,
      id: this.draftId,
      name,
      settings,
      updatedAtMs: Date.now()
    });
    this.editing = false;
  }

  @Builder
  private ScopeButtons(profileId: string) {
    Row({ space: 6 }) {
      Button('全局')
        .height(28).fontSize(10).fontColor('#F2F4F7').padding({ left: 9, right: 9 })
        .backgroundColor(this.scopeBackground(this.globalProfileId === profileId))
        .onClick((): void => { this.onSetGlobalProfile(profileId); })
      Button('此主机')
        .height(28).fontSize(10).fontColor('#F2F4F7').padding({ left: 9, right: 9 })
        .backgroundColor(this.scopeBackground(this.hostProfileId === profileId))
        .onClick((): void => { this.onSetHostProfile(profileId); })
      Button('本次会话')
        .height(28).fontSize(10).fontColor('#F2F4F7').padding({ left: 9, right: 9 })
        .backgroundColor(this.scopeBackground(this.sessionProfileId === profileId))
        .onClick((): void => { this.onSetSessionProfile(profileId); })
    }
  }

  @Builder
  private ChoiceButton(label: string, active: boolean, onChoose: () => void) {
    Button(label)
      .height(30).fontSize(10).fontColor('#F2F4F7')
      .padding({ left: 10, right: 10 }).borderRadius(8)
      .margin({ right: 6, bottom: 6 })
      .backgroundColor(this.scopeBackground(active))
      .onClick(onChoose)
  }

  @Builder
  private Editor() {
    Column({ space: 12 }) {
      Row() {
        Text(this.draftId.length > 0 ? '编辑 Profile' : '新建 Profile')
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
        Blank()
        Button('取消').height(30).fontSize(11).backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.editing = false; })
        Button('保存').height(30).fontSize(11).margin({ left: 8 })
          .backgroundColor(this.accentColor)
          .enabled(this.draftName.trim().length > 0)
          .onClick((): void => { this.saveDraft(); })
      }.width('100%')
      TextInput({ text: this.draftName, placeholder: 'Profile 名称' })
        .height(38).fontSize(12).fontColor('#F2F4F7')
        .backgroundColor('rgba(255,255,255,0.07)').borderRadius(8)
        .onChange((value: string): void => { this.draftName = value.slice(0, 64); })
      Text('前景色').fontSize(11).fontColor('rgba(242,244,247,0.62)').width('100%')
      Row({ space: 8 }) {
        ForEach(PROFILE_FOREGROUNDS, (color: string): void => {
          Column().width(30).height(30).borderRadius(15).backgroundColor(color)
            .border({ width: this.draftForeground === color ? 3 : 1,
              color: this.draftForeground === color ? this.accentColor : 'rgba(255,255,255,0.24)' })
            .onClick((): void => { this.draftForeground = color; })
        }, (color: string): string => color)
      }.width('100%')
      Text('背景色').fontSize(11).fontColor('rgba(242,244,247,0.62)').width('100%')
      Row({ space: 8 }) {
        ForEach(PROFILE_BACKGROUNDS, (color: string): void => {
          Column().width(30).height(30).borderRadius(8).backgroundColor(color)
            .border({ width: this.draftBackground === color ? 3 : 1,
              color: this.draftBackground === color ? this.accentColor : 'rgba(255,255,255,0.24)' })
            .onClick((): void => { this.draftBackground = color; })
        }, (color: string): string => color)
      }.width('100%')
      Text('字体').fontSize(11).fontColor('rgba(242,244,247,0.62)').width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(PROFILE_FONT_FAMILIES, (family: SshTerminalFontFamily): void => {
          this.ChoiceButton(family, this.draftFontFamily === family,
            (): void => { this.draftFontFamily = family; })
        }, (family: SshTerminalFontFamily): string => family)
      }.width('100%')
      Row({ space: 8 }) {
        Text('字号 ' + this.draftFontSize.toString()).fontSize(11).fontColor('#F2F4F7').layoutWeight(1)
        Button('−').width(30).height(28).padding(0).onClick((): void => {
          this.draftFontSize = Math.max(12, this.draftFontSize - 1);
        })
        Button('+').width(30).height(28).padding(0).onClick((): void => {
          this.draftFontSize = Math.min(32, this.draftFontSize + 1);
        })
      }.width('100%')
      Row({ space: 8 }) {
        Text('行距 ' + this.draftLineSpacing.toFixed(2)).fontSize(11).fontColor('#F2F4F7').layoutWeight(1)
        Button('−').width(30).height(28).padding(0).onClick((): void => {
          this.draftLineSpacing = Math.max(1, Math.round((this.draftLineSpacing - 0.04) * 100) / 100);
        })
        Button('+').width(30).height(28).padding(0).onClick((): void => {
          this.draftLineSpacing = Math.min(1.6, Math.round((this.draftLineSpacing + 0.04) * 100) / 100);
        })
      }.width('100%')
      Text('光标').fontSize(11).fontColor('rgba(242,244,247,0.62)').width('100%')
      Row({ space: 6 }) {
        ForEach(PROFILE_CURSOR_STYLES, (style: SshTerminalCursorStyle): void => {
          this.ChoiceButton(style, this.draftCursorStyle === style,
            (): void => { this.draftCursorStyle = style; })
        }, (style: SshTerminalCursorStyle): string => style)
        Blank()
        Text('闪烁').fontSize(11).fontColor('#F2F4F7')
        Toggle({ type: ToggleType.Switch, isOn: this.draftCursorBlink })
          .selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.draftCursorBlink = value; })
      }.width('100%')
      Text('回滚行数').fontSize(11).fontColor('rgba(242,244,247,0.62)').width('100%')
      Row({ space: 6 }) {
        ForEach(PROFILE_SCROLLBACKS, (count: number): void => {
          this.ChoiceButton(count.toString(), this.draftScrollback === count,
            (): void => { this.draftScrollback = count; })
        }, (count: number): string => count.toString())
      }.width('100%')
      Row() {
        Text('选中即复制').fontSize(12).fontColor('#F2F4F7').layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.draftCopyOnSelect })
          .selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.draftCopyOnSelect = value; })
      }.width('100%')
    }
    .width('100%').padding(14).borderRadius(12).backgroundColor('rgba(255,255,255,0.05)')
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('终端 Profile').fontSize(18).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
          Text(this.hostLabel.length > 0 ? '当前主机：' + this.hostLabel : '当前 SSH 会话')
            .fontSize(11).fontColor('rgba(242,244,247,0.55)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('新建').height(32).fontSize(11).backgroundColor(this.accentColor)
          .onClick((): void => { this.beginCreate(); })
        Button('关闭').height(32).fontSize(11).margin({ left: 8 })
          .backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 18, right: 18, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 10 }) {
          Column({ space: 8 }) {
            Row() {
              Column() {
                Text('内置默认').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
                Text('清除对应作用域覆盖，继续沿用兼容外观')
                  .fontSize(10).fontColor('rgba(242,244,247,0.52)').margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              this.ScopeButtons('')
            }.width('100%')
          }.width('100%').padding(12).borderRadius(11).backgroundColor('rgba(255,255,255,0.05)')

          ForEach(this.profiles, (profile: SshTerminalProfileV1): void => {
            Column({ space: 9 }) {
              Row() {
                Column() {
                  Text(profile.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
                  Text((profile.settings.fontFamily ?? '继承字体') + ' · ' +
                    (profile.settings.fontSize?.toString() ?? '继承字号'))
                    .fontSize(10).fontColor('rgba(242,244,247,0.52)').margin({ top: 3 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('编辑').height(28).fontSize(10).backgroundColor('rgba(255,255,255,0.08)')
                  .onClick((): void => { this.beginEdit(profile); })
                Button('删除').height(28).fontSize(10).fontColor('#FF9292')
                  .margin({ left: 6 }).backgroundColor('rgba(255,100,100,0.10)')
                  .onClick((): void => { this.onRemoveProfile(profile.id); })
              }.width('100%')
              this.ScopeButtons(profile.id)
            }.width('100%').padding(12).borderRadius(11).backgroundColor('rgba(255,255,255,0.05)')
          }, (profile: SshTerminalProfileV1): string => profile.id)

          if (this.editing) { this.Editor() }
        }.width('100%').padding({ left: 18, right: 18, bottom: 28 })
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor(this.sheetBackgroundColor)
  }
}
