import { AppTheme, Palette, buildDark } from '../../common/Theme';
import { RdpSecurityKeyPrompt, rdpSecurityKeyPinProblem } from '../../services/pro/ProRdpSecurityKey';
import { ProUsbFidoKeyCandidate } from '../../services/pro/ProUsbFidoKey';

const PIN_INPUT_ID: string = 'rdpSecurityKeyPin';

/** Modal prompt for RDP security-key redirection: confirm, choose a key, enter the PIN, touch the key. */
@Component
export struct RdpSecurityKeyPromptView {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop prompt: RdpSecurityKeyPrompt = {
    kind: 'touch', requestId: 0, rpId: '', register: false, retries: -1, candidates: [], busy: false, error: '',
    phone: false
  };
  @State pinDraft: string = '';
  onAllow: (requestId: number) => void = (_requestId: number): void => {};
  onDeny: (requestId: number) => void = (_requestId: number): void => {};
  onChoose: (requestId: number, key: string) => void = (_requestId: number, _key: string): void => {};
  onRefresh: () => void = (): void => {};
  onPhone: (requestId: number) => void = (_requestId: number): void => {};
  /** While the phone is asked: switch this request to a USB security key. */
  onUseKey: (requestId: number) => void = (_requestId: number): void => {};
  onPin: (requestId: number, pin: string) => void = (_requestId: number, _pin: string): void => {};
  onCancel: () => void = (): void => {};

  private pal(): Palette { return buildDark(this.accentColor); }

  aboutToDisappear(): void { this.pinDraft = ''; }

  private title(): string {
    switch (this.prompt.kind) {
      case 'confirm': return '安全密钥请求';
      case 'select': return '选择安全密钥';
      case 'pin': return this.prompt.retries === 0 ? '安全密钥 PIN 已锁定' : '输入安全密钥 PIN';
      case 'phone': return this.prompt.error !== '' ? '手机通行密钥未完成' : '请在手机上确认';
      default: return '请触摸安全密钥';
    }
  }

  private submitPin(): boolean {
    const pin = this.pinDraft;
    if (rdpSecurityKeyPinProblem(pin) !== '') { return false; }
    this.pinDraft = '';
    this.onPin(this.prompt.requestId, pin);
    return true;
  }

  /** defaultFocus only applies when a page first shows; this prompt appears over a live session. */
  private focusPin(): void {
    setTimeout((): void => {
      try { this.getUIContext().getFocusController().requestFocus(PIN_INPUT_ID); } catch (_error) {}
    }, 0);
  }

