import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * AI 动效: how the assistant looks while it works. Each kind has a few styles; the choice is per device (not per
 * account), kept in Preferences and mirrored into AppStorage so every AI surface follows it at once. With the
 * assistant's 减少动态效果 on, every kind falls back to its quietest style.
 */
export const AI_MOTION_THINKING: string = 'aiMotion.thinking';
export const AI_MOTION_ORB: string = 'aiMotion.orb';
export const AI_MOTION_DONE: string = 'aiMotion.done';
export const AI_MOTION_OPEN: string = 'aiMotion.open';
export const AI_MOTION_SEND_GLOW: string = 'aiMotion.sendGlow';
export const AI_MOTION_SPEED: string = 'aiMotion.speed';
/** Set by the assistant's personalization (减少动态效果). */
export const AI_MOTION_REDUCED: string = 'diagnosticAiReducedMotion';

export class AiMotionOption {
  id: string;
  label: string;
  detail: string;

  constructor(id: string, label: string, detail: string) {
    this.id = id;
    this.label = label;
    this.detail = detail;
  }
}

export class AiMotionKind {
  key: string;
  title: string;
  detail: string;
  fallback: string;
  quiet: string;
  options: AiMotionOption[];

  constructor(key: string, title: string, detail: string, fallback: string, quiet: string, options: AiMotionOption[]) {
    this.key = key;
    this.title = title;
    this.detail = detail;
    this.fallback = fallback;
    this.quiet = quiet;
    this.options = options;
  }
}

export const AI_MOTION_KINDS: AiMotionKind[] = [
  new AiMotionKind(AI_MOTION_THINKING, '思考动画', '准备、思考和执行时转动的指示', 'dots', 'minimal', [
    new AiMotionOption('dots', '光点环', '六个光点公转，大小随波峰起伏'),
    new AiMotionOption('discs', '圆片环', '圆片像硬币一样翻转，整圈同时旋转'),
    new AiMotionOption('halo', '智能光环', '多彩光环在空间里翻转，带亮芯辉光'),
    new AiMotionOption('aurora', '极光环', '彩虹光环流转，柔和发光'),
    new AiMotionOption('strands', '彩丝声波', '彩色细丝交织成声波'),
    new AiMotionOption('orbit', '彗星轨道', '三颗光点带着拖尾绕圈'),
    new AiMotionOption('wave', '语音波', '缩小的语音球光带'),
    new AiMotionOption('minimal', '简洁', '三个圆点轻轻起伏')
  ]),
  new AiMotionKind(AI_MOTION_ORB, '悬浮球', '抓取诊断和执行操作时浮在屏幕上的球', 'voice', 'glass', [
    new AiMotionOption('voice', '语音球', '梭形光带分层流动，带呼吸'),
    new AiMotionOption('aurora', '极光球', '几团彩色柔光在玻璃球里环绕'),
    new AiMotionOption('halo', '智能光环', '深色镜片里翻转的多彩光环'),
    new AiMotionOption('sine', '正弦光带', '细亮光线交织流动'),
    new AiMotionOption('xiaoyi', '小艺标志', '深色玻璃球里的小艺标志'),
    new AiMotionOption('glass', '玻璃球', '只有玻璃球体和微光')
  ]),
  new AiMotionKind(AI_MOTION_DONE, '完成动画', '执行操作完成时的确认', 'check', 'none', [
    new AiMotionOption('check', '画圆打勾', '先画圆再画对勾，最后轻弹'),
    new AiMotionOption('island', '灵动岛光环', '展开成方块，光环翻转收拢后打勾'),
    new AiMotionOption('bounce', '弹出对勾', '对勾直接弹出'),
    new AiMotionOption('ripple', '涟漪扩散', '对勾出现后光环向外扩散'),
    new AiMotionOption('sparkle', '粒子绽放', '画勾时迸出细小光点'),
    new AiMotionOption('none', '不显示', '直接变成悬浮球')
  ]),
  new AiMotionKind(AI_MOTION_OPEN, '展开动画', '打开 AI 助手时面板的出现方式', 'morph', 'none', [
    new AiMotionOption('morph', '灵动岛形变', '胶囊拉宽再长成面板'),
    new AiMotionOption('liquid', '液态弹出', '从灵动岛弹性回弹地展开'),
    new AiMotionOption('focus', '模糊聚焦', '由模糊放大到清晰'),
    new AiMotionOption('fade', '淡入', '面板直接淡入展开'),
    new AiMotionOption('none', '关闭', '立即出现')
  ]),
  new AiMotionKind(AI_MOTION_SEND_GLOW, '发送按钮光晕', '可以发送时按钮外的彩色光环', 'flow', 'off', [
    new AiMotionOption('flow', '流动', '彩色光环沿圆周流动'),
    new AiMotionOption('comet', '彗星', '一点亮光沿光环绕行'),
    new AiMotionOption('breath', '呼吸', '光环柔和地明暗缩放'),
    new AiMotionOption('static', '静止', '彩色光环不转动'),
    new AiMotionOption('off', '关闭', '只有按钮本身')
  ]),
  new AiMotionKind(AI_MOTION_SPEED, '动效速度', '思考动画和悬浮球的快慢', 'normal', 'normal', [
    new AiMotionOption('slow', '慢', ''),
    new AiMotionOption('normal', '标准', ''),
    new AiMotionOption('fast', '快', '')
  ])
];

function kindOf(key: string): AiMotionKind | undefined {
  return AI_MOTION_KINDS.find((kind: AiMotionKind): boolean => kind.key === key);
}

/** The style in effect for a kind: the saved choice, or its quietest style while motion is reduced. */
export function aiMotionStyle(key: string): string {
  const kind: AiMotionKind | undefined = kindOf(key);
  if (kind === undefined) { return ''; }
  if (AppStorage.get<boolean>(AI_MOTION_REDUCED) === true) { return kind.quiet; }
  const value: string | undefined = AppStorage.get<string>(key);
  return value !== undefined && kind.options.some((o: AiMotionOption): boolean => o.id === value) ? value : kind.fallback;
}

/** Time scale for continuous motion (thinking ring, orbs). */
export function aiMotionSpeedFactor(speed: string): number {
  if (speed === 'slow') { return 0.7; }
  if (speed === 'fast') { return 1.4; }
  return 1;
}

const STORE_NAME: string = 'RemoteDeskAiMotion-v1';

export class DiagnosticAiMotionStore {
  /** Load the saved choices into AppStorage (once per launch is enough; later changes go through save). */
  static init(context: common.Context): void {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      AI_MOTION_KINDS.forEach((kind: AiMotionKind): void => {
        const saved: preferences.ValueType = prefs.getSync(kind.key, kind.fallback);
        const value: string = typeof saved === 'string' &&
          kind.options.some((o: AiMotionOption): boolean => o.id === saved) ? saved : kind.fallback;
        AppStorage.setOrCreate(kind.key, value);
      });
    } catch (_error) {
      AI_MOTION_KINDS.forEach((kind: AiMotionKind): void => { AppStorage.setOrCreate(kind.key, kind.fallback); });
    }
  }

  static save(context: common.Context, key: string, value: string): void {
    const kind: AiMotionKind | undefined = kindOf(key);
    if (kind === undefined || !kind.options.some((o: AiMotionOption): boolean => o.id === value)) { return; }
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      prefs.putSync(key, value);
      prefs.flush();
    } catch (_error) { /* the choice still applies for this launch */ }
  }
}
