import { common } from '@kit.AbilityKit';
import { appUiOnAccentText } from '../../common/AppUiColorPolicy';
import { curves } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { AiSegmented } from './AiSegmented';
import { AiReadAloud } from '../../services/diagnosticAi/AiSpeech';
import { AI_ASR_ENGINES, AI_ASR_MODELS, AI_TTS_PROVIDERS, AiTtsProvider, AiVoiceConfig, AiVoiceSettings, aiTtsProvider } from '../../services/diagnosticAi/AiVoiceSettings';

const SAMPLE: string = '你好，我是你的 AI 助理。语音模式下，你可以直接和我说话，我会一边想一边告诉你。';

/**
 * 设置 › AI 语音 (Beta): off until turned on. On, the chat gets Siri-style voice mode and 按住 AI 按钮说话, and answers
 * are read with the engine chosen here — the system voice by default (offline, free), or a cloud voice (阿里云百炼,
 * MiniMax, OpenAI 兼容) with the user's own key. Speech is recognized on the device, or — when chosen — by 阿里云百炼's
 * real-time recognition with the same 阿里云百炼 key.
 */
@Component
export struct AiVoiceSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop owner: string = 'device-local';
  @State private config: AiVoiceConfig = new AiVoiceConfig();
  @State private keyDraft: string = '';
  @State private keyPrint: string = '';
  /** The 阿里云百炼 key, which cloud recognition uses (whatever voice reads the answers). */
  @State private asrKeyDraft: string = '';
  @State private asrKeyPrint: string = '';
  @State private message: string = '';
  @State private sampling: boolean = false;
  @State private maleReady: boolean = true;
  @State private downloading: boolean = false;
  private readonly settings: AiVoiceSettings = new AiVoiceSettings();

  aboutToAppear(): void {
    this.settings.init(this.context(), this.owner);
    this.reload();
    void AiReadAloud.systemVoiceReady(21).then((ready: boolean): void => { this.maleReady = ready; });
  }

  aboutToDisappear(): void {
    if (this.sampling) { AiReadAloud.stop(); }
  }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private reload(): void {
    this.config = this.settings.read();
    this.keyPrint = this.settings.keyFingerprint(this.config.provider);
    this.keyDraft = '';
    this.asrKeyPrint = this.settings.keyFingerprint('dashscope');
  }

  private pickAsr(id: string): void {
    this.settings.setAsr(id);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.reload(); });
  }

  private saveAsrKey(): void {
    const key: string = this.asrKeyDraft.trim();
    if (key === '') { this.flash('请先粘贴 API Key'); return; }
    if (!this.settings.saveKey('dashscope', key)) { this.flash('密钥没有保存成功，请重试'); return; }
    this.asrKeyDraft = '';
    this.reload();
    this.flash('已保存，密钥只存在本机的安全存储里');
  }

  private flash(text: string): void {
    this.message = text;
    setTimeout((): void => { if (this.message === text) { this.message = ''; } }, 3200);
  }

  private provider(): AiTtsProvider { return aiTtsProvider(this.config.provider); }

  private setEnabled(on: boolean): void {
    this.settings.setEnabled(on);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.reload(); });
  }

  private pickProvider(id: string): void {
    if (this.sampling) { AiReadAloud.stop(); }
    this.settings.setProvider(id);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.reload(); });
  }

  private saveKey(): void {
    const key: string = this.keyDraft.trim();
    if (key === '') { this.flash('请先粘贴 API Key'); return; }
    if (!this.settings.saveKey(this.config.provider, key)) { this.flash('密钥没有保存成功，请重试'); return; }
    this.reload();
    this.flash('已保存，密钥只存在本机的安全存储里');
  }

  private confirmRemoveKey(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除语音 API Key？',
      message: '本机保存的密钥会被删除，朗读改用系统语音；以后要用云端音色需要重新粘贴。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1) { this.removeKey(); }
    }).catch((): void => {});
  }

  private removeKey(): void {
    this.settings.removeKey(this.config.provider);
    this.reload();
    this.flash('已删除密钥，朗读会改用系统语音');
  }

  private sample(): void {
    if (this.sampling) { AiReadAloud.stop(); return; }
    this.sampling = true;
    void AiReadAloud.speak(this.context(), this.owner, 'voice-sample', SAMPLE, (id: string): void => {
      this.sampling = id !== '';
    }).then((note: string): void => { if (note !== '') { this.flash(note); } });
  }

  private downloadMale(): void {
    if (this.downloading) { return; }
    this.downloading = true;
    void AiReadAloud.downloadSystemVoice(21).then((problem: string): void => {
      this.downloading = false;
      if (problem !== '') { this.flash(problem); return; }
      this.maleReady = true;
      this.flash('男声已下载');
    });
  }

  @Builder private betaChip() {
    Text('Beta').fontSize(10).fontWeight(FontWeight.Bold).fontColor(Color.White)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
      .linearGradient({ angle: 90, colors: [['#FF7A45', 0], ['#FF3D7F', 1]] })
  }

  @Styles cardStyle() {
    .width('100%').padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private label(text: string) {
    Text(text).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text3).width('100%')
      .padding({ left: 4, top: 6 })
  }

  @Builder private switchRow(title: string, detail: string, on: boolean, change: (on: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(detail).fontSize(12).lineHeight(17).fontColor(this.pal().text3)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: on }).selectedColor(this.accent)
        .onChange((value: boolean): void => { change(value); })
    }.width('100%').padding({ top: 12, bottom: 12 })
  }

  @Builder private chips(options: string[][], current: string, pick: (id: string) => void) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(options, (option: string[]): void => {
        Text(option[1]).fontSize(12).fontColor(option[0] === current ? appUiOnAccentText(this.accent) : this.pal().text)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ right: 6, bottom: 6 }).borderRadius(14)
          .backgroundColor(option[0] === current ? this.accent : this.pal().surface)
          .onClick((): void => { pick(option[0]); })
      }, (option: string[]): string => option[0] + (option[0] === current ? '-on' : ''))
    }.width('100%')
  }

  @Builder private field(title: string, value: string, placeholder: string, save: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title).fontSize(13).fontColor(this.pal().text3).width('100%')
      TextInput({ text: value, placeholder: placeholder }).fontSize(14).height(40).borderRadius(12)
        .backgroundColor(this.pal().surface)
        .onChange((text: string): void => { save(text); })
    }.width('100%').padding({ top: 8, bottom: 8 })
  }

  @Builder private engineRow(provider: AiTtsProvider) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(provider.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(provider.detail).fontSize(12).lineHeight(17).fontColor(this.pal().text3)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (provider.id === this.config.provider) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accent])
      }
    }.width('100%').padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: { bottom: this.pal().divider } })
    .onClick((): void => { this.pickProvider(provider.id); })
  }

  @Builder private systemDetails() {
    Column() {
      Column({ space: 10 }) {
        Text('音色').fontSize(13).fontColor(this.pal().text3).width('100%')
        AiSegmented({ options: [['13', '女声 · 聆小珊'], ['21', '男声 · 凌飞哲']], current: this.config.voice,
          trackColor: this.pal().surface, textColor: this.pal().text, segmentHeight: 34,
          onPick: (id: string): void => { this.settings.setVoice('system', id); this.reload(); } })
        if (this.config.voice === '21' && !this.maleReady) {
          Row({ space: 8 }) {
            Text(this.downloading ? '正在下载男声…' : '男声需要下载一次（约几十 MB），下载前会一直用女声')
              .fontSize(12).lineHeight(17).fontColor(this.pal().text3).layoutWeight(1)
            if (!this.downloading) {
              Text('下载').fontSize(13).fontColor(this.accent).onClick((): void => { this.downloadMale(); })
            } else {
              LoadingProgress().width(20).height(20).color(this.accent)
            }
          }.width('100%')
        }
      }.width('100%').padding({ top: 12, bottom: 12 })
    }.cardStyle()
  }

  @Builder private cloudDetails() {
    Column() {
      Column() {
        Column({ space: 6 }) {
          Row() {
            Text('API Key').fontSize(13).fontColor(this.pal().text3).layoutWeight(1)
            if (this.keyPrint !== '') {
              Text('已保存 ••••' + this.keyPrint.slice(-4)).fontSize(12).fontColor(this.pal().text3)
              Text('删除').fontSize(12).fontColor(this.pal().danger).margin({ left: 10 })
                .onClick((): void => { this.confirmRemoveKey(); })
            }
          }.width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.keyDraft, placeholder: this.keyPrint !== '' ? '粘贴新的 Key 以替换' : '粘贴 ' + this.provider().name + ' 的 API Key' })
              .type(InputType.Password).fontSize(14).height(40).borderRadius(12).layoutWeight(1)
              .backgroundColor(this.pal().surface)
              .onChange((text: string): void => { this.keyDraft = text; })
            Text('保存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(appUiOnAccentText(this.accent)).height(36)
              .padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.accent)
              .opacity(this.keyDraft.trim() === '' ? 0.5 : 1)
              .onClick((): void => { this.saveKey(); })
          }.width('100%')
        }.width('100%').padding({ top: 12, bottom: 8 })
        if (this.provider().baseUrls.length > 0) {
          Column({ space: 6 }) {
            Text('服务地址').fontSize(13).fontColor(this.pal().text3).width('100%')
            this.chips(this.provider().baseUrls, this.config.baseUrl, (url: string): void => {
              this.settings.setBaseUrl(this.config.provider, url); this.reload();
            })
            TextInput({ text: this.config.baseUrl, placeholder: 'https://…/v1' }).fontSize(14).height(40).borderRadius(12)
              .backgroundColor(this.pal().surface)
              .onChange((text: string): void => { this.settings.setBaseUrl(this.config.provider, text); })
          }.width('100%').padding({ top: 8, bottom: 8 })
        }
        if (this.config.provider === 'minimax') {
          this.field('Group ID（可选，旧账号需要）', this.config.groupId, '在 MiniMax 账户信息里查看',
            (text: string): void => { this.settings.setGroupId('minimax', text); })
        }
        Column({ space: 6 }) {
          Text('模型').fontSize(13).fontColor(this.pal().text3).width('100%')
          this.chips(this.provider().models.map((model: string): string[] => [model, model]), this.config.model,
            (model: string): void => { this.settings.setModel(this.config.provider, model); this.reload(); })
        }.width('100%').padding({ top: 8, bottom: 4 })
        Column({ space: 6 }) {
          Text('音色').fontSize(13).fontColor(this.pal().text3).width('100%')
          this.chips(this.provider().voices, this.config.voice,
            (voice: string): void => { this.settings.setVoice(this.config.provider, voice); this.reload(); })
          TextInput({ text: this.config.voice, placeholder: '也可以填写其他音色 ID' }).fontSize(14).height(40)
            .borderRadius(12).backgroundColor(this.pal().surface)
            .onChange((text: string): void => { this.settings.setVoice(this.config.provider, text); })
        }.width('100%').padding({ top: 4, bottom: 12 })
      }.width('100%')
    }.cardStyle()
  }

  @Builder private asrCard() {
    Column() {
      Column({ space: 10 }) {
        AiSegmented({ options: AI_ASR_ENGINES, current: this.config.asr,
          trackColor: this.pal().surface, textColor: this.pal().text, segmentHeight: 34,
          onPick: (id: string): void => { this.pickAsr(id); } })
        Text(this.config.asr === 'system' ?
          '鸿蒙本机的离线识别：免费，声音不离开手机，但模型小，准确率一般。' :
          '阿里云百炼实时识别：边说边出字，准确率接近小艺输入法（同样是云端识别）。按时长计费，说话的声音会发送给阿里云。')
          .fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%')
        if (this.config.asr === 'dashscope') {
          Column({ space: 6 }) {
            Text('模型').fontSize(13).fontColor(this.pal().text3).width('100%')
            this.chips(AI_ASR_MODELS.map((model: string): string[] => [model, model]), this.config.asrModel,
              (model: string): void => { this.settings.setAsrModel(model); this.reload(); })
          }.width('100%')
          if (this.asrKeyPrint !== '') {
            Text('使用已保存的阿里云百炼密钥 ••••' + this.asrKeyPrint.slice(-4))
              .fontSize(12).fontColor(this.pal().text3).width('100%')
          } else {
            Column({ space: 6 }) {
              Text('阿里云百炼 API Key').fontSize(13).fontColor(this.pal().text3).width('100%')
              Row({ space: 8 }) {
                TextInput({ text: this.asrKeyDraft, placeholder: '粘贴阿里云百炼的 API Key' })
                  .type(InputType.Password).fontSize(14).height(40).borderRadius(12).layoutWeight(1)
                  .backgroundColor(this.pal().surface)
                  .onChange((text: string): void => { this.asrKeyDraft = text; })
                Text('保存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(appUiOnAccentText(this.accent)).height(36)
                  .padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.accent)
                  .opacity(this.asrKeyDraft.trim() === '' ? 0.5 : 1)
                  .onClick((): void => { this.saveAsrKey(); })
              }.width('100%')
              Text('没有密钥时仍用本机识别。').fontSize(12).fontColor(this.pal().text3).width('100%')
            }.width('100%')
          }
        }
      }.width('100%').padding({ top: 12, bottom: 14 })
    }.cardStyle()
  }

  private privacyText(): string {
    const reads: string = this.config.provider === 'system' ? '朗读在本机完成' :
      '朗读时，要读的文字会发送给 ' + this.provider().name;
    const hears: string = this.config.asr === 'dashscope' && this.asrKeyPrint !== '' ?
      '语音识别时，你说话的声音会发送给阿里云百炼' : '语音识别在本机完成，声音不会离开手机';
    return hears + '；' + reads + '。';
  }

  build() {
    Column({ space: 10 }) {
      Column() {
        Column() {
          Row({ space: 10 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.mic_fill_waves_left_and_right')).fontSize(20).fontColor([this.accent])
            }.width(38).height(38).borderRadius(12).backgroundColor(this.pal().surface)
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text('AI 语音').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                this.betaChip()
              }
              Text('Siri 式语音模式、按住说话和更自然的朗读。仍在测试中，可能不稳定。')
                .fontSize(12).lineHeight(17).fontColor(this.pal().text3)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.config.enabled }).selectedColor(this.accent)
              .onChange((on: boolean): void => { this.setEnabled(on); })
          }.width('100%').padding({ top: 14, bottom: 14 })
        }.width('100%')
      }.cardStyle()
      if (this.message !== '') {
        Text(this.message).fontSize(12).fontColor(this.accent).width('100%').padding({ left: 4 })
          .transition(TransitionEffect.OPACITY)
      }
      if (this.config.enabled) {
        Column({ space: 10 }) {
          this.label('语音引擎')
          Column() {
            Column() {
              ForEach(AI_TTS_PROVIDERS, (provider: AiTtsProvider): void => { this.engineRow(provider) },
                (provider: AiTtsProvider): string => provider.id + (provider.id === this.config.provider ? '-on' : ''))
            }.width('100%')
          }.cardStyle()
          if (this.config.provider === 'system') {
            this.systemDetails()
          } else {
            this.cloudDetails()
          }
          Column() {
            Column({ space: 10 }) {
              Text('语速').fontSize(13).fontColor(this.pal().text3).width('100%')
              AiSegmented({ options: [['slow', '慢'], ['normal', '正常'], ['fast', '快']], current: this.config.rate,
                trackColor: this.pal().surface, textColor: this.pal().text, segmentHeight: 34,
                onPick: (rate: string): void => { this.settings.setRate(rate); this.reload(); } })
              Row({ space: 8 }) {
                SymbolGlyph($r(this.sampling ? 'sys.symbol.stop_circle_fill' : 'sys.symbol.play_fill')).fontSize(14)
                  .fontColor([appUiOnAccentText(this.accent)])
                Text(this.sampling ? '停止试听' : '试听').fontSize(14).fontWeight(FontWeight.Medium).fontColor(appUiOnAccentText(this.accent))
              }.height(38).padding({ left: 16, right: 16 }).borderRadius(19).backgroundColor(this.accent)
              .onClick((): void => { this.sample(); })
            }.width('100%').padding({ top: 12, bottom: 14 }).alignItems(HorizontalAlign.Start)
          }.cardStyle()
          if (this.config.provider !== 'system' && this.keyPrint === '') {
            Text('还没有保存 ' + this.provider().name + ' 的密钥，朗读暂时使用系统语音。')
              .fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4 })
          }
          this.label('语音识别')
          this.asrCard()
          this.label('语音模式')
          Column() {
            Column() {
              this.switchRow('连续对话', '回答说完后接着听你说，直到你说“再见”或点关闭', this.config.continuous,
                (on: boolean): void => { this.settings.setContinuous(on); this.reload(); })
              Divider().color(this.pal().divider)
              this.switchRow('按住 AI 按钮说话', '在主页长按 AI 按钮开始说话，松手发送', this.config.holdToTalk,
                (on: boolean): void => { this.settings.setHoldToTalk(on); this.reload(); })
            }.width('100%')
          }.cardStyle()
          Text(this.privacyText())
            .fontSize(12).lineHeight(18).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4, bottom: 8 })
        }.width('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 })))
      }
    }.width('100%')
  }
}