  @Builder private button(label: string, primary: boolean, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule, stateEffect: true })
      .fontSize(14).fontWeight(FontWeight.Medium).height(40).layoutWeight(1)
      .fontColor(primary ? Color.White : this.pal().text)
      .backgroundColor(primary ? this.accentColor : this.pal().surface)
      .enabled(enabled).opacity(enabled ? 1 : 0.5)
      .onClick(action)
  }

  @Builder private keyRow(candidate: ProUsbFidoKeyCandidate) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(18).fontColor([this.accentColor])
      Text(candidate.label).fontSize(13).fontColor(this.pal().text).layoutWeight(1)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
    }
    .width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 }).borderRadius(12)
    .backgroundColor(this.pal().surface).enabled(!this.prompt.busy)
    .accessibilityText('选择安全密钥 ' + candidate.label)
    .onClick((): void => { this.onChoose(this.prompt.requestId, candidate.key); })
  }

  @Builder private body() {
    if (this.prompt.kind === 'confirm') {
      Text('远程电脑上的「' + this.prompt.rpId + '」请求使用你的安全密钥' +
        (this.prompt.register ? '注册新的登录凭据。' : '登录。'))
        .fontSize(14).fontColor(this.pal().text).lineHeight(21).width('100%')
      Text('只有确认是你自己在远程电脑上发起的操作时才允许。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).width('100%')
      Row({ space: 10 }) {
        this.button('拒绝', false, true, (): void => { this.onDeny(this.prompt.requestId); })
        this.button('允许', true, true, (): void => { this.onAllow(this.prompt.requestId); })
      }.width('100%').margin({ top: 6 })
    } else if (this.prompt.kind === 'select') {
      Text(this.prompt.busy ? '请在系统弹窗中允许 RemoteDesk 访问这支安全密钥…' :
        '插入 USB 安全密钥后选择它，系统会询问是否允许访问。')
        .fontSize(13).fontColor(this.pal().text2).lineHeight(19).width('100%')
      if (this.prompt.phone) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.phone_fill')).fontSize(18).fontColor([this.accentColor])
          Column({ space: 2 }) {
            Text('使用手机通行密钥').fontSize(13).fontColor(this.pal().text)
            Text('由已配对的手机确认并验证，本次连接内一直使用').fontSize(11).fontColor(this.pal().text3)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
        }
        .width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 }).borderRadius(12)
        .backgroundColor(this.pal().surface).enabled(!this.prompt.busy)
        .accessibilityText('使用手机通行密钥').onClick((): void => { this.onPhone(this.prompt.requestId); })
      }
      if (this.prompt.candidates.length === 0) {
        Text('没有检测到安全密钥').fontSize(13).fontColor(this.pal().text3)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 14, bottom: 14 })
      } else {
        Column({ space: 8 }) {
          ForEach(this.prompt.candidates, (candidate: ProUsbFidoKeyCandidate): void => { this.keyRow(candidate) },
            (candidate: ProUsbFidoKeyCandidate): string => candidate.key)
        }.width('100%')
      }
      if (this.prompt.error.length > 0) {
        Text(this.prompt.error).fontSize(12).fontColor(this.pal().danger).width('100%')
      }
      Row({ space: 10 }) {
        this.button('取消', false, true, (): void => { this.onCancel(); })
        this.button('刷新', true, !this.prompt.busy, (): void => { this.onRefresh(); })
      }.width('100%').margin({ top: 6 })
    } else if (this.prompt.kind === 'pin' && this.prompt.retries === 0) {
      Text('这支安全密钥连续输错 PIN 的次数过多，已被锁定。需要先按厂商说明重置安全密钥，才能再次使用。')
        .fontSize(14).fontColor(this.pal().text).lineHeight(21).width('100%')
      Row() {
        this.button('关闭', false, true, (): void => { this.onCancel(); })
      }.width('100%').margin({ top: 6 })
    } else if (this.prompt.kind === 'pin') {
      if (this.prompt.retries > 0) {
        Text('还可以尝试 ' + this.prompt.retries.toString() + ' 次，多次输错会锁定安全密钥。')
          .fontSize(12).fontColor(this.prompt.retries <= 3 ? this.pal().danger : this.pal().text3).width('100%')
      }
      TextInput({ text: this.pinDraft, placeholder: '安全密钥 PIN（至少 4 位）' })
        .id(PIN_INPUT_ID)
        .type(InputType.Password).maxLength(63).height(44).fontSize(15)
        .fontColor(this.pal().text).backgroundColor(this.pal().surface).borderRadius(12)
        .enterKeyType(EnterKeyType.Done)
        .onAppear((): void => { this.focusPin(); })
        .onChange((value: string): void => { this.pinDraft = value; })
        .onSubmit((_key: EnterKeyType, event: SubmitEvent): void => {
          // A PIN that would be refused keeps the field open for correction.
          if (!this.submitPin()) { event.keepEditableState(); }
        })
      if (this.pinDraft.length > 0 && rdpSecurityKeyPinProblem(this.pinDraft) !== '') {
        Text(rdpSecurityKeyPinProblem(this.pinDraft)).fontSize(12).fontColor(this.pal().danger).width('100%')
      }
      Text('PIN 只交给本机连接的安全密钥，不会发送到远程电脑或保存。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(16).width('100%')
      Row({ space: 10 }) {
        this.button('取消', false, true, (): void => { this.pinDraft = ''; this.onCancel(); })
        this.button('确定', true, rdpSecurityKeyPinProblem(this.pinDraft) === '', (): void => { this.submitPin(); })
      }.width('100%').margin({ top: 6 })
    } else if (this.prompt.kind === 'phone' && this.prompt.error !== '') {
      Text(this.prompt.error).fontSize(14).fontColor(this.pal().text).lineHeight(21).width('100%')
      Text('远程电脑上的这次' + (this.prompt.register ? '注册' : '登录') + '已取消，可以在网页上重试。')
        .fontSize(12).fontColor(this.pal().text3).width('100%')
      Row() {
        this.button('知道了', false, true, (): void => { this.onCancel(); })
      }.width('100%').margin({ top: 6 })
    } else if (this.prompt.kind === 'phone') {
      Text('已把「' + this.prompt.rpId + '」的' + (this.prompt.register ? '注册' : '登录') +
        '请求发到已配对的手机。请在手机上允许，并验证人脸、指纹或锁屏密码。')
        .fontSize(14).fontColor(this.pal().text).lineHeight(21).width('100%')
      Text('手机需要打开 RemoteDesk 并开启“接收登录请求”。').fontSize(12).fontColor(this.pal().text3).width('100%')
      Row({ space: 10 }) {
        this.button('取消', false, true, (): void => { this.onCancel(); })
        if (this.prompt.phone) {
          this.button('改用 USB 安全密钥', false, true, (): void => { this.onUseKey(this.prompt.requestId); })
        }
      }.width('100%').margin({ top: 6 })
    } else {
      Text('安全密钥闪烁时轻触它，完成远程电脑上的验证。')
        .fontSize(14).fontColor(this.pal().text).lineHeight(21).width('100%')
      Row() {
        this.button('取消', false, true, (): void => { this.onCancel(); })
      }.width('100%').margin({ top: 6 })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(20).fontColor([this.accentColor])
          }.width(38).height(38).borderRadius(12).backgroundColor(this.pal().surface)
          Text(this.title()).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppTheme.fontFamily).layoutWeight(1)
        }.width('100%')
        this.body()
      }
      .width('88%').constraintSize({ maxWidth: 380 }).padding(18).borderRadius(20)
      // Opaque (the dark palette's card is see-through): the remote page must not show through the request.
      .backgroundColor(this.pal().sheetBg).border({ width: 0.5, color: this.pal().cardBorder })
      .shadow({ radius: 24, color: '#59000000', offsetY: 8 })
    }
    .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.45)')
    .hitTestBehavior(HitTestMode.Block)
  }
}
