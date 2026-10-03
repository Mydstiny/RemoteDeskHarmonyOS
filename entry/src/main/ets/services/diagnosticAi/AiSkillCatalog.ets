/**
 * 工具与技能 for the AI chat. A tool is something the app does for the model (write a document, read an added file,
 * look at the hosts or the connection log); each can be switched off in 设置 › AI 工具与技能, and app data leaves the
 * device only through a tool that is on. A skill is a ready-made way of doing a task (周报, 会议纪要, 翻译…): a name,
 * when to use it, instructions for the model and the words that start it. Built-in skills are installed from the
 * library; users add their own, or import a SKILL.md / JSON file.
 */

export class AiToolSpec {
  id: string;
  /** The function name the model calls. */
  fn: string;
  name: string;
  detail: string;
  /** documents · app */
  group: string;
  defaultOn: boolean;
  /** The OpenAI-style function definition, as JSON text. */
  schema: string;

  constructor(id: string, fn: string, name: string, detail: string, group: string, defaultOn: boolean, schema: string) {
    this.id = id;
    this.fn = fn;
    this.name = name;
    this.detail = detail;
    this.group = group;
    this.defaultOn = defaultOn;
    this.schema = schema;
  }
}

function functionJson(name: string, description: string, properties: string, required: string): string {
  return '{"type":"function","function":{"name":"' + name + '","description":"' + description +
    '","parameters":{"type":"object","properties":{' + properties + '},"required":[' + required + ']}}}';
}

export const AI_TOOLS: AiToolSpec[] = [
  new AiToolSpec('documents.create', 'create_document', '生成文档', '把内容写成 Word、Excel、Markdown 或文本文件，可以用 WPS 打开、分享或另存',
    'documents', true, functionJson('create_document',
      '生成一个文档文件（Word、Excel、Markdown 或纯文本），保存在用户设备上，用户可以用 WPS 等应用打开、分享或另存。',
      '"title":{"type":"string","description":"文件名，不含扩展名"},' +
      '"format":{"type":"string","enum":["docx","xlsx","md","txt"],"description":"docx=Word，xlsx=Excel，md=Markdown，txt=纯文本"},' +
      '"content":{"type":"string","description":"正文。docx 和 md 用 Markdown（# 标题、- 列表、1. 编号、| 表格 |、**加粗**）；xlsx 用 Markdown 表格，第一行为表头；txt 为纯文本"}',
      '"title","format","content"')),
  new AiToolSpec('documents.read', 'read_attachment', '读取附件', '读取你添加的长文档中超出开头的部分',
    'documents', true, functionJson('read_attachment', '读取用户添加的附件的后续内容（附件较长时，消息里只放了开头）。',
      '"name":{"type":"string","description":"附件文件名"},"offset":{"type":"integer","description":"从第几个字符开始读"}',
      '"name","offset"')),
  new AiToolSpec('app.hosts', 'list_hosts', '主机列表', '主机名称、协议、分组、最近连接时间和网络状态；不含地址、账号和密码',
    'app', true, functionJson('list_hosts', '列出用户在 RemoteDesktop 里保存的远程主机：名称、协议、分组、最近连接时间、最近一次网络状态。不含地址和凭据。',
      '"protocol":{"type":"string","description":"只看某种协议：rdp、rustdesk、ssh、vnc、moonlight；留空为全部"}', '')),
  new AiToolSpec('app.connections', 'connection_history', '连接记录', '最近的连接和失败记录：时间、主机名、协议、结果',
    'app', true, functionJson('connection_history', '读取最近若干天在这台设备上的远程连接记录（时间、主机名、协议、成功或失败原因），适合写周报、日报和主机使用总结。',
      '"days":{"type":"integer","description":"最近几天，1 到 45，默认 7"}', '')),
  new AiToolSpec('app.settings', 'app_settings', '应用设置', '当前的连接、显示和 AI 设置（只读，不会修改）',
    'app', true, functionJson('app_settings', '读取 RemoteDesktop 当前的设置项和取值（只读）。', '', '')),
  new AiToolSpec('app.usage', 'ai_usage', 'AI 用量', '最近的 AI 请求次数、Token 和估算费用',
    'app', true, functionJson('ai_usage', '读取最近若干天的 AI 用量：请求次数、Token、估算费用。',
      '"days":{"type":"integer","description":"最近几天，默认 7"}', ''))
];

