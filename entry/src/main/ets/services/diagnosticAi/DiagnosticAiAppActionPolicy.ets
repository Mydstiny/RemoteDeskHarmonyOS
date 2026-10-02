/**
 * App actions the assistant may start from an answer. The model only returns plain-text steps, so each step is
 * matched against this whitelist by keywords; a step that matches nothing stays text and never becomes a button
 * that pretends to run. Every action only opens a screen the user then operates themselves.
 */
export type DiagnosticAiAppActionId =
  'host.add' | 'cloud.sync' | 'diagnostic.log' | 'feedback' | 'ssh.keys' | 'rdp.credentials' | 'ai.config';

export class DiagnosticAiAppAction {
  id: DiagnosticAiAppActionId;
  label: string;

  constructor(id: DiagnosticAiAppActionId, label: string) {
    this.id = id;
    this.label = label;
  }
}

class ActionRule {
  id: DiagnosticAiAppActionId;
  label: string;
  /** Every group must match (one of its words). */
  groups: string[][];

  constructor(id: DiagnosticAiAppActionId, label: string, groups: string[][]) {
    this.id = id;
    this.label = label;
    this.groups = groups;
  }
}

const RULES: ActionRule[] = [
  new ActionRule('host.add', '打开添加主机', [['添加', '新建', '新增', '“+”', '"+"', '+'], ['主机', '连接', '协议', '设备']]),
  new ActionRule('cloud.sync', '打开云同步', [['云同步', '同步', '云端', '备份']]),
  new ActionRule('diagnostic.log', '查看诊断日志', [['日志', '诊断记录']]),
  new ActionRule('feedback', '提交反馈', [['反馈', '联系开发', '联系我们']]),
  new ActionRule('ssh.keys', '打开 SSH 密钥库', [['密钥', '公钥', '私钥', 'key']]),
  new ActionRule('rdp.credentials', '管理 RDP 凭据', [['凭据', '账号密码', '用户名和密码', '登录凭证']])
];

/** The app actions a list of steps points to, in step order, each at most once. */
export function diagnosticAiAppActionsForSteps(steps: string[]): DiagnosticAiAppAction[] {
  const found: DiagnosticAiAppAction[] = [];
  steps.forEach((step: string): void => {
    const text: string = step.toLowerCase();
    RULES.forEach((rule: ActionRule): void => {
      if (found.some((a: DiagnosticAiAppAction): boolean => a.id === rule.id)) { return; }
      const matches: boolean = rule.groups.every((words: string[]): boolean =>
        words.some((word: string): boolean => text.indexOf(word.toLowerCase()) >= 0));
      if (matches) { found.push(new DiagnosticAiAppAction(rule.id, rule.label)); }
    });
  });
  return found;
}

/** Short label of an app action, as shown while it runs. */
export function diagnosticAiAppActionLabel(id: DiagnosticAiAppActionId): string {
  // Not matched from answers: offered by the assistant itself when no AI service is set up yet.
  if (id === 'ai.config') { return '前往 AI 配置'; }
  const rule: ActionRule | undefined = RULES.find((r: ActionRule): boolean => r.id === id);
  return rule !== undefined ? rule.label : '执行操作';
}
