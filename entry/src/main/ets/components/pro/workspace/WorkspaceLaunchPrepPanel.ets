import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { orgProtocolLabel } from '../../../services/pro/org/HostOrganizationDirectory';

/** One workspace entry as the PC 连接准备 sheet shows it. */
export interface WorkspacePrepRow {
  ref: string;
  label: string;
  protocol: string;
  locked: boolean;
  /** RDP 「连接时输入」 hosts: account and password are collected here once. */
  needsRdpCredential: boolean;
  /** Steps the host's own flow may still ask for (RustDesk confirmation, a new certificate or fingerprint). */
  mayAsk: string;
}

/** Account and password typed for one RDP host; held in memory for this run only. */
export interface WorkspacePrepCredential { ref: string; username: string; password: string; }

/**
 * PC 「连接准备」: everything the workspace needs from the user, asked once before any session starts — a single
 * biometric check for locked hosts and the account/password of 「连接时输入」 RDP hosts. After 开始连接 the sessions
 * open one after another without further taps.
 */
@Component
export struct WorkspaceLaunchPrepPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop name: string = '';
  @Prop rows: WorkspacePrepRow[] = [];
  onStart: (credentials: WorkspacePrepCredential[]) => void = (_credentials: WorkspacePrepCredential[]): void => {};
  onCancel: () => void = (): void => {};
  @State usernames: string[] = [];
  @State passwords: string[] = [];
  @State error: string = '';

  aboutToAppear(): void {
    this.usernames = this.rows.map((_row: WorkspacePrepRow): string => '');
    this.passwords = this.rows.map((_row: WorkspacePrepRow): string => '');
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private lockedCount(): number { return this.rows.filter((row: WorkspacePrepRow): boolean => row.locked).length; }
  private setUsername(index: number, value: string): void {
    const next: string[] = this.usernames.slice(); next[index] = value; this.usernames = next; this.error = '';
  }
  private setPassword(index: number, value: string): void {
    const next: string[] = this.passwords.slice(); next[index] = value; this.passwords = next; this.error = '';
  }
  private start(): void {
    const credentials: WorkspacePrepCredential[] = [];
    for (let index: number = 0; index < this.rows.length; index++) {
      const row: WorkspacePrepRow = this.rows[index];
      if (!row.needsRdpCredential) { continue; }
      const username: string = (this.usernames[index] ?? '').trim();
      const password: string = this.passwords[index] ?? '';
      if (username === '' || password === '') {
        this.error = '请填写「' + row.label + '」的 Windows 账号和密码';
        return;
      }
      credentials.push({ ref: row.ref, username, password });
    }
    // Clear the drafts before handing over so they do not linger in component state.
    this.passwords = this.rows.map((_row: WorkspacePrepRow): string => '');
    this.onStart(credentials);
  }

  build() {
    Column({ space: 14 }) {
      Column({ space: 4 }) {
        Text('连接准备').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text('「' + this.name + '」共 ' + this.rows.length.toString() + ' 台主机。先在这里一次确认，之后各会话会自动依次打开到独立窗口。')
          .fontSize(13).fontColor(this.pal().text2).lineHeight(19)
      }.alignItems(HorizontalAlign.Start).width('100%')
      if (this.lockedCount() > 0) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(20).fontColor([this.accent])
          Text(this.lockedCount().toString() + ' 台主机已上锁，开始连接时验证一次身份即可全部解锁')
            .fontSize(13).fontColor(this.pal().text).layoutWeight(1)
        }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
      }
      Column() {
        ForEach(this.rows, (row: WorkspacePrepRow, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 14, right: 14 }) }
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text((index + 1).toString()).fontSize(12).fontColor(this.accent).width(20)
              Text(row.label).fontSize(14).fontColor(this.pal().text).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (row.locked) { SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(13).fontColor([this.pal().text3]) }
              Text(orgProtocolLabel(row.protocol)).fontSize(11).fontColor(this.pal().text3)
            }.width('100%')
            if (row.needsRdpCredential) {
              Row({ space: 8 }) {
                TextInput({ text: this.usernames[index] ?? '', placeholder: 'Windows 账号' }).height(38).layoutWeight(1)
                  .maxLength(256).backgroundColor(this.pal().surface).borderRadius(10)
                  .onChange((value: string): void => { this.setUsername(index, value); })
                TextInput({ text: this.passwords[index] ?? '', placeholder: '密码' }).type(InputType.Password).height(38)
                  .layoutWeight(1).maxLength(1024).backgroundColor(this.pal().surface).borderRadius(10)
                  .onChange((value: string): void => { this.setPassword(index, value); })
              }.width('100%')
            }
            if (row.mayAsk !== '') {
              Text(row.mayAsk).fontSize(11).fontColor(this.pal().text3).width('100%')
            }
          }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
        }, (row: WorkspacePrepRow): string => row.ref)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      if (this.error !== '') { Text(this.error).fontSize(12).fontColor(this.pal().danger).width('100%') }
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(42).fontSize(15).fontColor(this.pal().text)
          .backgroundColor(this.pal().surface).onClick((): void => { this.onCancel(); })
        Button('开始连接').layoutWeight(2).height(42).fontSize(15).fontColor(appUiOnAccentText(this.accent))
          .backgroundColor(this.accent).onClick((): void => { this.start(); })
      }.width('100%')
      Text('账号和密码只在这次打开期间保存在内存中，用完即清除，不会保存或同步。').fontSize(11)
        .fontColor(this.pal().text3).width('100%')
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 24 })
  }
}