export function aiToolSpec(id: string): AiToolSpec | undefined {
  return AI_TOOLS.find((tool: AiToolSpec): boolean => tool.id === id);
}

export function aiToolByFunction(fn: string): AiToolSpec | undefined {
  return AI_TOOLS.find((tool: AiToolSpec): boolean => tool.fn === fn);
}

export class AiSkill {
  id: string;
  name: string;
  /** One line: what it is for (shown in the library and given to the model). */
  description: string;
  /** How the model should do it. */
  instructions: string;
  /** What a tap on its chip puts in the chat field ('' asks to add a document first). */
  starter: string;
  keywords: string[];
  /** builtin · custom · file */
  source: string;
  /** Asks for a document first (its chip opens the file picker). */
  needsDocument: boolean;

  constructor(id: string, name: string, description: string, instructions: string, starter: string, keywords: string[],
    source: string, needsDocument: boolean = false) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.instructions = instructions;
    this.starter = starter;
    this.keywords = keywords;
    this.source = source;
    this.needsDocument = needsDocument;
  }
}

export const AI_SKILL_LIBRARY: AiSkill[] = [
  new AiSkill('weekly-report', '写周报', '结合本周的远程连接记录和你补充的工作内容写周报',
    '先调用 connection_history（days=7）和 list_hosts 了解本周在哪些主机上工作过、各多少次、有没有连接问题；再结合用户补充的工作内容，' +
    '按「本周完成 / 进行中 / 问题与风险 / 下周计划」写周报，数据要具体（主机名、次数、日期）。用户补充不足时先给草稿，并在末尾列出需要补充的信息。' +
    '用户要文件时调用 create_document 生成 Word。', '帮我写本周周报，生成 Word 文档。本周主要做了：', ['周报', '本周', '这周', '工作总结'], 'builtin'),
  new AiSkill('daily-report', '写日报', '根据今天的连接记录和你的描述写日报',
    '调用 connection_history（days=1）看今天连过哪些主机；按「今日完成 / 遇到的问题 / 明日计划」写简洁的日报。',
    '帮我写今天的日报。今天做了：', ['日报', '今天做了', '今日'], 'builtin'),
  new AiSkill('meeting-minutes', '会议纪要', '把会议记录或录音文字整理成纪要和待办',
    '整理成「会议主题 / 时间与参会人 / 讨论要点 / 结论 / 待办事项（负责人、截止时间）」；待办用表格。原文没有的信息标注“待确认”，不要编造。' +
    '用户要文件时生成 Word。', '把下面的会议记录整理成纪要：\n', ['会议', '纪要', '开会'], 'builtin'),
  new AiSkill('doc-summary', '总结文档', '读你添加的文档，提炼要点、结论和待办',
    '先给一句话结论，再列 3 到 7 条要点，最后列出文档里的待办或需要注意的地方；长文档需要时用 read_attachment 继续读。',
    '', ['总结', '摘要', '概括', '要点', '读一下'], 'builtin', true),
  new AiSkill('translator', '翻译', '中英互译，保留原文格式和术语',
    '判断原文语言：中文译成英文，其他语言译成中文；保留原文的段落、列表和表格格式；专业术语保持一致，不确定的术语在括号里给出原文。',
    '把下面这段话翻译成英文：\n', ['翻译', '译成', '英文', '中文版'], 'builtin'),
  new AiSkill('polish', '润色文字', '让文字更通顺、专业，并说明主要改动',
    '先给出润色后的全文，再用 2 到 4 条说明主要改动；保持原意，不添加原文没有的事实。',
    '帮我润色下面这段文字，让它更通顺专业：\n', ['润色', '改写', '通顺', '修改一下'], 'builtin'),
  new AiSkill('excel-table', '做表格', '把数据或清单整理成 Excel 表格',
    '把用户给的数据整理成表格：第一行为表头，数字列只放数字（单位写在表头里）；用 create_document 生成 xlsx，回答里简单说明表格结构。',
    '帮我做一个 Excel 表格：', ['表格', 'excel', '清单', '统计表'], 'builtin'),
  new AiSkill('email-writer', '写邮件', '按场景写正式或日常邮件',
    '按「主题 / 称呼 / 正文 / 结尾敬语 / 署名」写邮件，语气按场景（正式、礼貌、简洁）；需要时给出两个不同语气的版本。',
    '帮我写一封邮件，内容是：', ['邮件', '写信', '回复邮件'], 'builtin'),
  new AiSkill('ppt-outline', 'PPT 大纲', '把主题或文档整理成演示文稿大纲',
    '按页给出大纲：每页一个标题和 3 到 5 条要点，并建议配图或图表；最后用 create_document 生成 Word 大纲，方便导入 WPS 演示。',
    '帮我做一份 PPT 大纲，主题是：', ['ppt', '演示', '幻灯片', '汇报材料'], 'builtin'),
  new AiSkill('host-report', '主机巡检报告', '汇总所有主机的状态、最近使用和连接问题',
    '调用 list_hosts 和 connection_history（days=30），按协议分组汇总：主机数、最近 30 天使用次数、长期未使用的主机、最近的连接失败及原因；' +
    '给出整理建议（例如清理长期不用的主机、排查经常失败的主机），用表格展示，并生成 Excel 或 Word。',
    '帮我做一份主机巡检报告', ['巡检', '主机报告', '主机状态', '哪些主机'], 'builtin'),
  new AiSkill('study-plan', '学习计划', '按目标和时间排出学习或工作计划',
    '先确认目标、可用时间和截止日期（不足时给出合理假设并说明），再按周或按天给出计划表，每项有具体产出；用表格展示。',
    '帮我做一个学习计划，目标是：', ['计划', '安排', '日程', '学习'], 'builtin'),
  new AiSkill('code-explain', '解释代码', '逐段解释代码或命令，并指出风险',
    '先用一句话说明代码/命令做什么，再逐段解释；指出可能的风险（删除数据、权限、安全问题）和改进建议。',
    '帮我解释这段代码：\n', ['代码', '命令', '脚本', '报错是什么意思'], 'builtin')
];

