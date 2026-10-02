/**
 * ProIntroRegistry — content of the Pro 功能介绍 sheet shown after the first-install guide, after the post-update
 * 「新功能」 list and from 「设置 → 教程」.
 *
 * Groups the Pro catalog by what a user gets, not by internal feature ids. Release builds keep Pro closed, so the
 * sheet is a preview there: it never offers a purchase and every item reads as 即将推出.
 */
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
}

const PRO_INTRO_ITEMS: ProIntroItem[] = [
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
    id: 'pro-intro-ai', glyph: $r('sys.symbol.code_square'),
    title: '远程 AI 工作台', hue: '#7B61FF', hue2: '#E25B8A',
    desc: '连接自己电脑上的 Codex 或 DSH，查看执行过程、批准操作、恢复会话，代码在你的电脑上运行。',
    tags: ['Codex', 'DSH', '局域网']
  },
  {
    id: 'pro-intro-knock', glyph: $r('sys.symbol.bolt_fill'),
    title: '碰一碰', hue: '#F2B705', hue2: '#FF8A3D',
    desc: '手机碰一碰分享 SSH 连接；在鸿蒙 PC 的 SFTP 窗口直接接收手机发来的文件。',
    tags: ['分享连接', '传文件']
  },
  {
    id: 'pro-intro-diagnostics', glyph: $r('sys.symbol.performance'),
    title: '诊断与 AI 帮助', hue: '#2BB673', hue2: '#00B8A9',
    desc: '用你自己配置的 AI 分析脱敏后的诊断信息，给出排查建议；也能预览后一键打包诊断邮件。',
    tags: ['自有 AI', '脱敏诊断', '邮件打包']
  }
];

export function proIntroItems(): ProIntroItem[] {
  return PRO_INTRO_ITEMS.map((item: ProIntroItem): ProIntroItem => ({
    id: item.id, glyph: item.glyph, title: item.title, desc: item.desc, tags: item.tags.slice(),
    hue: item.hue, hue2: item.hue2
  }));
}

/** Line under the title. `open` is true only where Pro can be used (Debug, or a future Release that ships Pro). */
export function proIntroStatus(open: boolean): string {
  return open ? '在「设置 → Pro 功能」中查看每项功能的状态与开关' : '正在打磨中，正式开放后可在「设置」中开通';
}

/** Promises that hold whether or not Pro is open: one purchase and a free core. */
export function proIntroPromises(): string[] {
  return ['一次购买', '不自动续费', '核心连接永久免费'];
}
