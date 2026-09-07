import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { SshAuthPrompt, SshAuthPromptRequest } from '../types/rdpnapi';
import { SshConnectionPreflight, SshPreflightInteraction } from '../services/ssh/auth/SshConnectionPreflight';
import { SshAuthenticatedHandoff } from '../services/ssh/auth/SshAuthenticatedHandoff';

@Component
export struct SshConnectionPreflightSheet {
  @Prop hostId: string = '';
  @Prop hostLabel: string = '';
  @Prop theme: string = 'dark';
  @Prop accent: string = '#007DFF';
  @Prop viewportHeight: number = 720;
  @State keyboardHeightVp: number = 0;
  private hostWindow: window.Window | null = null;
  private keyboardListener: (height: number) => void = (height: number): void => {
    this.keyboardHeightVp = this.getUIContext().px2vp(height);
  };
  isActive: () => boolean = (): boolean => true;
  onAuthenticated: (token: string) => void = (_token: string): void => {};
  onCancel: () => void = (): void => {};
  @State request: SshAuthPromptRequest | null = null;
  @State values: string[] = [];
  @State secretTitle: string = '';
  @State secretLabel: string = '';
  @State secretValue: string = '';
  @State error: string = '';
  @State replaceArmed: boolean = false;
  private mounted: boolean = false;
  private completed: boolean = false;
  private secretResolver: ((value: string) => void) | null = null;
  private connection: SshConnectionPreflight | null = null;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  aboutToAppear(): void {
    this.mounted = true;
    void window.getLastWindow(getContext(this)).then((hostWindow: window.Window): void => {
      if (!this.mounted) { return; }
      this.hostWindow = hostWindow;
      hostWindow.on('keyboardHeightChange', this.keyboardListener);
      this.keyboardListener(hostWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height);
    }).catch((): void => {});
    const interaction: SshPreflightInteraction = {
      active: (): boolean => this.mounted && this.isActive(),
      secret: (title: string, label: string): Promise<string> => {
        this.secretTitle = title; this.secretLabel = label; this.secretValue = '';
        return new Promise<string>((resolve): void => { this.secretResolver = resolve; });
      },
      prompt: (request: SshAuthPromptRequest | null): void => {
        this.request = request;
        this.values = request === null ? [] : request.prompts.map((): string => '');
        this.replaceArmed = false;
      },
      cancelled: (): void => { this.resolveSecret(''); }
    };
    this.connection = new SshConnectionPreflight(interaction);
    void this.start();
  }

  private async start(): Promise<void> {
    try {
      const token: string = await this.connection!.connect(this.hostId, getContext(this) as common.Context);
      if (!this.mounted || !this.isActive()) {
        SshAuthenticatedHandoff.getInstance().discard(token);
        return;
      }
      this.completed = true;
      this.onAuthenticated(token);
    } catch (err) {
      if (this.mounted) { this.error = err instanceof Error ? err.message : 'SSH 鉴权失败，请重试'; }
    }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    try { this.hostWindow?.off('keyboardHeightChange', this.keyboardListener); } catch (_err) { }
    this.hostWindow = null;
    this.connection?.cancel();
    this.resolveSecret('');
    this.request = null;
    this.values = [];
  }

  private resolveSecret(value: string): void {
    const resolve = this.secretResolver;
    this.secretResolver = null;
    this.secretTitle = ''; this.secretLabel = ''; this.secretValue = '';
    if (resolve !== null) { resolve(value); }
  }

  private submit(): void {
    if (this.secretResolver !== null) { this.resolveSecret(this.secretValue); return; }
    const request = this.request;
    if (request === null) { return; }
    if (request.kind === 'host_key' && request.hostKeyChanged && !this.replaceArmed) {
      this.replaceArmed = true;
      return;
    }
    if (!this.connection?.submit(request, this.values.slice())) {
      this.error = '认证请求已失效或信任记录保存失败，请重新连接';
    }
    this.values = [];
  }

