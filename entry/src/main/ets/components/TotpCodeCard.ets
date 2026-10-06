/**
 * TotpCodeCard.ets — TOTP 验证码卡片 (v4: 纯展示, 操作由 swipeAction 处理)
 */
import { TotpEntry, TotpCode } from '../model/TotpEntry';
import { TotpEngine } from '../services/TotpEngine';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { promptAction } from '@kit.ArkUI';
import { showLockGate, lockGateErrorMessage } from './LockGate';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import {
  TotpBrandVisual, totpBrandVisualForEntry, totpCustomAvatarUrl
} from '../services/TotpBrandService';
import { shouldRunTotpBrandTicker, TotpBrandTicker } from '../services/TotpBrandTicker';
import {
  TOTP_BRAND_CACHE,
  TotpBrandAssetLease,
  TotpDecodedAsset
} from '../services/TotpBrandCache';
import {
  configureTotpBrandResourceDecoder,
  decodeTotpBrandAsset,
  TOTP_BRAND_DECODE_MAX_BYTES
} from '../services/TotpBrandResourceDecoder';
import {
  TotpBrandAvatarState,
  TotpBrandAvatarToken,
  totpBrandAssetVisibility
} from '../services/TotpBrandAvatarState';
import { totpBrandAssetResource } from '../services/TotpBrandAssetRegistry';

