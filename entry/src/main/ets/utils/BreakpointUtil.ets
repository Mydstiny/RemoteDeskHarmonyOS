/**
 * BreakpointUtil.ets — 响应式断点工具类
 *
 * 基于华为官方一次开发多端部署规范 (API 23)。
 * 使用 window.on('windowSizeChange') 监听窗口变化, 支持 PC 自由窗口模式。
 *
 * 横向断点 (以窗口宽度 vp 为基准):
 *   sm   [320, 600)   — 手机竖屏
 *   md   [600, 840)   — 手机横屏 / 小平板
 *   lg   [840, 1440)  — 平板 / 折叠屏展开
 *   xl   [1440, +∞)  — PC / 大屏
 *
 * isWideScreen(): lg / xl  — 适合侧边导航栏
 * isPC():        xl       — 适合键盘/鼠标/多窗交互
 */
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

const TAG = 'BreakpointUtil';
const DOMAIN = 0x0020;

const BP_MD_MIN = 600;
const BP_LG_MIN = 840;
const BP_XL_MIN = 1440;

let gBp: string = 'sm';
let gWidth: number = 360;

function px2vpSync(px: number): number {
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    return px / d.densityPixels;
  } catch (_e) {
    return px / 2.0;
  }
}

function calcBp(w: number): string {
  if (w >= BP_XL_MIN) { return 'xl'; }
  if (w >= BP_LG_MIN) { return 'lg'; }
  if (w >= BP_MD_MIN) { return 'md'; }
  return 'sm';
}

function isWide(bp: string): boolean {
  return bp === 'lg' || bp === 'xl';
}

function isPc(bp: string): boolean {
  return bp === 'xl';
}

let gDesktopDevice: boolean = false;
function detectDesktopDevice(): boolean {
  try {
    const dt: string = deviceInfo.deviceType;
    return dt === 'pc' || dt === '2in1';
  } catch (_e) {
    return false;
  }
}

function updateBp(width: number): void {
  gWidth = width;
  const bp: string = calcBp(width);
  if (bp !== gBp) {
    hilog.info(DOMAIN, TAG, "断点变化: " + gBp + " → " + bp + " (w=" + width.toString() + ")");
  }
  gBp = bp;
  AppStorage.setOrCreate<string>('currentBreakpoint', bp);
  AppStorage.setOrCreate<boolean>('isWideScreen', isWide(bp));
  AppStorage.setOrCreate<boolean>('isPC', isPc(bp));
  AppStorage.setOrCreate<boolean>('isDesktopDevice', gDesktopDevice);
}

export class BreakpointUtil {
  static calcBreakpoint(width: number): string {
    return calcBp(width);
  }

  static getBreakpoint(): string {
    return gBp;
  }

  static getWidth(): number {
    return gWidth;
  }

  static isWideScreen(): boolean {
    return isWide(gBp);
  }

  static isPC(): boolean {
    return isPc(gBp);
  }

  static init(win: window.Window): void {
    try {
      gDesktopDevice = detectDesktopDevice();
      hilog.info(DOMAIN, TAG, "设备类型: " + deviceInfo.deviceType + " desktop=" + gDesktopDevice.toString());
      const props: window.WindowProperties = win.getWindowProperties();
      const rect: window.Rect = props.windowRect;
      const w: number = px2vpSync(rect.width);
      updateBp(w);

      win.on('windowSizeChange', (size: window.Size) => {
        updateBp(px2vpSync(size.width));
      });

      hilog.info(DOMAIN, TAG, "断点系统已注册, 当前: " + gBp + " w=" + gWidth.toString() + "vp");
    } catch (err) {
      hilog.error(DOMAIN, TAG, "断点系统初始化失败: " + JSON.stringify(err));
      updateBp(360);
    }
  }
}
