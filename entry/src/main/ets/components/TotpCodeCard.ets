/**
 * TotpCodeCard.ets — TOTP 验证码卡片 (v4: 纯展示, 操作由 swipeAction 处理)
 */
import { TotpEntry, TotpCode } from '../model/TotpEntry';
import { TotpEngine } from '../services/TotpEngine';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';

/** 已知公司品牌色映射 */
const BRAND_COLORS: Record<string, string> = {
  'Google': '#4285F4',
  'GitHub': '#24292F',
  'Microsoft': '#00A4EF',
  'Azure': '#0089D6',
  'AWS': '#FF9900',
  'Amazon': '#FF9900',
  'GitLab': '#FC6D26',
  'Twitter': '#1DA1F2',
  'X': '#000000',
  'Facebook': '#1877F2',
  'Meta': '#0467DF',
  'Apple': '#555555',
  'LinkedIn': '#0A66C2',
  'Dropbox': '#0061FF',
  'Slack': '#4A154B',
  'Discord': '#5865F2',
  'Spotify': '#1ED760',
  'Netflix': '#E50914',
  'PayPal': '#003087',
  'Epic Games': '#313131',
  'Steam': '#171A21',
  'Cloudflare': '#F38020',
  'DigitalOcean': '#0080FF',
  'Heroku': '#430098',
  'Atlassian': '#0052CC',
  'Jira': '#0052CC',
  'Notion': '#000000',
  'Figma': '#F24E1E',
  'Adobe': '#FF0000',
  'Shopify': '#7AB55C',
  'Stripe': '#635BFF',
  'Square': '#3D4B5C',
  'Twilio': '#F22F46',
  'SendGrid': '#00A9E0',
  'Namecheap': '#DE3723',
  'GoDaddy': '#00838F',
  'WordPress': '#21759B',
  'Tumblr': '#36465D',
  'Reddit': '#FF4500',
  'Pinterest': '#E60023',
  'Snapchat': '#FFFC00',
  'TikTok': '#000000',
  'Zoom': '#2D8CFF',
  'Binance': '#F3BA2F',
  'Coinbase': '#0052FF',
  'Huawei': '#CF0A2C',
  'hw-cloud': '#CF0A2C',
};

/** 从名称生成一致的颜色 */
function brandColorFor(issuer: string, account: string): string {
  const key: string = issuer.trim();
  // 精确匹配
  if (BRAND_COLORS[key]) { return BRAND_COLORS[key]; }
  // 大小写不敏感匹配
  const lower: string = key.toLowerCase();
  for (let i = 0; i < Object.keys(BRAND_COLORS).length; i++) {
    const k = Object.keys(BRAND_COLORS)[i];
    if (k.toLowerCase() === lower) { return BRAND_COLORS[k]; }
  }
  // 包含匹配 (e.g. "Google Cloud" → Google)
  for (let j = 0; j < Object.keys(BRAND_COLORS).length; j++) {
    const k = Object.keys(BRAND_COLORS)[j];
    if (lower.includes(k.toLowerCase()) || k.toLowerCase().includes(lower)) {
      return BRAND_COLORS[k];
    }
  }
  // 从 account domain 猜 (e.g. "user@github.com" → github)
  if (account.includes('@')) {
    const domain: string = account.split('@')[1] || '';
    const domainLower: string = domain.split('.')[0] || '';
    for (let d = 0; d < Object.keys(BRAND_COLORS).length; d++) {
      const k = Object.keys(BRAND_COLORS)[d];
      if (k.toLowerCase().includes(domainLower) || domainLower.includes(k.toLowerCase())) {
        return BRAND_COLORS[k];
      }
    }
  }
  // 根据名称 hash 生成颜色
  let hash: number = 0;
  for (let c = 0; c < key.length; c++) {
    hash = key.charCodeAt(c) + ((hash << 5) - hash);
  }
  const hue: number = Math.abs(hash) % 360;
  return `hsl(${hue}, 55%, 42%)`;
}

/** 提取首字母 (支持中英文) */
function initialOf(name: string): string {
  const t: string = name.trim();
  if (t.length === 0) { return '?'; }
  // 英文字母开头
  const first: string = t.charAt(0);
  if (/[A-Za-z]/.test(first)) { return first.toUpperCase(); }
  // 中文取第一个字
  return first;
}

@Component
export struct TotpCodeCard {
  @Prop entry: TotpEntry;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop pageLocked: boolean = false;
  @Prop showCheckbox: boolean = false;
  @Prop checkboxSelected: boolean = false;
  onCheckChange?: (checked: boolean) => void;
  @State codeStr: string = '------';
  @State remaining: number = 30;
  private timer: number = -1;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    if (!this.pageLocked && !this.entry.locked) {
      this.refresh();
      this.timer = setInterval(() => { this.refresh(); }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private refresh(): void {
    const tc: TotpCode = TotpEngine.generateCode(this.entry);
    this.codeStr = tc.code;
    this.remaining = tc.remaining;
  }

  private copyCode(): void {
    if (this.pageLocked || this.entry.locked) { return; }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.codeStr);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: `验证码 ${this.codeStr} 已复制`, duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  build() {
    Row() {
      if (this.showCheckbox) {
        Checkbox()
          .select(this.checkboxSelected)
          .selectedColor('#007DFF')
          .margin({ right: 8 })
          .onChange((v: boolean) => { if (this.onCheckChange) { this.onCheckChange(v); } })
      }
      // 公司 logo 圆形头像 — Stack 确保中英文字符双向居中
      Stack({ alignContent: Alignment.Center }) {
        Text(initialOf(this.entry.issuer))
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .fontFamily(AppTheme.fontFamily)
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .width(42).height(42)
      .borderRadius(21)
      .backgroundColor(brandColorFor(this.entry.issuer, this.entry.account))
      .margin({ right: 10 })

      Column() {
        Row() {
          Text(this.entry.issuer || 'Unknown')
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
        if (this.entry.account !== '') {
          Text(this.entry.account)
            .fontSize(12).fontColor(this.pal().text2)
            .fontFamily(AppTheme.fontFamily)
            .margin({ top: 2 }).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.entry.locked || this.pageLocked) {
          Text('已锁定 · 需要验证')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (!this.entry.locked && !this.pageLocked) {
        Column() {
          Text(this.codeStr)
            .fontSize(26).fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor).fontFamily('monospace')
            .onClick(() => { this.copyCode(); })
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
