import { display, promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import {
  MoonlightCodecPreference,
  MoonlightInputControlMode,
  MoonlightResolutionMode,
  MoonlightSettings,
  defaultMoonlightSettings,
  moonlightInputControlMode
} from '../model/MoonlightModels';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../services/AccountScopePolicy';
import { CloudStore } from '../services/CloudStore';
import {
  MoonlightDeletionCommandResult,
  MoonlightDeletionPreview,
  MoonlightDeletionSelectionSnapshot
} from '../services/MoonlightDeletionCommandService';
import {
  MoonlightDeletionCommandType
} from '../services/MoonlightDeletionPolicy';
import {
  MoonlightDeletionRuntime
} from '../services/MoonlightDeletionRuntime';
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
import {
  MoonlightHardwareDecoderCapabilities,
  MoonlightHardwareDecoderCapability,
  moonlightDecoderCapability,
  probeMoonlightHardwareDecoderCapabilities
} from '../services/MoonlightVideoCapabilityService';
import { MoonlightNativeLaunchConfiguration } from '../services/MoonlightHostService';
import { moonlightLaunchConfiguration } from '../services/MoonlightRuntimeContextFactory';
import { resolveMoonlightProductSettings } from '../services/MoonlightSettingsPolicy';

interface MoonlightResolutionRequestPixels {
  width: number;
  height: number;
}

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
  @Prop requestedSection: MoonlightSettingsSection = 'video';
  @Prop requestedHostId: string = '';
  @State hostId: string = '';
  @State section: MoonlightSettingsSection = 'video';
  @State settings: MoonlightSettings = defaultMoonlightSettings();
  @State dirty: boolean = false;
  @State saveCode: string = '';
  @State dataBusy: boolean = false;
  @State dataStatusCode: string = '';
  @State dataSyncSelected: boolean = false;
  @State dataCloudSchemaReady: boolean = false;
  @State dataLocalRows: number = 0;
  @State dataCacheRows: number = 0;
  @State dataRuntimeStates: number = 0;
  @State dataSecureIdentities: number = 0;
  @State decoderCapabilityRevision: number = 0;
  @State videoCodecDraft: MoonlightCodecPreference = 'auto';
  @State videoResolutionDraft: string = 'host';
  @State videoFpsDraft: number = 60;
  @State videoBitrateDraft: number = 20000;
  @State videoWidthDraft: number = 1920;
  @State videoHeightDraft: number = 1080;
  @State reconnectBudgetSecondsDraft: number = 15.5;
  @State inputControlModeDraft: MoonlightInputControlMode = 'adaptive';
  private decoderCapabilities: MoonlightHardwareDecoderCapabilities =
    probeMoonlightHardwareDecoderCapabilities();
  private readonly service: MoonlightSettingsLocalService =
    new MoonlightSettingsLocalService(CloudStore.getInstance());
  private readonly deletionRuntime: MoonlightDeletionRuntime =
    MoonlightDeletionRuntime.getInstance();
  private savedSettingsCanonical: string = '';
  private editingLease: AccountSessionLease | null = null;
  private surfaceActive: boolean = false;
  onClose: () => void = (): void => {};
  onDirtyChanged: (dirty: boolean) => void = (_dirty: boolean): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private topSafeHeight(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  aboutToAppear(): void {
    this.surfaceActive = true;
    if (this.embedded) {
      this.hostId = this.requestedHostId.trim();
      this.section = moonlightSettingsSections().indexOf(this.requestedSection) >= 0 ?
        this.requestedSection : 'video';
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
    this.refreshDecoderCapabilities();
    this.refreshDataStatus();
  }

  aboutToDisappear(): void { this.surfaceActive = false; }

  private loadCurrentSettings(): void {
    const store: CloudStore = CloudStore.getInstance();
    const before: AccountSessionLease | null = store.currentAccountLease();
    const loaded: MoonlightLocalSettingsResult = this.service.load();
    const after: AccountSessionLease | null = store.currentAccountLease();
    if (before === null || after === null ||
        !accountSessionLeaseEquals(before, after) || !store.isLeaseCurrent(after)) {
      this.editingLease = null;
      this.settings = defaultMoonlightSettings();
      this.syncVideoSliderDrafts(this.settings);
      this.syncInputControlModeDraft(this.settings);
      this.savedSettingsCanonical = JSON.stringify(this.settings);
      this.saveCode = 'account_changed';
      this.dirty = false;
      this.onDirtyChanged(false);
      return;
    }
    this.editingLease = cloneAccountSessionLease(after);
    this.settings = loaded.settings;
    this.syncVideoSliderDrafts(loaded.settings);
    this.syncInputControlModeDraft(loaded.settings);
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
    this.syncVideoSliderDrafts(next);
    this.syncInputControlModeDraft(next);
    this.dirty = JSON.stringify(next) !== this.savedSettingsCanonical;
    this.onDirtyChanged(this.dirty);
    this.saveCode = '';
  }

  private syncVideoSliderDrafts(settings: MoonlightSettings): void {
    this.videoCodecDraft = settings.video.codecPreference;
    this.videoResolutionDraft = settings.video.adaptiveResolution === 'host' ? 'host' :
      settings.video.adaptiveResolution === 'device' ? 'device' : settings.video.resolutionMode;
    this.videoFpsDraft = settings.video.fps;
    this.videoBitrateDraft = settings.video.bitrateKbps;
    this.videoWidthDraft = settings.video.customWidth;
    this.videoHeightDraft = settings.video.customHeight;
    this.reconnectBudgetSecondsDraft = settings.network.reconnectBudgetMs / 1000;
  }

  private syncInputControlModeDraft(settings: MoonlightSettings): void {
    this.inputControlModeDraft = moonlightInputControlMode(
      settings.input.controlMode, settings.input.touchMode);
  }

  private selectInputControlMode(value: MoonlightInputControlMode): void {
    this.inputControlModeDraft = value;
    this.update((next: MoonlightSettings): void => {
      next.input.controlMode = value;
      // New product modes use the relative-pointer lane. Keep the old
      // low-level field bounded for older clients and cloud records.
      next.input.touchMode = 'absoluteMouse';
    });
  }

  private setVideoFps(value: number): void {
    const fps: number = Math.max(30, Math.min(this.maximumVideoFps(), Math.round(value)));
    this.videoFpsDraft = fps;
    this.update((next: MoonlightSettings): void => { next.video.fps = fps; });
  }

  private setVideoBitrate(value: number): void {
    const bitrate: number = Math.max(1000, Math.min(200000, Math.round(value / 1000) * 1000));
    this.videoBitrateDraft = bitrate;
    this.update((next: MoonlightSettings): void => { next.video.bitrateKbps = bitrate; });
  }

  private setVideoWidth(value: number): void {
    const width: number = Math.max(320, Math.min(7680, Math.round(value / 2) * 2));
    this.videoWidthDraft = width;
    this.update((next: MoonlightSettings): void => { next.video.customWidth = width; });
  }

  private setVideoHeight(value: number): void {
    const height: number = Math.max(240, Math.min(4320, Math.round(value / 2) * 2));
    this.videoHeightDraft = height;
    this.update((next: MoonlightSettings): void => { next.video.customHeight = height; });
  }

  private setReconnectBudgetSeconds(value: number): void {
    const seconds: number = Math.max(0, Math.min(120, Math.round(value * 2) / 2));
    this.reconnectBudgetSecondsDraft = seconds;
    this.update((next: MoonlightSettings): void => {
      next.network.reconnectBudgetMs = Math.round(seconds * 1000);
    });
  }

  private refreshDecoderCapabilities(): void {
    this.decoderCapabilities = probeMoonlightHardwareDecoderCapabilities(true);
    this.decoderCapabilityRevision++;
  }

  private selectedDecoderCapability(): MoonlightHardwareDecoderCapability {
    // Reading the revision makes an in-place native capability refresh visible
    // to the reactive builder even though the detailed snapshot stays private.
    const revision: number = this.decoderCapabilityRevision;
    if (revision < 0) { return this.decoderCapabilities.h264; }
    return moonlightDecoderCapability(this.decoderCapabilities,
      this.videoCodecDraft);
  }

  private selectVideoCodec(value: MoonlightCodecPreference): void {
    this.videoCodecDraft = value;
    const maximumFps: number = this.maximumVideoFpsFor(value);
    this.update((next: MoonlightSettings): void => {
      next.video.codecPreference = value;
      next.video.fps = Math.min(next.video.fps, maximumFps);
    });
  }

  private adaptiveResolution(): string {
    if (this.settings.video.adaptiveResolution !== undefined) {
      return this.settings.video.adaptiveResolution;
    }
    return this.settings.video.resolutionMode === 'host' ? 'host' : 'off';
  }

  private selectResolution(value: string): void {
    this.videoResolutionDraft = value;
    this.update((next: MoonlightSettings): void => {
      if (value === 'host') {
        next.video.resolutionMode = 'host';
        next.video.adaptiveResolution = 'host';
        const capability: MoonlightHardwareDecoderCapability =
          moonlightDecoderCapability(this.decoderCapabilities, next.video.codecPreference);
        if (capability.maxWidth >= 3840 && capability.maxHeight >= 2160) {
          next.video.customWidth = 3840; next.video.customHeight = 2160;
        } else if (capability.maxWidth >= 2560 && capability.maxHeight >= 1440) {
          next.video.customWidth = 2560; next.video.customHeight = 1440;
        } else if (capability.maxWidth >= 1920 && capability.maxHeight >= 1080) {
          next.video.customWidth = 1920; next.video.customHeight = 1080;
        } else {
          next.video.customWidth = 1280; next.video.customHeight = 720;
        }
        return;
      }
      if (value === 'device') {
        next.video.resolutionMode = 'custom';
        next.video.adaptiveResolution = 'device';
        try {
          const current: display.Display = display.getDefaultDisplaySync();
          next.video.customWidth = Math.floor(Math.max(current.width, current.height) / 2) * 2;
          next.video.customHeight = Math.floor(Math.min(current.width, current.height) / 2) * 2;
        } catch (_error) {
          next.video.customWidth = 1920;
          next.video.customHeight = 1080;
        }
        return;
      }
      next.video.adaptiveResolution = 'off';
      next.video.resolutionMode = value as MoonlightResolutionMode;
    });
  }

  private resolutionChoice(): string {
    const adaptive: string = this.adaptiveResolution();
    if (adaptive === 'host' || adaptive === 'device') { return adaptive; }
    return this.settings.video.resolutionMode;
  }

  private resolutionAvailable(width: number, height: number): boolean {
    const capability: MoonlightHardwareDecoderCapability = this.selectedDecoderCapability();
    if (!capability.available) { return false; }
    return (capability.maxWidth <= 0 || width <= capability.maxWidth) &&
      (capability.maxHeight <= 0 || height <= capability.maxHeight);
  }

  private maximumVideoFps(): number {
    const maximum: number = this.selectedDecoderCapability().maxFps;
    return Math.max(30, Math.min(240, maximum >= 30 ? maximum : 60));
  }

  private maximumVideoFpsFor(codec: MoonlightCodecPreference): number {
    const maximum: number = moonlightDecoderCapability(this.decoderCapabilities, codec).maxFps;
    return Math.max(30, Math.min(240, maximum >= 30 ? maximum : 60));
  }

  private decoderCapabilityDetail(): string {
    const capability: MoonlightHardwareDecoderCapability = this.selectedDecoderCapability();
    if (!capability.available) { return '当前选择没有可用的硬件解码器'; }
    const size: string = capability.maxWidth > 0 && capability.maxHeight > 0 ?
      capability.maxWidth.toString() + '×' + capability.maxHeight.toString() : '分辨率由系统决定';
    const fps: string = capability.maxFps > 0 ? capability.maxFps.toString() + ' FPS' : '帧率由系统决定';
    const implementation: string = capability.name.trim() === '' ? '鸿蒙硬件解码器' : capability.name;
    return implementation + ' · ' + size + ' · ' + fps +
      (capability.lowLatency ? ' · 硬件低延迟' : '');
  }

  private selectedDecoderLabel(): string {
    if (this.videoCodecDraft === 'hevc') { return 'H.265 / HEVC'; }
    if (this.videoCodecDraft === 'av1') { return 'AV1'; }
    if (this.videoCodecDraft === 'h264') { return 'H.264'; }
    return '自动 / H.264';
  }

  private save(): void {
    const editingLease: AccountSessionLease | null = this.editingLease;
    if (editingLease === null) {
      this.loadCurrentSettings();
      promptAction.showToast({ message: '账号状态已变化，请重新确认设置后再保存', duration: 2400 });
      return;
    }
    let saved: MoonlightLocalSettingsResult;
    try {
      saved = this.service.save(this.settings, Date.now(), editingLease);
    } catch (_error) {
      this.saveCode = 'local_save_exception';
      promptAction.showToast({ message: 'Moonlight 本地设置保存失败，请稍后重试', duration: 2200 });
      return;
    }
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

  private refreshDataStatus(): void {
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = this.deletionRuntime.currentLease();
    this.dataCloudSchemaReady = store.moonlightCloudSchemaReady();
    if (lease === null || !this.deletionRuntime.isLeaseCurrent(lease)) {
      this.dataStatusCode = 'account_changed';
      this.dataSyncSelected = false;
      this.dataLocalRows = 0;
      this.dataCacheRows = 0;
      this.dataRuntimeStates = 0;
      this.dataSecureIdentities = 0;
      return;
    }
    const selection: MoonlightDeletionSelectionSnapshot | null =
      store.selectionSnapshot(lease);
    this.dataSyncSelected = selection !== null &&
      selection.physicalSelected;
    const preview: MoonlightDeletionPreview = this.deletionRuntime.preview(
      lease, 'delete_local_data');
    this.dataStatusCode = preview.code === 'ok' || preview.code === 'unchanged' ?
      '' : preview.code;
    if (this.dataStatusCode === '') {
      this.dataLocalRows = preview.impact.localRowsRemoved;
      this.dataCacheRows = preview.impact.cacheRowsRemoved;
      this.dataRuntimeStates = preview.impact.localRuntimeStatesRemoved;
      this.dataSecureIdentities = preview.impact.secureIdentitiesRemoved;
    } else {
      this.dataLocalRows = 0;
      this.dataCacheRows = 0;
      this.dataRuntimeStates = 0;
      this.dataSecureIdentities = 0;
    }
  }

  private dataCommandTitle(command: MoonlightDeletionCommandType): string {
    if (command === 'cancel_sync') { return '停止此设备的 Moonlight 云同步？'; }
    if (command === 'delete_cloud_data') { return '删除 Moonlight 云端数据？'; }
    return '删除此设备的 Moonlight 本地数据？';
  }

  private dataCommandMessage(command: MoonlightDeletionCommandType,
    preview: MoonlightDeletionPreview): string {
    if (command === 'cancel_sync') {
      return '只停止此设备未来对 Moonlight 云表的上传、下载。' +
        '本机与云端现有数据都不会删除，其他协议的云同步不受影响。';
    }
    if (command === 'delete_cloud_data') {
      return '将先下载并核对当前账号的 Moonlight 云端投影，再为可跨设备的设置、主机与配置写入删除标记。' +
        '本机数据、配对信任、证书和客户端私钥全部保留；删除完成后会自动停止 Moonlight 同步。';
    }
    const stopSync: string = preview.impact.selectionChanged ?
      '为防止云端副本立即回灌，将先停止此设备的 Moonlight 云同步。' : '';
    return stopSync + '将删除当前账号在此设备上的 ' +
      preview.impact.localRowsRemoved.toString() + ' 条记录、' +
      preview.impact.cacheRowsRemoved.toString() + ' 条目录缓存和 ' +
      preview.impact.localRuntimeStatesRemoved.toString() + ' 条恢复状态，并清理本机安全身份。' +
      '云端公开数据会保留；再次启用同步前请确认希望从云端恢复还是重新建立本机数据。';
  }

  private requestDataCommand(command: MoonlightDeletionCommandType): void {
    if (this.dataBusy) { return; }
    if (this.dirty) {
      promptAction.showToast({ message: '请先保存或放弃当前设置草稿，再管理数据', duration: 2400 });
      return;
    }
    const lease: AccountSessionLease | null = this.deletionRuntime.currentLease();
    if (lease === null || !this.deletionRuntime.isLeaseCurrent(lease)) {
      this.refreshDataStatus();
      promptAction.showToast({ message: '当前账号数据域已变化，请重试', duration: 2200 });
      return;
    }
    const preview: MoonlightDeletionPreview =
      this.deletionRuntime.preview(lease, command);
    if (preview.code === 'unchanged') {
      promptAction.showToast({
        message: command === 'cancel_sync' ? '此设备尚未启用 Moonlight 云同步' : '没有可删除的数据',
        duration: 1800
      });
      this.refreshDataStatus();
      return;
    }
    if (preview.code !== 'ok') {
      promptAction.showToast({
        message: preview.code === 'cloud_unavailable' ?
          'Moonlight 云表尚未就绪，不能安全执行云端删除' :
          '无法生成安全的数据影响预览：' + preview.code,
        duration: 2600
      });
      this.refreshDataStatus();
      return;
    }
    promptAction.showDialog({
      title: this.dataCommandTitle(command),
      message: this.dataCommandMessage(command, preview),
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: command === 'cancel_sync' ? '停止同步' : '确认删除',
          color: command === 'cancel_sync' ? this.accentColor : this.pal().danger }
      ]
    }).then((value: Object): void => {
      const selected: Record<string, number> = value as Record<string, number>;
      if (selected['index'] === 1) {
        void this.executeDataCommand(lease, preview);
      }
    });
  }

  private async executeDataCommand(lease: AccountSessionLease,
    preview: MoonlightDeletionPreview): Promise<void> {
    if (this.dataBusy || !this.surfaceActive) { return; }
    this.dataBusy = true;
    let result: MoonlightDeletionCommandResult;
    try {
      result = await this.deletionRuntime.execute(lease, preview);
    } catch (_error) {
      if (this.surfaceActive) {
        this.refreshDataStatus();
        promptAction.showToast({
          message: 'Moonlight 数据操作异常中止，未确认的数据保持不变',
          duration: 3000
        });
      }
      return;
    } finally {
      this.dataBusy = false;
    }
    if (!this.surfaceActive) { return; }
    if (preview.command === 'delete_local_data' && result.localCommitted) {
      // Never retain a stale in-memory settings draft after its backing row
      // has been removed. A secure-identity retry still starts from defaults.
      this.loadCurrentSettings();
    }
    this.refreshDataStatus();
    if (!result.ok) {
      let message: string = '操作失败，未确认的数据保持不变：' + result.code;
      if (result.code === 'stale_preview') {
        message = '数据在确认期间发生变化，已停止操作，请重新确认';
      } else if (result.code === 'selection_failed') {
        message = '未能完整停止 Moonlight 同步，因此没有删除本地数据';
      } else if (result.code === 'identity_delete_failed' &&
          result.localCommitted) {
        message = '本地记录已删除，但安全身份清理未完成；请再次执行“删除本地数据”重试';
      } else if (result.code === 'cloud_unavailable') {
        message = '云端状态无法核对，未执行不确定的删除';
      }
      promptAction.showToast({ message, duration: 3000 });
      return;
    }
    let message: string = 'Moonlight 数据操作已完成';
    if (preview.command === 'cancel_sync') {
      message = '已停止此设备的 Moonlight 云同步，现有数据均保留';
    } else if (preview.command === 'delete_cloud_data') {
      message = result.code === 'pending_cloud' ?
        '云端删除标记正在上传；本机数据保留，完成前不会重新启用同步' :
        'Moonlight 云端数据已删除，本机数据保留';
    } else {
      message = '此设备的 Moonlight 本地数据和安全身份已删除；云端副本保留';
    }
    promptAction.showToast({ message, duration: 2800 });
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
    if (this.embedded) {
      Row() {
        MoonlightBrandIcon({ iconSize: 24, tint: this.accentColor })
        Column() {
          Text(moonlightSettingsSectionLabel(this.section)).fontSize(19)
            .fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppTheme.fontFamily)
          Text(this.section === 'data' ? 'Moonlight · 当前账号数据域' :
            '修改立即预览，保存后用于下一次连接').fontSize(11)
            .fontColor(this.pal().text3).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
        if (this.dirty) {
          Text('未保存').fontSize(10).fontColor(this.pal().editColor)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.pal().editColor + '16').borderRadius(10).margin({ right: 8 })
        } else if (this.dataBusy) {
          Text('处理中').fontSize(11).fontColor(this.accentColor).margin({ right: 8 })
        }
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }.width(36).height(36).padding(0).borderRadius(18).backgroundColor(this.pal().surface)
          .onClick((): void => { this.close(); }).accessibilityText('关闭 Moonlight 设置')
      }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 })
    } else {
      Row() {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([this.pal().text]) }
          .width(42).height(42).padding(0).borderRadius(21).backgroundColor(this.pal().surface)
          .onClick((): void => { this.close(); }).accessibilityText('返回')
        MoonlightBrandIcon({ iconSize: 30, tint: this.accentColor }).margin({ left: 12 })
        Column() {
          Text('Moonlight 设置').fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text('当前账号全局默认 · 安全身份始终仅限本机').fontSize(10)
            .fontColor(this.pal().text3).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        if (this.dirty) {
          Text('未保存').fontSize(10).fontColor(this.pal().editColor)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.pal().editColor + '16').borderRadius(10).margin({ right: 8 })
        }
        if (this.section !== 'data') {
          Button('保存').height(40).fontSize(13).borderRadius(12)
            .backgroundColor(this.dirty && this.editingLease !== null ? this.accentColor : this.pal().surface)
            .fontColor(this.dirty && this.editingLease !== null ? Color.White : this.pal().text3)
            .enabled(this.dirty && this.editingLease !== null)
            .onClick((): void => { this.save(); })
        } else if (this.dataBusy) {
          Text('处理中').fontSize(11).fontColor(this.accentColor)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.accentColor + '14').borderRadius(10)
        }
      }.width('100%').padding({
        left: 18, right: 18, top: this.topSafeHeight() + 8, bottom: 10
      })
    }
  }

  @Builder private categoryButton(section: MoonlightSettingsSection) {
    Button() {
      Row() {
        Text(moonlightSettingsSectionLabel(section)).fontSize(13)
          .fontWeight(this.section === section ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.section === section ? this.accentColor : this.pal().text2)
          .layoutWeight(1).textAlign(TextAlign.Start)
      }.width('100%')
    }.width(this.embedded && this.breakpoint !== 'sm' ? '100%' :
      (this.breakpoint === 'xl' ? '100%' : 118)).height(42).borderRadius(12)
      .backgroundColor(this.section === section ? this.accentColor + '16' : this.pal().surface)
      .onClick((): void => {
        this.section = section;
        if (section === 'data') { this.refreshDataStatus(); }
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

  private resolutionPreview(): string {
    const request: MoonlightResolutionRequestPixels = this.effectiveResolutionRequest();
    if (this.adaptiveResolution() === 'device') {
      return '本机 ' + request.width.toString() + '×' + request.height.toString();
    }
    if (this.adaptiveResolution() === 'host') {
      return '远端上限 ' + request.width.toString() + '×' + request.height.toString();
    }
    if (this.settings.video.resolutionMode === '720p') { return '720p'; }
    if (this.settings.video.resolutionMode === '1080p') { return '1080p'; }
    if (this.settings.video.resolutionMode === '1440p') { return '1440p'; }
    if (this.settings.video.resolutionMode === '2160p') { return '4K'; }
    if (this.settings.video.resolutionMode === 'custom') { return '自定义'; }
    return '跟随主机';
  }

  private effectiveResolutionRequest(): MoonlightResolutionRequestPixels {
    const effective: MoonlightSettings = resolveMoonlightProductSettings(
      this.settings, this.decoderCapabilities).effective;
    const decoder: MoonlightHardwareDecoderCapability = moonlightDecoderCapability(
      this.decoderCapabilities, effective.video.codecPreference);
    let deviceWidth: number = 0;
    let deviceHeight: number = 0;
    try {
      const current: display.Display = display.getDefaultDisplaySync();
      deviceWidth = current.width;
      deviceHeight = current.height;
    } catch (_error) {}
    const request: MoonlightNativeLaunchConfiguration =
      moonlightLaunchConfiguration(effective, deviceWidth, deviceHeight,
        decoder.maxWidth, decoder.maxHeight);
    return {
      width: request.width ?? 1920,
      height: request.height ?? 1080
    };
  }

  private resolutionRequestPixels(): string {
    const request: MoonlightResolutionRequestPixels = this.effectiveResolutionRequest();
    return request.width.toString() + ' × ' + request.height.toString();
  }

  private resolutionRequestDetail(): string {
    if (this.adaptiveResolution() === 'device') {
      return '按当前鸿蒙设备横屏像素与宽高比请求，受当前硬件解码器上限约束';
    }
    if (this.adaptiveResolution() === 'host') {
      return '按远端编码能力请求最高标准画质，连接时还会按 Sunshine 返回的上限收敛';
    }
    return '固定请求尺寸；更改会立即反映在预览中，保存后用于下一次连接';
  }

  private inputPreview(): string {
    const mode: MoonlightInputControlMode = this.inputControlModeDraft;
    if (mode === 'keyboardMouse') { return '键鼠'; }
    if (mode === 'trackpad') { return '虚拟触控板'; }
    return '自适应';
  }

  private inputKeyboardPreview(): string {
    const mode: MoonlightInputControlMode = this.inputControlModeDraft;
    if (mode === 'adaptive') { return '键盘自动'; }
    if (mode === 'keyboardMouse') { return '键盘直通'; }
    return this.settings.input.captureKeyboard ? '键盘开' : '键盘关';
  }

  private networkPreview(): string {
    const reconnect: string = this.settings.network.autoReconnect ? '自动重连' : '不重连';
    let encryption: string = '自动加密';
    if (this.settings.network.streamEncryption === 'compatible') { encryption = '兼容加密'; }
    else if (this.settings.network.streamEncryption === 'required') { encryption = '强制加密'; }
    return reconnect + ' · ' + encryption;
  }

  @Builder private previewItem(title: string, value: string) {
    Column() {
      Text(title).fontSize(10).fontColor(this.pal().text3)
      Text(value).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 3 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      .padding({ left: 10, right: 10, top: 9, bottom: 9 })
      .backgroundColor(this.pal().card).borderRadius(11)
  }

  @Builder private liveSettingsPreview() {
    Column({ space: 8 }) {
      Row() {
        Text('当前连接预览').fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .layoutWeight(1)
        Text(this.dirty ? '有未保存更改' : '已保存').fontSize(10)
          .fontColor(this.dirty ? this.pal().editColor : this.pal().success)
      }.width('100%')
      Row({ space: 8 }) {
        this.previewItem('画面', this.resolutionPreview() + ' · ' +
          this.settings.video.fps.toString() + ' FPS · ' +
          this.settings.video.bitrateKbps.toString() + ' Kbps')
        this.previewItem('控制', this.inputPreview() + ' · ' + this.inputKeyboardPreview())
      }.width('100%')
      Row({ space: 8 }) {
        this.previewItem('网络', this.networkPreview())
        this.previewItem('会话', (this.settings.audio.enabled ? '音频开' : '音频关') +
          (this.settings.diagnostics.showPerformanceHud ? ' · 性能开' : ' · 性能关'))
      }.width('100%')
    }.width('100%').padding(12).backgroundColor(this.pal().surface)
      .border({ width: 0.5, color: this.pal().cardBorder }).borderRadius(16)
      .margin({ bottom: 12 })
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

  @Builder private videoFpsSlider() {
    Column() {
      Row() {
        Column() {
          Text('帧率').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('30–' + this.maximumVideoFps().toString() + ' FPS，逐帧连续调节')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.videoFpsDraft.toString() + ' FPS').fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.videoFpsDraft,
        min: 30, max: this.maximumVideoFps(), step: 1 })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .showTips(true).showSteps(false)
        .onChange((next: number, _mode: SliderChangeMode): void => { this.setVideoFps(next); })
        .margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private videoBitrateSlider() {
    Column() {
      Row() {
        Column() {
          Text('码率').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('拖动时实时预览；点击保存后才写入本地')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.videoBitrateDraft.toString() + ' Kbps').fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.videoBitrateDraft,
        min: 1000, max: 200000, step: 1000 })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .showTips(true).showSteps(false)
        .onChange((next: number, _mode: SliderChangeMode): void => { this.setVideoBitrate(next); })
        .margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private videoWidthSlider() {
    Column() {
      Row() {
        Column() {
          Text('自定义宽度').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('320–7680，native 会按解码器上限和偶数对齐校验')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.videoWidthDraft.toString() + ' px').fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.videoWidthDraft,
        min: 320, max: 7680, step: 2 })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .showTips(true).showSteps(false)
        .onChange((next: number, _mode: SliderChangeMode): void => { this.setVideoWidth(next); })
        .margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private videoHeightSlider() {
    Column() {
      Row() {
        Column() {
          Text('自定义高度').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('240–4320，保持与远端显示模式一致可避免拉伸')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.videoHeightDraft.toString() + ' px').fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.videoHeightDraft,
        min: 240, max: 4320, step: 2 })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .showTips(true).showSteps(false)
        .onChange((next: number, _mode: SliderChangeMode): void => { this.setVideoHeight(next); })
        .margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private reconnectBudgetSlider() {
    Column() {
      Row() {
        Column() {
          Text('重连预算').fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.settings.network.autoReconnect ? this.pal().text : this.pal().text3)
          Text('最多尝试 6 次；0 秒等同于不自动重连')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text((Number.isInteger(this.reconnectBudgetSecondsDraft) ?
          this.reconnectBudgetSecondsDraft.toString() :
          this.reconnectBudgetSecondsDraft.toFixed(1)) + ' 秒')
          .fontSize(12).fontColor(this.pal().text2)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.reconnectBudgetSecondsDraft,
        min: 0, max: 120, step: 0.5 })
        .width('100%').selectedColor(this.accentColor).trackColor(this.pal().surface)
        .showTips(true).showSteps(false).enabled(this.settings.network.autoReconnect)
        .onChange((next: number, _mode: SliderChangeMode): void => {
          this.setReconnectBudgetSeconds(next);
        }).margin({ top: 7 })
    }.width('100%').padding({ top: 7, bottom: 7 })
      .opacity(this.settings.network.autoReconnect ? 1 : 0.55)
  }

  @Builder private statusRow(title: string, detail: string, value: string,
    available: boolean = true) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(detail).fontSize(10).fontColor(this.pal().text3).lineHeight(15).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(value).fontSize(11).fontWeight(FontWeight.Medium)
        .fontColor(available ? this.pal().text2 : this.pal().text3)
        .padding({ left: 9, right: 9, top: 5, bottom: 5 })
        .backgroundColor(this.pal().surface).borderRadius(10).margin({ left: 12 })
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End).constraintSize({ maxWidth: '40%' })
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

  @Builder private choiceButton(label: string, value: string, current: string,
    enabled: boolean, onChoose: (value: string) => void) {
    Button(label).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
      .backgroundColor(current === value ? this.accentColor : this.pal().surface)
      .fontColor(current === value ? Color.White : this.pal().text2)
      .enabled(enabled).opacity(enabled ? 1 : 0.45)
      .onClick((): void => { if (enabled) { onChoose(value); } })
  }

  @Builder private decoderChoiceButton(label: string, value: MoonlightCodecPreference,
    enabled: boolean) {
    Button(label).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
      .backgroundColor(this.videoCodecDraft === value ? this.accentColor : this.pal().surface)
      .fontColor(this.videoCodecDraft === value ? Color.White : this.pal().text2)
      .enabled(enabled).opacity(enabled ? 1 : 0.45)
      .onClick((): void => { if (enabled) { this.selectVideoCodec(value); } })
  }

  @Builder private resolutionChoiceButton(label: string, value: string,
    enabled: boolean = true) {
    Button(label).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
      .backgroundColor(this.videoResolutionDraft === value ? this.accentColor : this.pal().surface)
      .fontColor(this.videoResolutionDraft === value ? Color.White : this.pal().text2)
      .enabled(enabled).opacity(enabled ? 1 : 0.45)
      .onClick((): void => { if (enabled) { this.selectResolution(value); } })
  }

  @Builder private inputControlModeChoiceButton(label: string,
    value: MoonlightInputControlMode) {
    Button(label).height(36).layoutWeight(1).fontSize(11).borderRadius(10)
      .backgroundColor(this.inputControlModeDraft === value ? this.accentColor : this.pal().surface)
      .fontColor(this.inputControlModeDraft === value ? Color.White : this.pal().text2)
      .onClick((): void => { this.selectInputControlMode(value); })
  }

  @Builder private videoContent() {
    this.sectionHeader('画面', '预设、编码、分辨率、帧率与码率都在这里管理；重连要求会明确标出。')
    Column() {
      this.cardTitle('画面预设', '选择后立即更新上方预览，保存后用于下一次 Moonlight 连接')
      Row({ space: 8 }) {
        Button('省流').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps <= 20000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps <= 20000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = Math.min(60, this.maximumVideoFpsFor(next.video.codecPreference));
            next.video.bitrateKbps = 20000;
          }); })
        Button('平衡').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps > 20000 &&
            this.settings.video.bitrateKbps < 50000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps > 20000 &&
            this.settings.video.bitrateKbps < 50000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = Math.min(60, this.maximumVideoFpsFor(next.video.codecPreference));
            next.video.bitrateKbps = 30000;
          }); })
        Button('画质优先').layoutWeight(1).height(42).borderRadius(12).fontSize(12)
          .backgroundColor(this.settings.video.bitrateKbps >= 50000 ? this.accentColor : this.pal().surface)
          .fontColor(this.settings.video.bitrateKbps >= 50000 ? Color.White : this.pal().text2)
          .onClick((): void => { this.update((next: MoonlightSettings): void => {
            next.video.fps = Math.min(60, this.maximumVideoFpsFor(next.video.codecPreference));
            next.video.bitrateKbps = 50000;
          }); })
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('硬件解码器', '仅列出鸿蒙当前设备实际返回的硬件解码格式；自动模式优先兼容性。')
      Row({ space: 7 }) {
        this.decoderChoiceButton('自动', 'auto', true)
        this.decoderChoiceButton('H.264', 'h264', this.decoderCapabilities.h264.available)
      }.width('100%')
      Row({ space: 7 }) {
        this.decoderChoiceButton('H.265 / HEVC', 'hevc', this.decoderCapabilities.hevc.available)
        this.decoderChoiceButton('AV1', 'av1', this.decoderCapabilities.av1.available)
      }.width('100%').margin({ top: 7 })
      this.statusRow('当前解码映射', this.decoderCapabilityDetail(),
        this.selectedDecoderLabel(), this.selectedDecoderCapability().available)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('分辨率与帧率', '每项会实时进入上方连接预览；保存后用于下一次连接。')
      Text('自适应').fontSize(11).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row({ space: 7 }) {
        this.resolutionChoiceButton('适配远端', 'host')
        this.resolutionChoiceButton('适配当前设备', 'device')
      }.width('100%')
      this.statusRow('下一次串流请求', this.resolutionRequestDetail(),
        this.resolutionRequestPixels())
      Text('常用画质').fontSize(11).fontColor(this.pal().text3).margin({ top: 14, bottom: 7 })
      Row({ space: 7 }) {
        this.resolutionChoiceButton('720p', '720p', this.resolutionAvailable(1280, 720))
        this.resolutionChoiceButton('1080p', '1080p', this.resolutionAvailable(1920, 1080))
        this.resolutionChoiceButton('1440p', '1440p', this.resolutionAvailable(2560, 1440))
      }.width('100%')
      Row({ space: 7 }) {
        this.resolutionChoiceButton('4K', '2160p', this.resolutionAvailable(3840, 2160))
        this.resolutionChoiceButton('自定义', 'custom')
      }.width('100%').margin({ top: 7 })
      if (this.videoResolutionDraft === 'custom') {
        this.videoWidthSlider()
        this.videoHeightSlider()
      }
      this.videoFpsSlider()
      this.videoBitrateSlider()
      this.statusRow('HDR', '当前媒体管线尚未开放，避免保存后静默降级', '尚未开放', false)
      Divider().color(this.pal().divider)
      this.statusRow('YUV 4:4:4', '当前媒体管线尚未开放，保持 8-bit YUV420', '尚未开放', false)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('画面生命周期', '公共显示与画中画仍由应用级设置统一管理')
      this.statusRow('无可见 Surface',
        '丢弃视频帧并保留唯一连接；恢复画面后重新绑定 Surface 并等待新帧', '保活并丢帧')
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
      Divider().color(this.pal().divider)
      this.toggleRow('主机同时播放', '由 Sunshine 能力与主机设置共同决定', this.settings.audio.playOnHost,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.audio.playOnHost = value; }); })
      Divider().color(this.pal().divider)
      this.toggleRow('后台继续音频',
        '进入后台或画中画时保持主机音频；关闭后会暂停并在回前台恢复',
        this.settings.background.allowAudioInBackground,
        (value: boolean): void => {
          this.update((next: MoonlightSettings): void => {
            next.background.allowAudioInBackground = value;
          });
        })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private inputContent() {
    this.sectionHeader('控制与手柄', '键鼠、虚拟触控板和自适应输入统一进入会话控制通道。')
    Column() {
      this.cardTitle('控制模式', '保存后用于下一次连接；连接中也可以从侧栏控制中心临时切换')
      Row({ space: 7 }) {
        this.inputControlModeChoiceButton('自适应', 'adaptive')
        this.inputControlModeChoiceButton('键鼠', 'keyboardMouse')
        this.inputControlModeChoiceButton('虚拟触控板', 'trackpad')
      }.width('100%')
      this.statusRow('自适应规则',
        '手机默认虚拟触控板；Pad/PC 默认键鼠。触摸画面切换为虚拟触控板，实体键盘、鼠标或触控板活动切回键鼠。',
        '实时识别')
      Divider().color(this.pal().divider)
      this.toggleRow('捕获键盘',
        '虚拟触控板模式下手机按此开关；自适应、键鼠、Pad 与 PC 始终直通，退出时补发全部 key-up',
        this.settings.input.captureKeyboard,
        (value: boolean): void => { this.update((next: MoonlightSettings): void => { next.input.captureKeyboard = value; }); })
      Divider().color(this.pal().divider)
      this.statusRow('转发系统快捷键', '系统保留组合键尚未开放，普通按键仍可发送', '尚未开放', false)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('控制器', '实体和虚拟控制器由同一状态聚合器处理，避免重复或冲突输入')
      this.statusRow('控制器槽位', '实体与虚拟手柄统一进入会话控制器槽位', '槽位 1')
      this.statusRow('手柄震动', '当前未接入主机到手柄的反馈输出，保持不可用', '尚未开放', false)
      Row() {
        SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(17).fontColor([this.pal().editColor])
        Text('切换输入源、编辑配置、进入后台或退出时，都会先释放按键并将手柄复位。')
          .fontSize(10).fontColor(this.pal().text3).layoutWeight(1).lineHeight(15).margin({ left: 8 })
      }.width('100%').padding(10).backgroundColor(this.pal().surface).borderRadius(12).margin({ top: 8 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private networkContent() {
    this.sectionHeader('网络与安全', '局域网发现、计费网络、断线恢复、地址族与串流加密。')
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
      this.choice3('每次询问', '始终允许', '禁止串流', this.settings.network.meteredNetwork,
        'ask', 'allow', 'deny', (value: string): void => {
          this.update((next: MoonlightSettings): void => { next.network.meteredNetwork = value as 'ask'; });
        })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
    Column() {
      this.cardTitle('断线恢复', '只恢复当前 Moonlight 会话，不创建第二套网络连接管理')
      this.toggleRow('自动重连', '传输意外中断后，在限定时间内恢复当前应用与输入会话',
        this.settings.network.autoReconnect, (value: boolean): void => {
          this.update((next: MoonlightSettings): void => { next.network.autoReconnect = value; });
      })
      Divider().color(this.pal().divider)
      this.reconnectBudgetSlider()
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

  @Builder private diagnosticsContent() {
    this.sectionHeader('诊断', '只保留 Moonlight 会话指标与脱敏日志；默认关闭，避免无意义采样。')
    Column() {
      this.toggleRow('性能 HUD',
        '串流中每秒读取一次有界原生快照；关闭后立即停止采样',
        this.settings.diagnostics.showPerformanceHud,
        (value: boolean): void => {
          this.update((next: MoonlightSettings): void => {
            next.diagnostics.showPerformanceHud = value;
          });
        })
      Divider().color(this.pal().divider)
      this.statusRow('日志级别', '发布版只保留错误级别，不开放包含更多运行细节的调试日志', '错误')
      Divider().color(this.pal().divider).margin({ top: 12 })
      Row() {
        SymbolGlyph($r('sys.symbol.text_clipboard')).fontSize(19).fontColor([this.accentColor])
        Column() {
          Text('脱敏诊断导出').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('不包含地址、PIN、证书、身份材料或会话密钥').fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        Text('会话内可用').fontSize(10).fontColor(this.pal().success)
      }.width('100%').padding({ top: 12, bottom: 6 })
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

  @Builder private dataActionRow(icon: Resource, title: string,
    detail: string, label: string, dangerous: boolean,
    enabled: boolean, action: () => void) {
    Row() {
      Row() {
        SymbolGlyph(icon).fontSize(20)
          .fontColor([dangerous ? this.pal().danger : this.accentColor])
      }.width(42).height(42).borderRadius(13)
        .backgroundColor(dangerous ? this.pal().danger + '12' : this.accentColor + '12')
        .justifyContent(FlexAlign.Center)
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(enabled ? this.pal().text : this.pal().text3)
        Text(detail).fontSize(10).fontColor(this.pal().text3)
          .lineHeight(15).margin({ top: 3 }).maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 11, right: 10 })
      Button(label).height(36).fontSize(11).borderRadius(11)
        .backgroundColor(enabled ?
          (dangerous ? this.pal().danger : this.accentColor) : this.pal().surface)
        .fontColor(enabled ? Color.White : this.pal().text3)
        .enabled(enabled).onClick(action)
    }.width('100%').padding({ top: 10, bottom: 10 })
  }

  @Builder private dataContent() {
    this.sectionHeader('数据管理',
      '本机、云端与配对安全身份分别管理；每个删除动作都先计算影响范围并再次确认。')
    Column() {
      this.cardTitle('当前设备', '只描述 Moonlight，不改变其他协议的云同步选择')
      this.statusRow('Moonlight 云同步',
        '云表自动启用；设置、主机与配置固定整体同步',
        this.dataSyncSelected ? '此设备已选择' : '此设备未选择',
        this.dataSyncSelected)
      Divider().color(this.pal().divider)
      this.statusRow('云表运行状态',
        this.dataCloudSchemaReady ?
          '本机已通过可选云表注册与列合同检查' :
          '旧版 8 张云表继续独立工作；Moonlight 云操作保持关闭',
        this.dataCloudSchemaReady ? '已就绪' : '尚未就绪',
        this.dataCloudSchemaReady)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })

    Column() {
      this.cardTitle('此设备上的 Moonlight 数据',
        this.dataStatusCode === '' ? '影响数量来自当前账号的实时预览' :
          '当前无法生成完整预览：' + this.dataStatusCode)
      Row({ space: 8 }) {
        Column() {
          Text(this.dataLocalRows.toString()).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text('本地记录').fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.layoutWeight(1).height(66).justifyContent(FlexAlign.Center)
          .backgroundColor(this.pal().surface).borderRadius(14)
        Column() {
          Text(this.dataCacheRows.toString()).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text('目录缓存').fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.layoutWeight(1).height(66).justifyContent(FlexAlign.Center)
          .backgroundColor(this.pal().surface).borderRadius(14)
        Column() {
          Text((this.dataRuntimeStates + this.dataSecureIdentities).toString())
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('运行/安全状态').fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.layoutWeight(1).height(66).justifyContent(FlexAlign.Center)
          .backgroundColor(this.pal().surface).borderRadius(14)
      }.width('100%')
      Text('配对 trust、主机证书和客户端私钥永远不会作为 Moonlight 云数据上传。')
        .fontSize(10).fontColor(this.pal().text3).lineHeight(16)
        .width('100%').margin({ top: 10 })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })

    Column() {
      this.cardTitle('分别处理', '三个入口互不代替，也不会跳转到其他设置')
      this.dataActionRow($r('sys.symbol.link'), '停止 Moonlight 云同步',
        '保留本机和云端数据，仅停止此设备未来上传与下载', '停止', false,
        this.dataSyncSelected && !this.dataBusy,
        (): void => { this.requestDataCommand('cancel_sync'); })
      Divider().color(this.pal().divider)
      this.dataActionRow($r('sys.symbol.cloud_fill'), '删除 Moonlight 云端数据',
        '保留本机数据与安全身份；云端完成后自动停止同步',
        this.dataCloudSchemaReady ? '删除云端' : '未就绪', true,
        this.dataCloudSchemaReady && !this.dataBusy,
        (): void => { this.requestDataCommand('delete_cloud_data'); })
      Divider().color(this.pal().divider)
      this.dataActionRow($r('sys.symbol.ohos_trash'), '删除 Moonlight 本地数据',
        '先停止此设备同步，再删除本地记录、缓存、恢复状态与安全身份；云端副本保留',
        '删除本机', true, !this.dataBusy && this.dataStatusCode === '',
        (): void => { this.requestDataCommand('delete_local_data'); })
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 12 })
  }

  @Builder private activeContent() {
    if (this.section !== 'data') { this.liveSettingsPreview() }
    if (this.section === 'video') { this.videoContent() }
    else if (this.section === 'audio') { this.audioContent() }
    else if (this.section === 'input') { this.inputContent() }
    else if (this.section === 'networkSecurity') { this.networkContent() }
    else if (this.section === 'diagnostics') { this.diagnosticsContent() }
    else if (this.section === 'trust') { this.trustContent() }
    else { this.dataContent() }
  }

  @Builder private embeddedFooter() {
    if (this.section !== 'data') {
      Column() {
        Divider().color(this.pal().divider).margin({ bottom: 12 })
        Button(this.dirty ? '保存更改' : '设置已保存').width('100%').height(44)
          .fontSize(13).borderRadius(11)
          .backgroundColor(this.dirty && this.editingLease !== null ?
            this.accentColor : this.pal().surface)
          .fontColor(this.dirty && this.editingLease !== null ? Color.White : this.pal().text3)
          .enabled(this.dirty && this.editingLease !== null)
          .onClick((): void => { this.save(); })
      }.width('100%').padding({ left: 20, right: 20, bottom: 18 })
    }
  }

  build() {
    Column() {
      this.header()
      if (this.saveCode !== '' && this.saveCode !== 'default' && this.saveCode !== 'ok') {
        Text('本地设置状态：' + this.saveCode).fontSize(10).fontColor(this.pal().editColor)
          .width('100%').padding({ left: 22, right: 22, bottom: 6 })
      }
      if (this.embedded) {
        Scroll() {
          Column() { this.activeContent() }.width('100%').constraintSize({ maxWidth: 720 })
            .padding({ left: 20, right: 20, top: 4, bottom: 12 })
            .enabled(this.editingLease !== null).opacity(this.editingLease !== null ? 1 : 0.55)
        }.width('100%').height(0).layoutWeight(1)
          .align(Alignment.TopStart).scrollBar(BarState.Off)
        this.embeddedFooter()
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