/** Installed when a user has never changed the list. */
export const AI_DEFAULT_SKILLS: string[] = ['weekly-report', 'meeting-minutes', 'doc-summary', 'translator', 'polish',
  'excel-table', 'email-writer', 'ppt-outline'];

export function aiLibrarySkill(id: string): AiSkill | undefined {
  return AI_SKILL_LIBRARY.find((skill: AiSkill): boolean => skill.id === id);
}

/** The skills a question calls for: those whose keywords it mentions. */
export function aiSkillsForQuestion(skills: AiSkill[], question: string): AiSkill[] {
  const text: string = question.toLowerCase();
  return skills.filter((skill: AiSkill): boolean =>
    skill.keywords.some((word: string): boolean => word !== '' && text.indexOf(word.toLowerCase()) >= 0) ||
      text.indexOf(skill.name.toLowerCase()) >= 0);
}

function frontMatter(text: string): Map<string, string> {
  const fields: Map<string, string> = new Map<string, string>();
  text.split('\n').forEach((line: string): void => {
    const at: number = line.indexOf(':');
    if (at > 0) { fields.set(line.slice(0, at).trim().toLowerCase(), line.slice(at + 1).trim().replace(/^["']|["']$/g, '')); }
  });
  return fields;
}

function listOf(value: string): string[] {
  return value.replace(/^\[|\]$/g, '').split(/[,，、]/).map((word: string): string => word.trim().replace(/^["']|["']$/g, ''))
    .filter((word: string): boolean => word !== '').slice(0, 12);
}

/**
 * A skill from a file: SKILL.md (front matter with name / description / starter / keywords, the body is the
 * instructions), JSON with the same fields, or plain text (the file name is the skill's name). null: not a skill.
 */
export function aiParseSkill(text: string, fileName: string, id: string): AiSkill | null {
  const raw: string = text.replace(/\r\n?/g, '\n').replace(/^﻿/, '').trim();
  if (raw === '') { return null; }
  let name: string = '';
  let description: string = '';
  let instructions: string = '';
  let starter: string = '';
  let keywords: string[] = [];
  if (raw.startsWith('{')) {
    try {
      const row = JSON.parse(raw) as Record<string, Object>;
      const field = (key: string): string => typeof row[key] === 'string' ? (row[key] as string).trim() : '';
      name = field('name'); description = field('description'); starter = field('starter');
      instructions = field('instructions') || field('prompt');
      keywords = Array.isArray(row['keywords']) ? (row['keywords'] as Object[]).map((k: Object): string => String(k)).slice(0, 12) : [];
    } catch (_error) { return null; }
  } else if (raw.startsWith('---')) {
    const end: number = raw.indexOf('\n---', 3);
    if (end < 0) { return null; }
    const fields: Map<string, string> = frontMatter(raw.slice(3, end));
    name = fields.get('name') ?? '';
    description = fields.get('description') ?? '';
    starter = fields.get('starter') ?? '';
    keywords = listOf(fields.get('keywords') ?? '');
    instructions = raw.slice(end + 4).trim();
  } else {
    instructions = raw;
  }
  if (name === '') { name = fileName.replace(/\.[a-zA-Z0-9]+$/, '').replace(/^skill[-_ ]?/i, '').trim(); }
  if (name === '' || instructions === '') { return null; }
  return new AiSkill(id, name.slice(0, 20), description.slice(0, 80), instructions.slice(0, 4000), starter.slice(0, 200),
    keywords, 'file');
}

/** What the chat shows while a tool runs. */
export function aiToolStatus(fn: string, detail: string): string {
  if (fn === 'create_document') { return detail !== '' ? '正在生成《' + detail + '》' : '正在生成文档'; }
  if (fn === 'read_attachment') { return detail !== '' ? '正在继续阅读《' + detail + '》' : '正在继续阅读文档'; }
  if (fn === 'list_hosts') { return '正在查看主机列表'; }
  if (fn === 'connection_history') { return '正在翻看连接记录'; }
  if (fn === 'app_settings') { return '正在查看应用设置'; }
  if (fn === 'ai_usage') { return '正在统计 AI 用量'; }
  return '正在调用工具';
}

/**
 * Lines to rotate while waiting for an answer, after what the question is about (the first one says what is being
 * read, when documents came with it).
 */
export function aiThinkingPhrases(question: string, newDocuments: string[]): string[] {
  const q: string = question.toLowerCase();
  const lines: string[] = [];
  if (newDocuments.length === 1) { lines.push('正在阅读《' + newDocuments[0] + '》'); }
  else if (newDocuments.length > 1) { lines.push('正在阅读 ' + newDocuments.length.toString() + ' 份文档'); }
  if (/翻译|译成|英文|中文/.test(q)) { lines.push('正在逐句翻译', '正在核对术语', '正在调整语序'); }
  else if (/总结|摘要|概括|要点/.test(q)) { lines.push('正在提炼要点', '正在梳理结构', '正在归纳结论'); }
  else if (/周报|日报|报告|纪要|汇报/.test(q)) { lines.push('正在整理素材', '正在搭建结构', '正在补充细节'); }
  else if (/表格|excel|统计/.test(q)) { lines.push('正在整理数据', '正在设计表头', '正在填写表格'); }
  else if (/润色|改写|修改/.test(q)) { lines.push('正在推敲措辞', '正在调整语气', '正在通读全文'); }
  else if (/写|起草|草拟|邮件|文案/.test(q)) { lines.push('正在构思', '正在组织结构', '正在推敲措辞'); }
  else if (/代码|命令|脚本/.test(q)) { lines.push('正在读代码', '正在分析逻辑', '正在检查风险'); }
  else { lines.push('正在理解你的问题', '正在思考', '正在组织回答'); }
  lines.push('快好了，正在整理回答');
  return lines;
}
