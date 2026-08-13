import { promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightSettings, defaultMoonlightSettings } from '../model/MoonlightModels';
import { CloudStore } from '../services/CloudStore';
import {
  MoonlightLocalSettingsResult,
  MoonlightSettingsLocalService
} from '../services/MoonlightSettingsLocalService';
import {
  MoonlightRouteIdentity,
  MoonlightSettingsSection,
  moonlightRouteIdentity,
  moonlightSettingsSectionLabel,
  moonlightSettingsSections
} from '../services/MoonlightUiPolicy';

function cloneSettings(settings: MoonlightSettings): MoonlightSettings {
  return JSON.parse(JSON.stringify(settings)) as MoonlightSettings;
}

@Component
export struct MoonlightSettingsSurface {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop embedded: boolean = false;
  @Prop requestedSection: MoonlightSettingsSection = 'quick';
  @Prop requestedHostId: string = '';
  @State hostId: string = '';
  @State section: MoonlightSettingsSection = 'quick';
  @State settings: MoonlightSettings = defaultMoonlightSettings();
  @State dirty: boolean = false;
  @State saveCode: string = '';
  private readonly service: MoonlightSettingsLocalService =
    new MoonlightSettingsLocalService(CloudStore.getInstance());
  private savedSettingsCanonical: string = '';
  onClose: () => void = (): void => {};
  onDirtyChanged: (dirty: boolean) => void = (_dirty: boolean): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private topSafeHeight(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  aboutToAppear(): void {
    if (this.embedded) {
      this.hostId = this.requestedHostId.trim();
      this.section = moonlightSettingsSections().indexOf(this.requestedSection) >= 0 ?
        this.requestedSection : 'quick';
    } else {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      const route: MoonlightRouteIdentity = moonlightRouteIdentity(params);
      this.hostId = route.valid ? route.hostId : '';
      const sectionValue: Object | undefined = params['moonlightSettingsSection'];
      if (typeof sectionValue === 'string' &&
          moonlightSettingsSections().indexOf(sectionValue as MoonlightSettingsSection) >= 0) {
        this.section = sectionValue as MoonlightSettingsSection;
      }
    }
    const loaded: MoonlightLocalSettingsResult = this.service.load();
    this.settings = loaded.settings;
    this.savedSettingsCanonical = JSON.stringify(loaded.settings);
    this.saveCode = loaded.ok ? '' : loaded.code;
    this.dirty = false;
    this.onDirtyChanged(false);
  }

  private update(change: (next: MoonlightSettings) => void): void {
    const next: MoonlightSettings = cloneSettings(this.settings);
    change(next);
    this.settings = next;
    this.dirty = JSON.stringify(next) !== this.savedSettingsCanonical;
    this.onDirtyChanged(this.dirty);
    this.saveCode = '';
  }

  private save(): void {
    const saved: MoonlightLocalSettingsResult = this.service.save(this.settings, Date.now());
    this.saveCode = saved.code;
    if (saved.localCommitted) {
      this.savedSettingsCanonical = JSON.stringify(this.settings);
      this.dirty = false;
      this.onDirtyChanged(false);
      promptAction.showToast({
        message: saved.ok ? 'Moonlight 设置已保存到当前账号本地' :
          '设置已提交到本地；正在等待本地回读确认',
        duration: saved.ok ? 1800 : 2400
      });
    } else {
      promptAction.showToast({ message: '本地设置保存失败：' + saved.code, duration: 2200 });
    }
  }

  private close(): void {
    if (this.embedded) {
      this.onClose();
      return;
    }
    if (!this.dirty) { router.back(); return; }
    promptAction.showDialog({
      title: '放弃未保存的 Moonlight 设置？',
      message: '当前修改只在本页草稿中，尚未写入本地记录。',
      buttons: [
        { text: '继续编辑', color: this.pal().text2 },
        { text: '放弃修改', color: this.pal().danger }
      ]
    }).then((value: Object): void => {
      const decision: Record<string, number> = value as Record<string, number>;
      if (decision['index'] === 1) { router.back(); }
    });
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface)
        .onClick((): void => { this.close(); }).accessibilityText('返回')
      MoonlightBrandIcon({ iconSize: 30, tint: this.accentColor }).margin({ left: 12 })
      Column() {
        Text(this.embedded ? moonlightSettingsSectionLabel(this.section) : 'Moonlight 设置')
          .fontSize(this.embedded ? 20 : 24).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(this.embedded ? 'Moonlight · 当前账号本地' :
          '全局默认 · 主机/应用可覆盖 · 当前仅本地').fontSize(10)
          .fontColor(this.pal().text3).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      if (this.dirty) {
        Text('未保存').fontSize(10).fontColor(this.pal().editColor)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.pal().editColor + '16').borderRadius(10).margin({ right: 8 })
      }
      Button('保存').height(40).fontSize(13).borderRadius(12)
        .backgroundColor(this.dirty ? this.accentColor : this.pal().surface)
        .fontColor(this.dirty ? Color.White : this.pal().text3).enabled(this.dirty)
        .onClick((): void => { this.save(); })
    }.width('100%').padding({
      left: this.embedded ? 16 : 18,
      right: this.embedded ? 16 : 18,
      top: this.embedded ? 10 : this.topSafeHeight() + 8,
      bottom: this.embedded ? 8 : 10
    })
  }

  @Builder private categoryButton(section: MoonlightSettingsSection) {
    Button() {
      Row() {
        Text(moonlightSettingsSectionLabel(section)).fontSize(13)
          .fontWeight(this.section === section ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.section === section ? this.accentColor : this.pal().text2)
          .layoutWeight(1).textAlign(TextAlign.Start)
        if (section === 'cloud') {
          Text('停用').fontSize(9).fontColor(this.pal().text3)
        }
      }.width('100%')
    }.width(this.embedded && this.breakpoint !== 'sm' ? '100%' :
      (this.breakpoint === 'xl' ? '100%' : 118)).height(42).borderRadius(12)
      .backgroundColor(this.section === section ? this.accentColor + '16' : this.pal().surface)
      .onClick((): void => {
        this.section = section;
      })
  }

  @Builder private sectionHeader(title: string, detail: string) {
    Column() {
      if (!this.embedded) {
        Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily)
      }
      Text(detail).fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
        .lineHeight(17).margin({ top: this.embedded ? 0 : 5 })
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: this.embedded ? 10 : 14 })
  }

  @Builder private cardTitle(title: string, subtitle: string = '') {
    Column() {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
      if (subtitle !== '') {
        Text(subtitle).fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
      }
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 10 })
  }

  @Builder private toggleRow(title: string, detail: string, checked: boolean,
    onChange: (value: boolean) => void, enabled: boolean = true) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(enabled ? this.pal().text : this.pal().text3)
        Text(detail).fontSize(10).fontColor(this.pal().text3).lineHeight(15).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked }).selectedColor(this.accentColor)
        .enabled(enabled).opacity(enabled ? 1 : 0.55).onChange(onChange).scale({ x: 0.86, y: 0.86 })
    }.width('100%').height(62).padding({ top: 6, bottom: 6 })
  }

  @Builder private sliderRow(title: string, detail: string, value: number,
    minimum: number, maximum: number, step: number, suffix: string,
    onCommit: (value: number) => void) {
    Column() {
      Row() {
        Column() {
          Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text(detail).fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(Math.round(value).toString() + suffix).fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ value: value, min: minimum, max: maximum, step: step })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .onChange((next: number, mode: SliderChangeMode): void => {
          if (mode === SliderChangeMode.End) { onCommit(next); }
        }).margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private choice3(first: string, second: string, third: string,
    current: string, firstValue: string, secondValue: string, thirdValue: string,
    onChoose: (value: string) => void, thirdEnabled: boolean = true) {
    Row({ space: 7 }) {
      Button(first).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
        .backgroundColor(current === firstValue ? this.accentColor : this.pal().surface)
        .fontColor(current === firstValue ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose(firstValue); })
      Button(second).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
        .backgroundColor(current === secondValue ? this.accentColor : this.pal().surface)
        .fontColor(current === secondValue ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose(secondValue); })
      Button(third).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
        .backgroundColor(current === thirdValue ? this.accentColor : this.pal().surface)
        .fontColor(current === thirdValue ? Color.White : this.pal().text2)
        .enabled(thirdEnabled).opacity(thirdEnabled ? 1 : 0.55)
        .onClick((): void => { onChoose(thirdValue); })
    }.width('100%')
  }

  @Builder private quickContent() {
    this.sectionHeader('快速设置', '先选常用体验，再到各叶页精调。实际设置会按主机和设备能力安全降级。')
    Column() {
      this.cardTitle('体验预设', '预设只改本地草稿，点击保存后原子写入 Moonlight 本地记录')
      Row({ space: 8 }) {
        Button('低延迟').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.latencyMode === 'lowLatency' ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.latencyMode === 'lowLatency' ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.latencyMode = 'lowLatency'; next.video.fps = 60; next.video.bitrateKbps = 20000;
          }); })
        Button('平衡').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.latencyMode === 'balanced' ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.latencyMode === 'balanced' ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.latencyMode = 'balanced'; next.video.fps = 60; next.video.bitrateKbps = 30000;
          }); })
        Button('画质优先').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.latencyMode === 'smooth' ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.latencyMode === 'smooth' ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.latencyMode = 'smooth'; next.video.fps = 60; next.video.bitrateKbps = 50000;
          }); })
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('当前默认')
      this.toggleRow('接收音频', '使用已接入的 Opus 解码与系统音频输出链路', this.settings.audio.enabled,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.enabled = value; }); })
      Divider().color(this.pal().divider)
      this.toggleRow('自动重连', '有限预算，不并行创建第二连接', this.settings.network.autoReconnect,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.network.autoReconnect = value; }); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private videoContent() {
    this.sectionHeader('画面', '编码、分辨率、帧率与码率。需要重新协商的变更不会伪装为会话内即时生效。')
    Column() {
      this.cardTitle('编码与显示')
      Text('编码偏好').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice3('自动', 'H.264', 'HEVC', this.settings.video.codecPreference,
        'auto', 'h264', 'hevc', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.video.codecPreference = value as 'auto'; });
        })
      Text('分辨率').fontSize(11).fontColor(this.pal().text3).margin({ top: 14, bottom: 7 })
      this.choice3('跟随主机', '1080p', '2160p', this.settings.video.resolutionMode,
        'host', '1080p', '2160p', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.video.resolutionMode = value as 'host'; });
        })
      this.sliderRow('帧率', '30–240 FPS，按设备与主机能力下调', this.settings.video.fps,
        30, 240, 30, ' FPS', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.video.fps = Math.round(value); });
        })
      this.sliderRow('码率', '拖动结束才持久化，避免高频写盘', this.settings.video.bitrateKbps,
        1000, 200000, 1000, ' Kbps', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.video.bitrateKbps = Math.round(value); });
        })
      this.toggleRow('HDR', '设备、Surface 与主机链路全部支持才启用', this.settings.video.hdr,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.video.hdr = value; }); })
      Divider().color(this.pal().divider)
      this.toggleRow('YUV 4:4:4', '不可用时保留原值并显示实际降级原因', this.settings.video.yuv444,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.video.yuv444 = value; }); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('缩放与延迟')
      Text('延迟策略').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice3('低延迟', '平衡', '平滑', this.settings.video.latencyMode,
        'lowLatency', 'balanced', 'smooth', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.video.latencyMode = value as 'lowLatency'; });
        })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private audioContent() {
    this.sectionHeader('音频', '音量与启用状态可会话内调整；声道变化在下次连接生效。')
    Column() {
      this.toggleRow('接收主机音频', '关闭后不初始化音频输出', this.settings.audio.enabled,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.enabled = value; }); })
      Divider().color(this.pal().divider)
      this.sliderRow('默认音量', '0–100%，焦点丢失时不会反复抢占', this.settings.audio.volume * 100,
        0, 100, 1, '%', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.audio.volume = Math.round(value) / 100; });
        })
      Text('声道').fontSize(11).fontColor(this.pal().text3).margin({ top: 8, bottom: 7 })
      this.choice3('立体声', '5.1', '7.1', this.settings.audio.channels,
        'stereo', 'surround51', 'surround71', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.audio.channels = value as 'stereo'; });
        })
      this.toggleRow('主机同时播放', '由 Sunshine 能力与主机设置共同决定', this.settings.audio.playOnHost,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.playOnHost = value; }); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private inputContent() {
    this.sectionHeader('控制与手柄', '触摸、鼠标、键盘、虚拟控制器和实体手柄共享唯一 native input owner。')
    Column() {
      this.cardTitle('控制模式')
      this.choice3('直接触控', '绝对鼠标', '相对鼠标', this.settings.input.touchMode,
        'touch', 'absoluteMouse', 'relativeMouse', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.input.touchMode = value as 'touch'; });
        })
      this.toggleRow('捕获键盘', '保留系统逃生键，失焦或退出补发全部 key-up', this.settings.input.captureKeyboard,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.input.captureKeyboard = value; }); })
      Divider().color(this.pal().divider)
      this.toggleRow('转发系统快捷键', '仅能力允许的组合键可发送', this.settings.input.forwardSystemShortcuts,
        (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.input.forwardSystemShortcuts = value; });
        })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('控制器', '实体与虚拟事件都只提交语义状态，由 native 聚合并发送 full-state')
      Text('控制器槽位').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice3('自动', '槽位 1', '槽位 2', this.settings.input.controllerSlot.toString(),
        '-1', '0', '1', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.input.controllerSlot = Number(value); });
        })
      this.toggleRow('手柄震动', '当前未接入主机到手柄的反馈输出，保持不可用',
        this.settings.input.enableRumble, (_value: boolean): void => {}, false)
      Row() {
        SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(17).fontColor([this.pal().editColor])
        Text('ArkTS 不编码或直发手柄协议；source 切换、编辑态、后台与退出先发送 neutral。')
          .fontSize(10).fontColor(this.pal().text3).layoutWeight(1).lineHeight(15).margin({ left: 8 })
      }.width('100%').padding(10).backgroundColor(this.pal().surface).borderRadius(12).margin({ top: 8 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private networkContent() {
    this.sectionHeader('网络与安全', '发现、地址族、加密、计费网络、重连预算和证书变化策略。')
    Column() {
      this.cardTitle('网络')
      Text('发现方式').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice3('自动 + 手动', '仅手动', '—', this.settings.network.discovery,
        'manualOrMdns', 'manualOnly', 'none', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.discovery = value as 'manualOnly'; });
        }, false)
      Text('地址偏好').fontSize(11).fontColor(this.pal().text3).margin({ top: 14, bottom: 7 })
      this.choice3('自动', 'IPv4', 'IPv6', this.settings.network.preferredAddressFamily,
        'auto', 'ipv4', 'ipv6', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.preferredAddressFamily = value as 'auto'; });
        })
      Text('计费网络').fontSize(11).fontColor(this.pal().text3).margin({ top: 14, bottom: 7 })
      this.choice3('每次询问', '允许', '禁止', this.settings.network.meteredNetwork,
        'ask', 'allow', 'deny', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.meteredNetwork = value as 'ask'; });
        })
      this.toggleRow('自动重连', '有限预算，旧 generation 完整停止后才重建', this.settings.network.autoReconnect,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.network.autoReconnect = value; }); })
      this.sliderRow('重连预算', '预算耗尽进入失败终态并保留退出路径',
        this.settings.network.reconnectBudgetMs / 1000, 0, 120, 1, ' 秒', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.network.reconnectBudgetMs = Math.round(value) * 1000; });
        })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('安全')
      Text('串流加密').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice3('自动', '必须加密', '兼容', this.settings.network.streamEncryption,
        'auto', 'required', 'compatible', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.streamEncryption = value as 'auto'; });
        })
      this.toggleRow('阻止证书变化', '安全合同强制开启；变化时必须重新核对与配对，不提供“一直忽略”',
        this.settings.security.blockCertificateChanges, (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.security.blockCertificateChanges = value; });
        }, false)
      Divider().color(this.pal().divider)
      this.toggleRow('允许旧 SHA-1', '高风险兼容项，默认关闭', this.settings.network.allowLegacySha1,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.network.allowLegacySha1 = value; }); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private backgroundContent() {
    this.sectionHeader('后台串流', '这里仅保留 Moonlight 协议独有的后台音频与无 Surface 视频策略。')
    Column() {
      this.toggleRow('后台继续音频', '仍服从系统音频焦点与后台任务限制',
        this.settings.background.allowAudioInBackground, (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.background.allowAudioInBackground = value; });
        })
      Text('无 Surface 视频策略').fontSize(11).fontColor(this.pal().text3).margin({ top: 12, bottom: 7 })
      this.choice3('丢帧保连接', '暂停视频', '—', this.settings.background.noSurfaceVideo,
        'drop', 'pause', 'none', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.background.noSurfaceVideo = value as 'drop'; });
        }, false)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private diagnosticsContent() {
    this.sectionHeader('诊断', '默认只显示可行动摘要；专业指标按需、低频采样，不让 ArkUI 每帧重排。')
    Column() {
      this.toggleRow('默认显示性能 HUD', '简洁 chip 可点击展开并拖动吸附',
        this.settings.diagnostics.showPerformanceHud, (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.diagnostics.showPerformanceHud = value; });
        })
      Text('日志级别').fontSize(11).fontColor(this.pal().text3).margin({ top: 12, bottom: 7 })
      this.choice3('错误', '信息', '调试', this.settings.diagnostics.logLevel,
        'error', 'info', 'debug', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.diagnostics.logLevel = value as 'error'; });
        })
      Row() {
        SymbolGlyph($r('sys.symbol.text_clipboard')).fontSize(19).fontColor([this.accentColor])
        Column() {
          Text('脱敏诊断导出').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('不包含地址、PIN、证书、身份材料或会话密钥').fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        Text('连接后可用').fontSize(10).fontColor(this.pal().text3)
      }.width('100%').padding({ top: 12, bottom: 6 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private cloudContent() {
    this.sectionHeader('云同步范围', '按当前产品决定，Moonlight 暂时只使用本地主机存储；云表、选择器与上传全部停用。')
    Column() {
      this.cardTitle('当前状态', '不会注册、创建或上传 moonlightrecordv1')
      ForEach(['设置', '主机', '应用配置', '信任', '身份'], (label: string): void => {
        Row() {
          Text(label).fontSize(14).fontColor(this.pal().text3).layoutWeight(1)
          Text('仅本地').fontSize(10).fontColor(this.pal().text3)
          Toggle({ type: ToggleType.Switch, isOn: false }).enabled(false).opacity(0.5).scale({ x: 0.82, y: 0.82 })
            .margin({ left: 8 })
        }.width('100%').height(48)
      })
      Text('现有云同步仍精确使用原 8 张表；Moonlight 不进入 CloudSyncCoordinator。')
        .fontSize(10).fontColor(this.pal().editColor).lineHeight(16).width('100%').margin({ top: 8 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private trustContent() {
    this.sectionHeader('配对与信任', '安全身份留在本地安全边界；证书变化会阻止连接并要求重新配对。')
    Column() {
      this.cardTitle(this.hostId === '' ? '全局信任策略' : '当前主机',
        this.hostId === '' ? '从具体主机详情进入可查看绑定状态' : '主机 ID：' + this.hostId)
      this.toggleRow('阻止证书变化', '安全合同强制开启；不提供永久忽略，降低中间人风险',
        this.settings.security.blockCertificateChanges, (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.security.blockCertificateChanges = value; });
        }, false)
      Row() {
        SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(22).fontColor([this.pal().success])
        Column() {
          Text('身份存储：仅本地安全存储').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('PIN、私钥和会话密钥不进入页面状态、日志或云同步。').fontSize(10).fontColor(this.pal().text3).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      }.width('100%').padding({ top: 12, bottom: 6 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private activeContent() {
    if (this.section === 'quick') { this.quickContent() }
    else if (this.section === 'video') { this.videoContent() }
    else if (this.section === 'audio') { this.audioContent() }
    else if (this.section === 'input') { this.inputContent() }
    else if (this.section === 'networkSecurity') { this.networkContent() }
    else if (this.section === 'background') { this.backgroundContent() }
    else if (this.section === 'diagnostics') { this.diagnosticsContent() }
    else if (this.section === 'cloud') { this.cloudContent() }
    else { this.trustContent() }
  }

  build() {
    Column() {
      this.header()
      if (this.saveCode !== '' && this.saveCode !== 'default') {
        Text('本地设置状态：' + this.saveCode).fontSize(10).fontColor(this.pal().editColor)
          .width('100%').padding({ left: 22, right: 22, bottom: 6 })
      }
      if (this.embedded) {
        Scroll() {
          Column() { this.activeContent() }.width('100%').constraintSize({ maxWidth: 720 })
            .padding({ left: 16, right: 16, top: 8, bottom: 22 })
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      } else if (this.breakpoint === 'xl') {
        Row() {
          Scroll() {
            Column({ space: 7 }) {
              ForEach(moonlightSettingsSections(), (item: MoonlightSettingsSection): void => {
                this.categoryButton(item)
              }, (item: MoonlightSettingsSection): string => item)
            }.width('100%')
          }.width(220).height('100%').scrollBar(BarState.Off)
          Scroll() {
            Column() { this.activeContent() }
              .width('100%').constraintSize({ maxWidth: 820 }).padding({ left: 24, right: 28, bottom: 28 })
          }.layoutWeight(1).height('100%').scrollBar(BarState.Off)
        }.width('100%').layoutWeight(1).padding({ left: 24 })
      } else {
        Scroll() {
          Row({ space: 7 }) {
            ForEach(moonlightSettingsSections(), (item: MoonlightSettingsSection): void => {
              this.categoryButton(item)
            }, (item: MoonlightSettingsSection): string => item)
          }
        }.width('100%').height(50).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .padding({ left: 16, right: 16 })
        Scroll() {
          Column() { this.activeContent() }.width('100%').constraintSize({ maxWidth: 820 })
            .padding({ left: 18, right: 18, top: 12, bottom: 28 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      }
    }.width('100%').height('100%').backgroundColor(this.embedded ? this.pal().sheetBg : this.pal().bg)
  }
}

@Entry
@Component
struct MoonlightSettingsPage {
  build() {
    Column() {
      MoonlightSettingsSurface()
    }.width('100%').height('100%')
  }
}
