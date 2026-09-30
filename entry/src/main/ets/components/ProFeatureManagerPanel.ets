import { common } from '@kit.AbilityKit';
import { DEBUG } from 'BuildProfile';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSettingsChoiceButton } from './AppSettingsChoiceButton';
import { ProBadge } from './ProBadge';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProEntries } from '../services/pro/ProEntries';
import { ProFeature } from '../services/pro/ProFeatureCatalog';
import { ProFeatureStatus, proFeatureScope } from '../services/pro/ProFeatureStatus';
import { proFeatureCurrentStatus, proStateText } from '../services/pro/ProFeatureStatusReader';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
import { ProDebugMode, ProRuntimeSnapshot } from '../services/pro/ProRuntime';
import { ProContinuationCredentialMode, ProContinuationPreferences,
  ProContinuationSettings } from '../services/pro/ProContinuationPreferences';
import { PRO_CONTINUATION_FEATURE } from '../services/pro/ProContinuationService';

const DEBUG_MODES: ProDebugMode[] = ['real', 'free', 'pro'];

/** Settings sheet: the account's Pro state and, in Debug, the entitlement simulation. */
@Component
export struct ProStatusPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State revision: number = 0;
  private stop: (() => void) | null = null;
  aboutToAppear(): void { this.stop = ProEntries.subscribe((): void => { this.revision++; }); }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private runtime(_revision: number): ProRuntimeSnapshot { return ProAppRuntime.getInstance().runtime.snapshot(); }
  private modeLabel(mode: ProDebugMode): string {
    return mode === 'real' ? '跟随真实' : mode === 'free' ? '模拟免费' : '模拟 Pro';
  }
  build() {
    Column({ space: 14 }) {
      Row() {
        Text('Pro 状态').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
        ProBadge()
      }.width('100%')
      Row() {
        Text('当前').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).layoutWeight(1)
        Text(proStateText(this.runtime(this.revision))).fontSize(14).fontColor(this.accent).fontFamily(AppConfig.fontFamily)
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
      if (DEBUG) {
        Column({ space: 10 }) {
          Text('开发者调试 · 权益模拟').fontSize(14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
          Row({ space: 8 }) {
            ForEach(DEBUG_MODES, (mode: ProDebugMode): void => {
              AppSettingsChoiceButton({ label: this.modeLabel(mode), isSelected: this.runtime(this.revision).mode === mode,
                onSelect: (): void => { ProAppRuntime.getInstance().runtime.setDebugMode(mode); } }).layoutWeight(1)
            }, (mode: ProDebugMode): string => mode)
          }.width('100%')
          Text('仅当前运行有效，重启后恢复跟随真实。切到模拟免费后，本栏目会随 Pro 一起隐藏，可在 Pro 页面切回。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(18).width('100%')
        }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
  }
}

/** Settings sheet for one Pro feature: live status, scope, display switch and its own options. */
@Component
export struct ProFeatureDetailPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop featureId: string = '';
  @State revision: number = 0;
  @State continuation: ProContinuationSettings = ProContinuationPreferences.getInstance().settings();
  private contextValue: common.UIAbilityContext | null = null;
  private stop: (() => void) | null = null;
  private stopContinuation: (() => void) | null = null;

  aboutToAppear(): void {
    this.contextValue = getContext(this) as common.UIAbilityContext;
    ProFeatureVisibility.getInstance().load(this.contextValue);
    ProContinuationPreferences.getInstance().load(this.contextValue);
    this.stop = ProEntries.subscribe((): void => { this.revision++; });
    this.stopContinuation = ProContinuationPreferences.getInstance().subscribe((): void => {
      this.continuation = ProContinuationPreferences.getInstance().settings();
    });
  }
  aboutToDisappear(): void {
    this.stop?.(); this.stop = null; this.stopContinuation?.(); this.stopContinuation = null; this.contextValue = null;
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private feature(_revision: number): ProFeature | undefined {
    return ProFeatureVisibility.getInstance().proCatalog().find((item: ProFeature): boolean => item.id === this.featureId);
  }
  private status(_revision: number): ProFeatureStatus | null {
    const feature = this.feature(this.revision);
    return feature === undefined ? null : proFeatureCurrentStatus(feature);
  }
  private toneColor(status: ProFeatureStatus | null): ResourceColor {
    if (status !== null && status.tone === 'ready') { return this.accent; }
    if (status !== null && status.tone === 'experimental') { return '#B26A00'; }
    return this.pal().text3;
  }
  private updateContinuation(auto: boolean, mode: ProContinuationCredentialMode): void {
    if (this.contextValue === null) { return; }
    ProContinuationPreferences.getInstance().update(this.contextValue, { auto, credentialMode: mode });
  }
  @Builder private switchRow(title: string, detail: string, isOn: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
        if (detail.length > 0) {
          Text(detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn }).selectedColor(this.accent).accessibilityText(title).onChange(onChange)
    }.width('100%').padding(16)
  }
  @Builder private continuationOptions() {
    Column() {
      this.switchRow('Pro 下自动开启接续', '连上直连 SSH、RustDesk 或 VNC 后自动允许在同账号设备继续；关闭后需在会话菜单中手动准备',
        this.continuation.auto, (on: boolean): void => { this.updateContinuation(on, this.continuation.credentialMode); })
      Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
      Column({ space: 10 }) {
        Text('接续时的密码与密钥').fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
        Row({ space: 8 }) {
          AppSettingsChoiceButton({ label: '自己输入（默认）', isSelected: this.continuation.credentialMode === 'manual',
            onSelect: (): void => { this.updateContinuation(this.continuation.auto, 'manual'); } }).layoutWeight(1)
          AppSettingsChoiceButton({ label: '随接续传输', isSelected: this.continuation.credentialMode === 'transfer',
            onSelect: (): void => { this.updateContinuation(this.continuation.auto, 'transfer'); } }).layoutWeight(1)
        }.width('100%')
        Text(this.continuation.credentialMode === 'manual' ?
          '目标设备使用它自己保存的密码或密钥；没有保存时由你在目标设备输入。密码和私钥不会离开本设备。' :
          '风险提示：你接续时，本设备会把这台主机保存的密码或私钥经系统分布式通道加密发送给同账号的目标设备，只用于那一次连接、不写入目标设备，最长保留 2 分钟。若同账号的其他设备丢失或被他人使用，对方可能借接续获得这台主机的访问凭据。请只在自己信任的设备间开启；私钥口令未保存时仍需在目标设备输入。')
          .fontSize(12).fontColor(this.continuation.credentialMode === 'manual' ? this.pal().text3 : '#B26A00')
          .fontFamily(AppConfig.fontFamily).lineHeight(18).width('100%')
      }.width('100%').padding(16)
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
  }
  build() {
    Column({ space: 14 }) {
      if (this.feature(this.revision) !== undefined) {
        Row() {
          Text(this.feature(this.revision)?.title ?? '').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          ProBadge()
        }.width('100%')
        Column({ space: 6 }) {
          Row() {
            Text('状态').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).layoutWeight(1)
            Text(this.status(this.revision)?.label ?? '').fontSize(14)
              .fontColor(this.toneColor(this.status(this.revision))).fontFamily(AppConfig.fontFamily)
          }.width('100%')
          Text(this.status(this.revision)?.detail ?? '').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
          Text('适用：' + proFeatureScope(this.feature(this.revision) as ProFeature)).fontSize(12).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
          Text(this.feature(this.revision)?.description ?? '').fontSize(13).fontColor(this.pal().text2)
            .fontFamily(AppConfig.fontFamily).lineHeight(19).width('100%').margin({ top: 4 })
        }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
        Column() {
          this.switchRow('显示入口', '只控制应用中是否显示此功能入口，不改变购买或权益',
            ProFeatureVisibility.getInstance().isVisible(this.featureId), (on: boolean): void => {
              if (this.contextValue !== null) { ProFeatureVisibility.getInstance().setVisible(this.contextValue, this.featureId, on); }
            })
        }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
        if (this.featureId === PRO_CONTINUATION_FEATURE) { this.continuationOptions() }
      } else {
        Text('此功能已不在目录中').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
  }
}
