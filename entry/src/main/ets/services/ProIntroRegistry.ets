import { PRO_TRIAL_STORY } from './ProTrialStory';

/**
 * ProIntroRegistry — content of the Pro 功能介绍 sheet shown after the first-install guide, after the post-update
 * 「新功能」 list and from 「设置 → 教程」.
 *
 * Groups the Pro catalog by what a user gets, not by internal feature ids. AI 助理 leads, as one large featured card.
 * In 1.2.0 everyone has Pro free (ProComplimentaryPolicy): the sheet introduces the trial and never sells.
 */
/** AppStorage flag set by 「现在订购」 in the startup sheet; the home page opens the Pro page and clears it. */
export const PRO_ORDER_PENDING_KEY: string = 'proOrderPending';

export interface ProIntroItem {
  id: string;
  glyph: Resource;
  title: string;
  desc: string;
  /** Two or three keywords shown as small chips. */
  tags: string[];
  /** Gradient of the icon tile (#RRGGBB). */
  hue: string;
  hue2: string;
  /** Shown first, across the whole width, larger than the rest. */
  featured?: boolean;
  /** What the featured card lists, one line each. */
  points?: string[];
}

const PRO_INTRO_ITEMS: ProIntroItem[] = [
  {
    id: 'pro-intro-ai-assistant', glyph: $r('sys.symbol.wand_and_stars'),
    title: 'AI 助理', hue: '#5B8CFF', hue2: '#B455FF', featured: true,
    desc: '用你自己配置的 AI，一句话就能办事：聊天写作、读文档出报告，设提醒、搜网页、改设置、管理主机；连接出问题时抓取脱敏日志帮你排查。',
    tags: ['聊天 · 助理 · 语音', '文档与数据管理', '诊断与反馈'],
    points: [
      '聊天：写作、翻译、总结，生成和修改 Word、Excel，记住你交代的事',
      'AI 语音（Beta）：像 Siri 一样说话，能随时打断，语音和文字随时切换',
      '能动手：提醒、日程、搜索、分享、改设置、连接或管理主机，先给卡片再执行',
      '助理诊断：抓取脱敏日志分析连接问题，整理好邮件和日志附件发给开发者',
      '你的想法它会记下，攒好了说一声，就整理成需求邮件发给开发者',
      '连接中也能用：各协议的侧栏里一点，悬浮球陪着你操作'
    ]
  },
  {
    id: 'pro-intro-ai', glyph: $r('sys.symbol.code_square'),
    title: '远程 AI 工作台', hue: '#7B61FF', hue2: '#E25B8A',
    desc: '连接自己电脑上的 Codex 或 DSH，查看执行过程、批准操作、恢复会话，代码在你的电脑上运行。',
    tags: ['Codex', 'DSH', '局域网']
  },
  {
    id: 'pro-intro-workspaces', glyph: $r('sys.symbol.rectangle_on_rectangle'),
    title: '工作区与布局', hue: '#4F7CFF', hue2: '#7B61FF',
    desc: '把常用的一组会话存成工作区，一键打开：PC 按布局摆好窗口，Pad 自动分屏。',
    tags: ['一键打开', 'PC 窗口布局', 'Pad 分屏']
  },
  {
    id: 'pro-intro-hosts', glyph: $r('sys.symbol.list_bullet'),
    title: '高级主机管理', hue: '#FF8A3D', hue2: '#FF5A5F',
    desc: '跨协议分组与标签、智能分组，多选批量修改端口、账号与显示设置，导入导出不含密码。',
    tags: ['分组与标签', '批量编辑', '导入导出']
  },
  {
    id: 'pro-intro-continuation', glyph: $r('sys.symbol.link'),
    title: '同账号接续', hue: '#00B8A9', hue2: '#3BA7FF',
    desc: '在手机、平板和 PC 之间接着用：SSH 回到原来的目录，RDP 恢复桌面视图，RustDesk 与 VNC 重新连上同一台电脑。',
    tags: ['手机 · 平板 · PC', 'SSH / RDP / RustDesk / VNC']
  },
  {
    id: 'pro-intro-display', glyph: $r('sys.symbol.display'),
    title: '远端显示方案', hue: '#3BA7FF', hue2: '#4F7CFF',
    desc: '自定义远端桌面宽高，Windows 界面缩放 100–500% 任意选择；RustDesk 在支持的远端上提交自定义分辨率。',
    tags: ['任意分辨率', 'Windows 缩放', 'RDP · RustDesk']
  },
  {
    id: 'pro-intro-personalization', glyph: $r('sys.symbol.paintpalette_fill'),
    title: '个性化', hue: '#E25B8A', hue2: '#9B5DE5',
    desc: '自定义组合键、成套的 SSH 终端皮肤与字体，Pro 标识的样式、动效与配色，以及预设应用图标。',
    tags: ['组合键', '终端皮肤', 'Pro 标识']
  },
  {
    id: 'pro-intro-knock', glyph: $r('sys.symbol.bolt_fill'),
    title: '碰一碰', hue: '#F2B705', hue2: '#FF8A3D',
    desc: '手机碰一碰分享 SSH 连接；在鸿蒙 PC 的 SFTP 窗口直接接收手机发来的文件（验证完成后开放）。',
    tags: ['分享连接', '传文件']
  }
];

export function proIntroItems(): ProIntroItem[] {
  return PRO_INTRO_ITEMS.map((item: ProIntroItem): ProIntroItem => ({
    id: item.id, glyph: item.glyph, title: item.title, desc: item.desc, tags: item.tags.slice(),
    hue: item.hue, hue2: item.hue2, featured: item.featured === true,
    points: item.points !== undefined ? item.points.slice() : []
  }));
}

/** Line under the hero. `trial`: the 1.2.0 free trial is on (every Pro feature is open to everyone). */
export function proIntroStatus(trial: boolean): string {
  return trial ? PRO_TRIAL_STORY + '每项功能的状态可在「设置 → Pro 功能」查看。' :
    '正在打磨中，正式开放后可在「设置」中开通';
}

/** What holds for the trial: everything free now and a core that stays free. */
export function proIntroPromises(): string[] {
  return ['全部功能免费试用', '核心连接永久免费'];
}
