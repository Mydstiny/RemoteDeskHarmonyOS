import { promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightSettings, defaultMoonlightSettings } from '../model/MoonlightModels';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../services/AccountScopePolicy';
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
  private editingLease: AccountSessionLease | null = null;
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
    this.loadCurrentSettings();
  }

  private loadCurrentSettings(): void {
    const store: CloudStore = CloudStore.getInstance();
    const before: AccountSessionLease | null = store.currentAccountLease();
    const loaded: MoonlightLocalSettingsResult = this.service.load();
    const after: AccountSessionLease | null = store.currentAccountLease();
    if (before === null || after === null ||
        !accountSessionLeaseEquals(before, after) || !store.isLeaseCurrent(after)) {
      this.editingLease = null;
      this.settings = defaultMoonlightSettings();
      this.savedSettingsCanonical = JSON.stringify(this.settings);
      this.saveCode = 'account_changed';
      this.dirty = false;
      this.onDirtyChanged(false);
      return;
    }
    this.editingLease = cloneAccountSessionLease(after);
    this.settings = loaded.settings;
    this.savedSettingsCanonical = JSON.stringify(loaded.settings);
    this.saveCode = loaded.ok ? '' : loaded.code;
    this.dirty = false;
    this.onDirtyChanged(false);
  }

  private update(change: (next: MoonlightSettings) => void): void {
    if (this.editingLease === null) {
      this.saveCode = 'account_changed';
      return;
    }
    const next: MoonlightSettings = cloneSettings(this.settings);
    change(next);
    this.settings = next;
    this.dirty = JSON.stringify(next) !== this.savedSettingsCanonical;
    this.onDirtyChanged(this.dirty);
    this.saveCode = '';
  }

  private save(): void {
    const editingLease: AccountSessionLease | null = this.editingLease;
    if (editingLease === null) {
      this.loadCurrentSettings();
      promptAction.showToast({ message: '账号状态已变化，请重新确认设置后再保存', duration: 2400 });
      return;
    }
    const saved: MoonlightLocalSettingsResult =
      this.service.save(this.settings, Date.now(), editingLease);
    if (saved.code === 'stale_account') {
      this.loadCurrentSettings();
      promptAction.showToast({ message: '账号已切换，旧账号的设置草稿已丢弃', duration: 2400 });
      return;
    }
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
          '当前账号全局默认 · 当前仅本地').fontSize(10)
          .fontColor(this.pal().text3).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      if (this.dirty) {
        Text('未保存').fontSize(10).fontColor(this.pal().editColor)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.pal().editColor + '16').borderRadius(10).margin({ right: 8 })
      }
      Button('保存').height(40).fontSize(13).borderRadius(12)
        .backgroundColor(this.dirty && this.editingLease !== null ? this.accentColor : this.pal().surface)
        .fontColor(this.dirty && this.editingLease !== null ? Color.White : this.pal().text3)
        .enabled(this.dirty && this.editingLease !== null)
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

  @Builder private statusRow(title: string, detail: string, value: string) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(detail).fontSize(10).fontColor(this.pal().text3).lineHeight(15).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(value).fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
        .padding({ left: 9, right: 9, top: 5, bottom: 5 })
        .backgroundColor(this.accentColor + '14').borderRadius(10).margin({ left: 12 })
    }.width('100%').padding({ top: 9, bottom: 9 })
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

  @Builder private choice2(first: string, second: string,
    current: string, firstValue: string, secondValue: string,
    onChoose: (value: string) => void) {
    Row({ space: 7 }) {
      Button(first).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
        .backgroundColor(current === firstValue ? this.accentColor : this.pal().surface)
        .fontColor(current === firstValue ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose(firstValue); })
      Button(second).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
        .backgroundColor(current === secondValue ? this.accentColor : this.pal().surface)
        .fontColor(current === secondValue ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose(secondValue); })
    }.width('100%')
  }

  @Builder private quickContent() {
    this.sectionHeader('快速设置', '先选常用码率预设，再到画面页精调。实际设置会按设备能力安全降级。')
    Column() {
      this.cardTitle('体验预设', '预设只改本地草稿，点击保存后原子写入 Moonlight 本地记录')
      Row({ space: 8 }) {
        Button('省流').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps <= 20000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps <= 20000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = 60; next.video.bitrateKbps = 20000;
          }); })
        Button('平衡').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps > 20000 &&
            this.settings.video.bitrateKbps < 50000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps > 20000 &&
            this.settings.video.bitrateKbps < 50000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = 60; next.video.bitrateKbps = 30000;
          }); })
        Button('画质优先').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps >= 50000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps >= 50000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = 60; next.video.bitrateKbps = 50000;
          }); })
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('当前默认')
      this.statusRow('当前媒体能力', '发布版使用已验证的保守协商组合', 'H.264 · 立体声')
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private videoContent() {
    this.sectionHeader('画面', '编码、分辨率、帧率与码率。需要重新协商的变更不会伪装为会话内即时生效。')
    Column() {
      this.cardTitle('编码与显示')
      this.statusRow('视频编码', '当前 HarmonyOS 解码链路只协商已完成验收的编码', 'H.264')
      Text('分辨率').fontSize(11).fontColor(this.pal().text3).margin({ top: 14, bottom: 7 })
      this.choice3('默认 1080p', '720p', '1080p', this.settings.video.resolutionMode,
        'host', '720p', '1080p', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.video.resolutionMode = value as 'host'; });
        })
      this.sliderRow('帧率', '当前发布链路支持 30 或 60 FPS', this.settings.video.fps,
        30, 60, 30, ' FPS', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.video.fps = Math.round(value); });
        })
      this.sliderRow('码率', '拖动结束才持久化，避免高频写盘', this.settings.video.bitrateKbps,
        1000, 200000, 1000, ' Kbps', (value: number): void => {
          this.update((next: MoonlightSettings): void => { next.video.bitrateKbps = Math.round(value); });
        })
      this.toggleRow('HDR', '当前媒体管线尚未开放，避免保存后静默降级', false,
        (_value: boolean): void => {}, false)
      Divider().color(this.pal().divider)
      this.toggleRow('YUV 4:4:4', '当前媒体管线尚未开放，保持不可用', false,
        (_value: boolean): void => {}, false)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private audioContent() {
    this.sectionHeader('音频', 'Moonlight 只管理协议独有的音频启用与主机播放策略；音量跟随系统。')
    Column() {
      this.toggleRow('接收主机音频', '关闭后不初始化音频输出', this.settings.audio.enabled,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.enabled = value; }); })
      Divider().color(this.pal().divider)
      this.statusRow('音量', '与其他远程协议一致，统一使用系统媒体音量', '跟随系统')
      Divider().color(this.pal().divider)
      this.statusRow('声道', '当前 Opus 输出链路已完成双声道验收', '立体声')
      this.toggleRow('主机同时播放', '由 Sunshine 能力与主机设置共同决定', this.settings.audio.playOnHost,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.playOnHost = value; }); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private inputContent() {
    this.sectionHeader('控制与手柄', '触摸、鼠标、键盘、虚拟控制器和实体手柄共享唯一 native input owner。')
    Column() {
      this.cardTitle('控制模式')
      this.choice3('直接触控', '触控板', '相对鼠标', this.settings.input.touchMode,
        'touch', 'absoluteMouse', 'relativeMouse', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.input.touchMode = value as 'touch'; });
        }, false)
      this.toggleRow('捕获键盘', '串流画面获得焦点时转发实体键盘；退出时补发全部 key-up', this.settings.input.captureKeyboard,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.input.captureKeyboard = value; }); })
      Divider().color(this.pal().divider)
      this.toggleRow('转发系统快捷键', '系统保留组合键尚未开放，普通按键仍可发送', false,
        (_value: boolean): void => {}, false)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('控制器', '实体与虚拟事件都只提交语义状态，由 native 聚合并发送 full-state')
      this.statusRow('控制器槽位', '实体与虚拟手柄统一进入 native full-state 聚合器', '槽位 1')
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
    this.sectionHeader('网络与安全', '局域网发现、地址族、串流加密与证书变化策略。')
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
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('安全')
      Text('串流加密').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      this.choice2('自动协商', '兼容旧主机',
        this.settings.network.streamEncryption === 'compatible' ? 'compatible' : 'auto',
        'auto', 'compatible', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.streamEncryption = value as 'auto'; });
        })
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
            .enabled(this.editingLease !== null).opacity(this.editingLease !== null ? 1 : 0.55)
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
              .enabled(this.editingLease !== null).opacity(this.editingLease !== null ? 1 : 0.55)
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
            .enabled(this.editingLease !== null).opacity(this.editingLease !== null ? 1 : 0.55)
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