  build() {
    Column({ space: 12 }) {
      Scroll() {
      Column({ space: 12 }) {
      Text(this.secretTitle || (this.request?.kind === 'host_key' ? '确认 SSH 主机指纹' : 'SSH 连接鉴权'))
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .width('100%')
      Text(this.hostLabel).fontSize(12).fontColor(this.pal().text2).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor(this.pal().danger).width('100%')
      } else if (this.secretTitle.length > 0) {
        Text(this.secretLabel).fontSize(13).fontColor(this.pal().text2).width('100%')
        TextInput({ text: this.secretValue, placeholder: '仅用于本次连接' })
          .type(InputType.Password).enableAutoFill(false).height(44)
          .onChange((value: string): void => { this.secretValue = value; })
          .onSubmit((): void => { this.submit(); })
      } else if (this.request !== null) {
        if (this.request!.kind === 'host_key') {
          Text(this.request!.hostKeyHopIndex < 0 ? '目标主机' :
            '跳板机第 ' + (this.request!.hostKeyHopIndex + 1).toString() + ' 跳')
            .fontSize(13).fontColor(this.pal().text).width('100%')
          Text(this.request!.endpointHost + ':' + this.request!.endpointPort.toString())
            .fontSize(12).fontColor(this.pal().text2).width('100%')
          Text(this.request!.hostKeyChanged ? '服务器指纹已变更，请通过可信渠道核对后再继续。' :
            '首次连接此主机，请核对指纹。确认信任后才会向该主机发送认证信息。')
            .fontSize(13).fontColor(this.request!.hostKeyChanged ? this.pal().danger : this.pal().text2)
          Text(this.request!.hostKeyAlgorithm + '  ' + this.request!.hostKeyFingerprintSha256)
            .fontSize(12).fontColor(this.pal().text).width('100%')
          if (this.request!.hostKeyChanged) {
            Text('原指纹：' + (this.request!.expectedHostKeyFingerprintSha256 || '仅保存了原始 Host Key'))
              .fontSize(12).fontColor(this.pal().text2).width('100%')
          }
        } else {
          Text(this.request!.hop || this.request!.targetHost).fontSize(12).fontColor(this.pal().text2)
          Text(this.request!.name + '\n' + this.request!.instruction)
            .fontSize(13).fontColor(this.pal().text).width('100%')
            Column({ space: 10 }) {
              ForEach(this.request!.prompts, (prompt: SshAuthPrompt, index: number): void => {
                Text(prompt.text || '请输入认证响应').fontSize(12).fontColor(this.pal().text).width('100%')
                TextInput({ text: this.values[index], placeholder: prompt.echo ? '输入响应' : '密码或验证码' })
                  .type(prompt.echo ? InputType.Normal : InputType.Password).enableAutoFill(false).height(44)
                  .onChange((value: string): void => {
                    const values: string[] = this.values.slice(); values[index] = value; this.values = values;
                  })
                  .onSubmit((): void => { this.submit(); })
              }, (_prompt: SshAuthPrompt, index: number): string => index.toString())
            }.width('100%')
        }
      } else {
        LoadingProgress().width(28).height(28).color(this.accent)
        Text('鉴权通过后打开终端').fontSize(13).fontColor(this.pal().text2)
      }
      }.width('100%')
      }.width('100%').constraintSize({
        maxHeight: Math.max(64, Math.min(420, this.viewportHeight - this.keyboardHeightVp - 160))
      }).scrollBar(BarState.Auto)
      Row({ space: 12 }) {
        Button(this.error.length > 0 ? '关闭' : '取消').height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text)
          .onClick((): void => { this.connection?.cancel(); this.onCancel(); })
        if (this.error.length === 0 && (this.request !== null || this.secretTitle.length > 0)) {
          Button(this.request?.kind === 'host_key' ?
            (this.request!.hostKeyChanged ? (this.replaceArmed ? '确认更换并连接' : '我已核对，继续') : '信任并连接') : '继续')
            .height(40).layoutWeight(1).backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { this.submit(); })
        }
      }.width('100%')
    }.padding(20).width('100%').backgroundColor(this.pal().sheetBg)
  }
}