@Component
export struct TotpCodeCard {
  @Prop @Watch('onEntryChanged') entry: TotpEntry;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('totpLogoMode') totpLogoMode: string = 'logo';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('remoteDesktopBgFlag') @Watch('onCardLifecycleChanged') appInBackground: boolean = false;
  @Prop @Watch('onCardLifecycleChanged') pageLocked: boolean = false;
  @Prop showCheckbox: boolean = false;
  @Prop checkboxSelected: boolean = false;
  onCheckChange?: (checked: boolean) => void;
  /** An entry locked on its own (it can arrive locked through sync): verified, then unlocked by the page. */
  onUnlock?: () => void;
  /** PC has no swipe: the ⋯ menu offers what the swipe actions do on a phone. */
  onRename?: () => void;
  onSelect?: () => void;
  onDelete?: () => void;
  @State menuVisible: boolean = false;
  @State codeStr: string = '------';
  @State remaining: number = 30;
  @State brandReady: boolean = false;
  @State brandFailed: boolean = false;
  @State brandResourceFailed: boolean = false;
  @State customAvatarFailed: boolean = false;
  @State customAvatarReady: boolean = false;
  @State brandPixelMap: image.PixelMap | null = null;
  private tickerUnsubscribe: (() => void) | null = null;
  private avatarState: TotpBrandAvatarState = new TotpBrandAvatarState();
  private avatarToken: TotpBrandAvatarToken | null = null;
  private brandLease: TotpBrandAssetLease | null = null;
  private avatarKey: string = '';
  private resourceDecoderConfigured: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    this.resetBrandState();
    this.updateTickerSubscription();
  }

  aboutToDisappear(): void {
    this.stopTicker();
    this.releaseBrandAsset();
    this.avatarState.invalidate();
    this.avatarToken = null;
    this.brandPixelMap = null;
  }

  private onEntryChanged(): void {
    this.resetBrandState();
    this.updateTickerSubscription();
  }

  private onCardLifecycleChanged(): void {
    if (!shouldRunTotpBrandTicker(this.pageLocked, this.entry.locked, this.appInBackground)) {
      // A background/locked page must not retain native PixelMaps or continue
      // a decode that could repopulate the cache after the clear.
      this.releaseBrandAsset();
      this.avatarState.invalidate();
      this.avatarToken = null;
      this.brandPixelMap = null;
      TOTP_BRAND_CACHE.clear();
    }
    this.updateTickerSubscription();
  }

  private stopTicker(): void {
    if (this.tickerUnsubscribe !== null) {
      this.tickerUnsubscribe();
      this.tickerUnsubscribe = null;
    }
  }

  private updateTickerSubscription(): void {
    if (!shouldRunTotpBrandTicker(this.pageLocked, this.entry.locked, this.appInBackground)) {
      this.stopTicker();
      this.releaseBrandAsset();
      this.avatarState.invalidate();
      this.avatarToken = null;
      this.brandPixelMap = null;
      TOTP_BRAND_CACHE.clear();
      return;
    }
    if (this.tickerUnsubscribe !== null) { return; }
    if (this.avatarToken === null) { this.resetBrandState(); }
    this.refresh();
    this.tickerUnsubscribe = TotpBrandTicker.sharedTicker().subscribe((): void => {
      if (shouldRunTotpBrandTicker(this.pageLocked, this.entry.locked, this.appInBackground)) {
        this.refresh();
      } else {
        this.stopTicker();
      }
    });
  }

  /**
   * The secret is empty while the master password is locked or after a
   * forgotten-password reset cleared it; an empty key must never be shown as
   * a code, because HMAC over an empty key still produces plausible digits.
   */
  private secretAvailable(): boolean {
    return this.entry.secret.length > 0;
  }

  private refresh(): void {
    if (!this.secretAvailable()) {
      this.codeStr = '';
      this.remaining = 0;
      return;
    }
    const tc: TotpCode = TotpEngine.generateCode(this.entry);
    this.codeStr = tc.code;
    this.remaining = tc.remaining;
  }

  /** A locked entry: verify, then let the page unlock it. */
  private async unlockEntry(): Promise<void> {
    if (this.pageLocked || !this.entry.locked || this.showCheckbox) { return; }
    const r = await showLockGate(this.primaryLabel(), 'biometric');
    if (!r.ok) {
      const message: string = lockGateErrorMessage(r);
      if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
      return;
    }
    if (this.onUnlock) { this.onUnlock(); }
  }

  @Builder totpMenuRow(icon: Resource, label: string, danger: boolean, action: () => void) {
    Row() {
      SymbolGlyph(icon).fontSize(16).fontColor([danger ? this.pal().danger : this.pal().text])
      Text(label).fontSize(13).fontColor(danger ? this.pal().danger : this.pal().text).margin({ left: 8 })
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .onClick(() => { this.menuVisible = false; action(); })
  }

  @Builder totpMenuBuilder() {
    Column() {
      this.totpMenuRow($r('sys.symbol.square_and_pencil'), '重命名', false,
        (): void => { if (this.onRename) { this.onRename(); } })
      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
      this.totpMenuRow($r('sys.symbol.list_bullet'), '多选', false,
        (): void => { if (this.onSelect) { this.onSelect(); } })
      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
      this.totpMenuRow($r('sys.symbol.ohos_trash'), '删除', true,
        (): void => { if (this.onDelete) { this.onDelete(); } })
    }.width('100%').padding({ top: 2, bottom: 2 }).borderRadius(12)
  }

  private copyCode(): void {
    if (this.pageLocked || this.entry.locked || !this.secretAvailable()) { return; }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.codeStr);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: `验证码 ${this.codeStr} 已复制`, duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  private avatarVisual(): TotpBrandVisual {
    return totpBrandVisualForEntry(this.entry, this.totpLogoMode === 'initials' ? 'initials' : 'logo');
  }

  private resetBrandState(): void {
    this.releaseBrandAsset();
    this.brandPixelMap = null;
    const visual: TotpBrandVisual = this.avatarVisual();
    this.avatarKey = this.brandKey(visual);
    this.brandReady = false;
    this.brandFailed = false;
    this.brandResourceFailed = false;
    this.customAvatarFailed = false;
    this.customAvatarReady = false;
    this.avatarToken = this.avatarState.begin(
      this.entry.id, visual.slug + ':' + visual.sha256);
    if (this.avatarToken !== null) {
      this.preloadDecodedBrandAsset(visual, this.avatarToken);
    }
  }

  private preloadDecodedBrandAsset(
    visual: TotpBrandVisual,
    token: TotpBrandAvatarToken
  ): void {
    if (this.customAvatarUrl() !== '' || visual.avatarMode !== 'local' || visual.localAsset.length === 0 ||
      !shouldRunTotpBrandTicker(this.pageLocked, this.entry.locked, this.appInBackground)) {
      return;
    }
    const cached: TotpBrandAssetLease | null = TOTP_BRAND_CACHE.acquire(
      visual.slug, visual.sha256);
    if (cached !== null) {
      if (cached.asset.pixelMap !== undefined) {
        this.brandLease = cached;
        this.brandPixelMap = cached.asset.pixelMap;
        return;
      }
      cached.release();
    }
    const cachedRecord = TOTP_BRAND_CACHE.get(visual.slug, visual.sha256);
    if (cachedRecord !== null && cachedRecord.state === 'failed') { return; }
    if (!this.resourceDecoderConfigured) {
      try {
        configureTotpBrandResourceDecoder(getContext(this) as common.UIAbilityContext);
        this.resourceDecoderConfigured = true;
      } catch (_error) {
        return;
      }
    }
    TOTP_BRAND_CACHE.acquireOrDecode(
      visual.slug,
      visual.sha256,
      TOTP_BRAND_DECODE_MAX_BYTES,
      (): Promise<TotpDecodedAsset | null> =>
        decodeTotpBrandAsset(visual.localAsset)
    ).then((lease): void => {
      // Budget pressure, lifecycle clear, and decoder failure all keep the
      // first-frame initials visible. They must not poison the cache as a
      // permanent decode failure.
      if (lease === null) { return; }
      const current = this.avatarState.snapshot();
      const tokenStillCurrent: boolean = current.entryKey === token.entryKey &&
        current.brandId === token.brandId && current.generation === token.generation &&
        this.avatarKey === this.brandKey(visual) &&
        shouldRunTotpBrandTicker(this.pageLocked, this.entry.locked, this.appInBackground);
      if (!tokenStillCurrent) {
        lease.release();
        return;
      }
      if (lease.asset.pixelMap === undefined) {
        lease.release();
        this.handleBrandDecodeError(visual, token);
        return;
      }
      this.brandLease = lease;
      this.brandPixelMap = lease.asset.pixelMap;
    }).catch((): void => {
      this.handleBrandDecodeError(visual, token);
    });
  }

  private handleBrandDecodeError(visual: TotpBrandVisual,
    token: TotpBrandAvatarToken): void {
    const current = this.avatarState.snapshot();
    if (current.entryKey !== token.entryKey || current.brandId !== token.brandId ||
      current.generation !== token.generation || this.avatarKey !== this.brandKey(visual)) {
      return;
    }
    if (this.avatarState.onError(token)) {
      this.releaseBrandAsset();
      this.brandPixelMap = null;
      this.brandReady = false;
      this.brandFailed = true;
      TOTP_BRAND_CACHE.markFailed(visual.slug, visual.sha256);
    }
  }

  private releaseBrandAsset(): void {
    if (this.brandLease !== null) {
      this.brandLease.release();
      this.brandLease = null;
    }
  }

  private brandKey(visual: TotpBrandVisual): string {
    return this.entry.id + '|' + this.entry.issuer + '|' + this.entry.account + '|' +
      this.entry.iconUrl + '|' +
      visual.slug + '|' + visual.sha256 + '|' + visual.localAsset + '|' +
      visual.avatarMode;
  }

  private customAvatarUrl(): string {
    return totpCustomAvatarUrl(this.entry.iconUrl);
  }

  private shouldRenderCustomAvatar(): boolean {
    return this.customAvatarUrl() !== '' && !this.customAvatarFailed;
  }

  private primaryLabel(): string {
    const customName: string = this.entry.displayName.trim();
    if (customName !== '') { return customName; }
    return this.entry.issuer || this.entry.account || '未命名';
  }

  private secondaryLabel(): string {
    if (this.entry.displayName.trim() === '') { return this.entry.account; }
    if (this.entry.issuer !== '' && this.entry.account !== '') {
      return this.entry.issuer + ' / ' + this.entry.account;
    }
    return this.entry.issuer || this.entry.account;
  }

  private localBrandFailed(visual: TotpBrandVisual): boolean {
    if (this.brandFailed) { return true; }
    const cached = TOTP_BRAND_CACHE.get(visual.slug, visual.sha256);
    return cached !== null && cached.state === 'failed';
  }

  private visualForBuild(): TotpBrandVisual {
    const visual: TotpBrandVisual = this.avatarVisual();
    if (this.avatarKey !== this.brandKey(visual)) {
      this.resetBrandState();
    }
    return visual;
  }

  private shouldRenderBrandAsset(visual: TotpBrandVisual): boolean {
    return !this.shouldRenderCustomAvatar() && visual.avatarMode === 'local' && this.brandPixelMap !== null &&
      (this.directBrandResource(visual) === null || this.brandResourceFailed) &&
      !this.localBrandFailed(visual);
  }

  private directBrandResource(visual: TotpBrandVisual): Resource | null {
    if (visual.avatarMode !== 'local' || visual.slug.length === 0) { return null; }
    return totpBrandAssetResource(visual.slug);
  }

  private shouldRenderDirectBrandResource(visual: TotpBrandVisual): boolean {
    return !this.shouldRenderCustomAvatar() && this.directBrandResource(visual) !== null && !this.brandResourceFailed;
  }

  private shouldShowInitials(visual: TotpBrandVisual): boolean {
    // A primary avatar owns the slot while it is loading.  Rendering initials
    // underneath it makes transparent/reloaded logos show two avatars during
    // a theme transition.
    if (this.shouldRenderDirectBrandResource(visual) || this.shouldRenderCustomAvatar()) {
      return false;
    }
    const decodedAssetVisible: boolean = this.shouldRenderBrandAsset(visual) &&
      totpBrandAssetVisibility(this.avatarState.snapshot(), this.brandPixelMap !== null) === 'asset';
    return !this.customAvatarReady && !this.brandReady && !decodedAssetVisible;
  }

  private brandLogoBackground(visual: TotpBrandVisual): string {
    // X distributes a transparent white SVG in its official brand kit. Keep
    // the official bytes unchanged and give that variant its required dark
    // field in both light and dark app themes.
    return visual.slug === 'x' ? visual.background : this.pal().surface;
  }

  @Builder
  private brandAvatar(
    visual: TotpBrandVisual,
    token: TotpBrandAvatarToken | null
  ) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.shouldShowInitials(visual)) {
        Text(visual.initials)
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(visual.foreground)
          .fontFamily(AppTheme.fontFamily)
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      if (this.shouldRenderDirectBrandResource(visual)) {
        Image(this.directBrandResource(visual) as Resource)
          .width(42).height(42).padding(9).borderRadius(21)
          .backgroundColor(this.brandLogoBackground(visual))
          .objectFit(ImageFit.Contain)
          .onComplete((): void => {
            if (token !== null && this.avatarState.onComplete(token)) {
              this.brandReady = true;
              this.brandFailed = false;
            }
          })
          .onError((): void => {
            if (this.avatarKey === this.brandKey(visual)) {
              // Rawfile is the primary source.  If a malformed/missing asset
              // is ever shipped, fall back to the existing decoded asset or
              // initials instead of leaving a broken Image node in the card.
              this.brandResourceFailed = true;
              this.brandReady = false;
            }
          })
      }
      if (this.shouldRenderBrandAsset(visual)) {
        Image(this.brandPixelMap as image.PixelMap)
          .width(42).height(42).padding(9).borderRadius(21)
          .backgroundColor(this.brandLogoBackground(visual))
          .objectFit(ImageFit.Contain)
          .opacity(totpBrandAssetVisibility(
            this.avatarState.snapshot(), this.brandPixelMap !== null) === 'asset' ? 1 : 0)
          .onComplete((): void => {
            if (token !== null && this.avatarState.onComplete(token)) {
              this.brandReady = true;
              this.brandFailed = false;
            }
          })
          .onError((): void => {
            if (token !== null && this.avatarState.onError(token)) {
              this.releaseBrandAsset();
              this.brandPixelMap = null;
              this.brandReady = false;
              this.brandFailed = true;
              TOTP_BRAND_CACHE.markFailed(visual.slug, visual.sha256);
            }
          })
      }
      if (this.shouldRenderCustomAvatar()) {
        Image(this.customAvatarUrl())
          .width(42).height(42).borderRadius(21)
          .backgroundColor(this.pal().surface)
          .objectFit(ImageFit.Cover)
          .onComplete((): void => {
            if (this.avatarKey === this.brandKey(visual)) {
              this.customAvatarFailed = false;
              this.customAvatarReady = true;
            }
          })
          .onError((): void => {
            if (this.avatarKey === this.brandKey(visual)) {
              this.customAvatarFailed = true;
              this.customAvatarReady = false;
              this.brandReady = false;
            }
          })
      }
    }
    .width(42).height(42)
    .borderRadius(21)
    .backgroundColor(visual.background)
    .margin({ right: 10 })
  }

  build() {
    Row() {
      if (this.showCheckbox) {
        Checkbox()
          .select(this.checkboxSelected)
          .selectedColor(this.accentColor)
          .margin({ right: 8 })
          .onChange((v: boolean) => { if (this.onCheckChange) { this.onCheckChange(v); } })
      }
      // An explicitly stored avatar wins; otherwise known brands use the
      // bundled rawfile resource and initials remain the final fallback.
      this.brandAvatar(this.visualForBuild(), this.avatarToken)

      Column() {
        Row() {
          Text(this.primaryLabel())
            .fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
            .maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.entry.locked) {
            SymbolGlyph($r('sys.symbol.ohos_lock'))
              .fontSize(14)
              .fontColor([this.accentColor])
              .margin({ left: 6 })
          }
        }
        if (this.secondaryLabel() !== '') {
          Text(this.secondaryLabel())
            .fontSize(12).fontColor(this.pal().text2)
            .fontFamily(AppTheme.fontFamily)
            .margin({ top: 2 }).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.entry.locked || this.pageLocked) {
          Text('已锁定 · 需要验证')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
        } else if (!this.secretAvailable()) {
          Text('密钥不可用 · 请解锁主密码或重新绑定')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (!this.entry.locked && !this.pageLocked && this.secretAvailable()) {
        Column() {
          Text(this.codeStr)
            .fontSize(26).fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor).fontFamily('monospace')
            .onClick(() => {
              // In multi-select a tap selects instead of copying.
              if (this.showCheckbox) {
                if (this.onCheckChange) { this.onCheckChange(!this.checkboxSelected); }
                return;
              }
              this.copyCode();
            })
          Row() {
            Progress({ value: this.remaining, total: this.entry.period, type: ProgressType.Linear })
              .width(60).height(3).color(this.accentColor)
              .backgroundColor(this.pal().surface)
            Text(`${this.remaining}s`)
              .fontSize(10).fontColor(this.pal().text3)
              .fontFamily('monospace').margin({ left: 6 })
          }.margin({ top: 4 })
        }.alignItems(HorizontalAlign.End)
      } else {
        SymbolGlyph($r('sys.symbol.ohos_lock'))
          .fontSize(24)
          .fontColor([this.pal().text3])
          .accessibilityText(this.entry.locked && !this.pageLocked ? '解锁这个 2FA 账户' : '已锁定')
          .onClick((): void => {
            if (this.showCheckbox) {
              if (this.onCheckChange) { this.onCheckChange(!this.checkboxSelected); }
              return;
            }
            void this.unlockEntry();
          })
      }
      if (this.isDesktopDevice && !this.showCheckbox && !this.pageLocked) {
        Button() {
          Text('⋯').fontSize(18).fontColor(this.pal().text)
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(this.pal().surface)
        .margin({ left: 8 })
        .accessibilityText('更多操作')
        .bindPopup(this.menuVisible, {
          builder: this.totpMenuBuilder(),
          placement: Placement.BottomRight,
          enableArrow: true,
          popupColor: this.pal().card,
          width: 128,
          onStateChange: (e: Object) => {
            const ev: Record<string, boolean> = e as Record<string, boolean>;
            if (!ev['isVisible']) { this.menuVisible = false; }
          }
        })
        .onClick(() => { this.menuVisible = !this.menuVisible; })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
    .borderRadius(14).backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }
}
