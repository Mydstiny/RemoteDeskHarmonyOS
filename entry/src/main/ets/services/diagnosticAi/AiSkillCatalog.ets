import { diagnosticAiAppActionCatalog } from './DiagnosticAiAppActionPolicy';
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

/** The app screens the chat may open, as id=label pairs (the assistant's own catalog, minus in-session actions). */
function appScreens(): string {
  return diagnosticAiAppActionCatalog().split('\n').map((line: string): string[] => line.split('|'))
    .filter((parts: string[]): boolean => parts.length >= 2 && !parts[0].startsWith('session.'))
    .map((parts: string[]): string => parts[0] + '=' + parts[1].replace(/["\\]/g, '')).join('；');
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
  // The documents the AI wrote: listed, read back, rewritten, deleted (deleting waits for 确认).
  new AiToolSpec('documents.list', 'list_documents', '文档列表', '列出 AI 生成过、还在设备上的文档',
    'documents', true, functionJson('list_documents',
      '列出 AI 为用户生成过、仍保存在设备上的文档：名称、格式、大小、生成时间、所在对话。用户提到“之前生成的文档”或要修改、删除文档时先用它查看。',
      '', '')),
  new AiToolSpec('documents.readOwn', 'read_document', '读取生成的文档', '读取 AI 生成过的文档内容，用来回答或修改',
    'documents', true, functionJson('read_document', '读取一份 AI 生成过的文档的正文（Word、Excel 会转成文字）。修改文档前先读出原文。',
      '"name":{"type":"string","description":"文档名称（list_documents 里的名称）"},"offset":{"type":"integer","description":"从第几个字符开始读，默认 0"}',
      '"name"')),
  new AiToolSpec('documents.update', 'update_document', '修改文档', '按你的要求改写已生成的文档（还是同一个文件）',
    'documents', true, functionJson('update_document',
      '改写一份 AI 生成过的文档：用新的完整正文覆盖原文件（文件名和格式不变，对话里的文档卡片打开的就是新内容）。只在用户要求修改已有文档时使用；要另存一份新文档用 create_document。',
      '"name":{"type":"string","description":"文档名称（list_documents 里的名称）"},' +
      '"content":{"type":"string","description":"修改后的完整正文，格式要求同 create_document"}', '"name","content"')),
  new AiToolSpec('documents.delete', 'delete_document', '删除文档', '删除 AI 生成的文档；先显示确认卡片',
    'documents', true, functionJson('delete_document', '删除一份 AI 生成过的文档（从设备上删掉文件）。会先显示确认卡片，用户确认后才删除。要删多份就分别调用。',
      '"name":{"type":"string","description":"文档名称（list_documents 里的名称）"}', '"name"')),
  new AiToolSpec('app.hosts', 'list_hosts', '主机列表', '主机名称、协议、分组、最近连接时间和网络状态；不含地址、账号和密码',
    'app', true, functionJson('list_hosts', '列出用户在 RemoteDesktop 里保存的远程主机：名称、协议、分组、最近连接时间、最近一次网络状态。不含地址和凭据。',
      '"protocol":{"type":"string","description":"只看某种协议：rdp、rustdesk、ssh、vnc、moonlight；留空为全部"}', '')),
  new AiToolSpec('app.connections', 'connection_history', '连接记录', '最近的连接和失败记录：时间、主机名、协议、结果',
    'app', true, functionJson('connection_history', '读取最近若干天在这台设备上的远程连接记录（时间、主机名、协议、成功或失败原因），适合写周报、日报和主机使用总结。',
      '"days":{"type":"integer","description":"最近几天，1 到 45，默认 7"}', '')),
  new AiToolSpec('app.settings', 'app_settings', '应用设置', '当前的连接、显示和 AI 设置（只读，不会修改）',
    'app', true, functionJson('app_settings', '读取 RemoteDesktop 当前的设置项和取值（只读）。', '', '')),
  new AiToolSpec('app.changeSetting', 'change_setting', '修改设置', '按你的要求修改 App 设置，先显示确认卡片，你确认后才生效',
    'app', true, functionJson('change_setting',
      '修改 RemoteDesktop 的一项设置（主题、画质、键盘、AI 动效等）。setting_id 和 value 必须来自 app_settings 返回的清单（每行：id|名称|可选值=说明|当前值）；会先给用户显示确认卡片，用户确认后才生效。',
      '"setting_id":{"type":"string","description":"设置 id，例如 ui.theme"},"value":{"type":"string","description":"可选值里的值，例如 dark、true"}',
      '"setting_id","value"')),
  new AiToolSpec('app.openScreen', 'open_app_screen', '打开页面', '打开 App 里的页面：添加主机、云同步、诊断日志、各类设置',
    'app', true, functionJson('open_app_screen',
      '打开 RemoteDesktop 里的一个页面让用户自己操作（例如添加主机、云同步、某类设置）。会先显示卡片，用户确认后才打开。screen 只能是以下 id 之一：' + appScreens(),
      '"screen":{"type":"string","description":"页面 id"}', '"screen"')),
  new AiToolSpec('app.assistant', 'ask_assistant', '交给助理', '连接诊断、抓取日志、问题反馈交给 AI 助理处理',
    'app', true, functionJson('ask_assistant',
      '把需要 AI 助理处理的事交给它：诊断远程连接问题、抓取和分析诊断日志、生成问题反馈邮件。助理会在“助理”模式里接着处理。question 写清楚用户要什么。',
      '"question":{"type":"string","description":"交给助理的问题，用用户的原话"}', '"question"')),
  new AiToolSpec('app.editHost', 'edit_host', '编辑主机', '打开某台主机的编辑页，由你修改并保存（先显示确认卡片）',
    'app', true, functionJson('edit_host',
      '打开用户一台远程主机的编辑页（改名称、地址、账号、分组等由用户在编辑页里完成并保存；你看不到地址和凭据，不要替用户填写）。会先显示确认卡片。',
      '"name":{"type":"string","description":"主机名称"},"protocol":{"type":"string","enum":["rdp","rustdesk","ssh","vnc","moonlight",""],"description":"协议，可不填"}',
      '"name"')),
  new AiToolSpec('app.deleteHost', 'delete_host', '删除主机', '删除一台保存的主机：先显示确认卡片，再由 App 的删除确认把关',
    'app', true, functionJson('delete_host',
      '删除用户保存的一台远程主机。会先显示确认卡片；用户确认后，App 还会弹出自己的删除确认（加锁的主机需要验证），用户再次确认才删除。',
      '"name":{"type":"string","description":"主机名称"},"protocol":{"type":"string","enum":["rdp","rustdesk","ssh","vnc","moonlight",""],"description":"协议，可不填"}',
      '"name"')),
  new AiToolSpec('app.conversations', 'list_conversations', '对话记录', '列出保存的聊天和助理对话',
    'app', true, functionJson('list_conversations', '列出这个账号保存的 AI 对话记录（聊天和助理）：标题、类型、最后更新时间、轮数、生成的文档数。', '', '')),
  new AiToolSpec('app.deleteConversation', 'delete_conversation', '删除对话', '删除保存的对话记录；先显示确认卡片',
    'app', true, functionJson('delete_conversation',
      '删除一条保存的对话记录（不能删除正在进行的这段对话）。会先显示确认卡片。title 用 list_conversations 里的标题；要删多条就分别调用。对话里生成的文档不会一起删除，需要时另用 delete_document。',
      '"title":{"type":"string","description":"对话标题"}', '"title"')),
  new AiToolSpec('app.memory', 'update_memory', '记忆', '记住、改写或忘掉你让 AI 记住的事',
    'app', true, functionJson('update_memory',
      '修改“用户希望你记住”的内容（AI 个性化设置 › 记忆）。用户说“记住……”“以后……”时 add；说“忘掉/不要记……”时 remove；要改掉某条时 replace（old 为原来的说法）；说“清空记忆”时 clear。只记用户明确要求记住的事，不要记密码、验证码等敏感信息。',
      '"action":{"type":"string","enum":["add","remove","replace","clear"]},"text":{"type":"string","description":"要记住或要忘掉的内容（一句话）"},' +
      '"old":{"type":"string","description":"replace 时，原来记住的那句话"}', '"action"')),
  new AiToolSpec('app.usage', 'ai_usage', 'AI 用量', '最近的 AI 请求次数、Token 和估算费用',
    'app', true, functionJson('ai_usage', '读取最近若干天的 AI 用量：请求次数、Token、估算费用。',
      '"days":{"type":"integer","description":"最近几天，默认 7"}', '')),
  // 系统能力 — read-only ones and system confirm screens run at once; the rest wait for the user's 确认.
  new AiToolSpec('system.clipboard', 'read_clipboard', '读取剪贴板', '读取你刚复制的文字（需要你允许读取剪贴板）',
    'system', true, functionJson('read_clipboard', '读取用户剪贴板里的文字。用户说“刚复制的”“剪贴板里的”内容时使用。', '', '')),
  new AiToolSpec('system.copy', 'copy_to_clipboard', '复制到剪贴板', '把译文、地址等结果直接复制好',
    'system', true, functionJson('copy_to_clipboard', '把一段文字复制到用户剪贴板，方便粘贴到其他应用。',
      '"text":{"type":"string","description":"要复制的文字"}', '"text"')),
  new AiToolSpec('system.device', 'device_status', '设备状态', '电量、是否充电、网络类型、机型和当前时间',
    'system', true, functionJson('device_status', '读取设备状态：电量、充电、网络类型、机型、系统版本和当前时间。', '', '')),
  new AiToolSpec('system.location', 'get_location', '大致位置', '你所在的城市和区（需要你允许获取位置）',
    'system', true, functionJson('get_location', '获取用户当前大致位置（城市、区、道路）。只在用户问附近、路线、当地相关的问题时使用。', '', '')),
  new AiToolSpec('system.calendar.read', 'read_calendar', '读取日程', '查看本机日历里接下来的日程（需要你允许读取日历）',
    'system', true, functionJson('read_calendar', '读取本机日历中从今天开始若干天的日程（目前可能只读得到本应用的日历，结果会说明读到的范围；读不到时不要断言用户没有安排）。',
      '"days":{"type":"integer","description":"从今天起多少天，1 到 31，默认 7"}', '')),
  new AiToolSpec('system.calendar.add', 'add_calendar_event', '添加日程', '在系统日历的新建页填好日程，由你点保存',
    'system', true, functionJson('add_calendar_event', '打开系统日历的新建日程页面并填好内容，用户在系统页面里保存。',
      '"title":{"type":"string","description":"日程标题"},"start":{"type":"string","description":"开始时间 YYYY-MM-DD HH:mm（本地时间）"},' +
      '"end":{"type":"string","description":"结束时间 YYYY-MM-DD HH:mm，可省略"},"location":{"type":"string"},"notes":{"type":"string"},' +
      '"allDay":{"type":"boolean"}', '"title","start"')),
  new AiToolSpec('system.reminder', 'set_reminder', '定时提醒', '到点弹出提醒；先显示确认卡片，你点确认才设置',
    'system', true, functionJson('set_reminder', '设置一个提醒。会先在对话里显示确认卡片，用户确认后才设置。',
      '"title":{"type":"string","description":"提醒内容"},"time":{"type":"string","description":"提醒时间 YYYY-MM-DD HH:mm（本地时间）"},' +
      '"minutes":{"type":"integer","description":"或者多少分钟后提醒"},"notes":{"type":"string"}', '"title"')),
  new AiToolSpec('system.reminder.list', 'list_reminders', '查看提醒', '列出 AI 设置的、还没到点的提醒',
    'system', true, functionJson('list_reminders', '列出本应用设置的、还没有触发的提醒（编号、内容、时间）。用户问“我有哪些提醒”或要取消提醒时先用它查看。', '', '')),
  new AiToolSpec('system.reminder.cancel', 'cancel_reminder', '取消提醒', '取消一个提醒；先显示确认卡片',
    'system', true, functionJson('cancel_reminder', '取消一个本应用设置的提醒。会先显示确认卡片。id 用 list_reminders 返回的编号。',
      '"id":{"type":"integer","description":"提醒编号"},"title":{"type":"string","description":"提醒内容（卡片上显示）"}', '"id"')),
  new AiToolSpec('system.contact.pick', 'pick_contact', '选择联系人', '弹出通讯录让你选一个人，AI 只拿到你选的那一个',
    'system', true, functionJson('pick_contact', '弹出系统通讯录让用户选择一个联系人，返回姓名、电话和邮箱。需要某人的电话或邮箱时使用。', '', '')),
  new AiToolSpec('system.contact.add', 'add_contact', '新建联系人', '在系统通讯录的新建页填好信息，由你点保存',
    'system', true, functionJson('add_contact', '打开系统新建联系人页面并填好信息，用户在系统页面里保存。',
      '"name":{"type":"string"},"phone":{"type":"string"},"email":{"type":"string"},"company":{"type":"string"}', '"name"')),
  new AiToolSpec('system.call', 'call_phone', '打电话', '先显示确认卡片，确认后打开拨号',
    'system', true, functionJson('call_phone', '给某个号码打电话。会先显示确认卡片，用户确认后打开拨号界面。',
      '"number":{"type":"string","description":"电话号码"},"name":{"type":"string","description":"对方称呼"}', '"number"')),
  new AiToolSpec('system.mail', 'send_email', '写邮件', '在邮件应用里写好邮件，由你检查后发送',
    'system', true, functionJson('send_email', '在邮件应用里写好一封邮件（收件人、主题、正文），用户检查后自己发送。会先显示确认卡片。',
      '"to":{"type":"string","description":"收件人邮箱，可省略"},"subject":{"type":"string"},"body":{"type":"string"}', '"subject","body"')),
  new AiToolSpec('system.navigate', 'navigate', '导航', '在地图应用里搜索目的地；先显示确认卡片',
    'system', true, functionJson('navigate', '在地图应用里搜索并导航到一个地点。会先显示确认卡片。',
      '"destination":{"type":"string","description":"目的地名称或地址"}', '"destination"')),
  new AiToolSpec('system.link', 'open_link', '打开网页', '用浏览器打开网址；先显示确认卡片',
    'system', true, functionJson('open_link', '用浏览器打开一个网址。会先显示确认卡片。',
      '"url":{"type":"string","description":"http 或 https 网址"},"title":{"type":"string"}', '"url"')),
  new AiToolSpec('system.flashlight', 'flashlight', '手电筒', '打开或关闭手电筒',
    'system', true, functionJson('flashlight', '打开或关闭手电筒。', '"on":{"type":"boolean","description":"true 打开，false 关闭"}', '"on"')),
  new AiToolSpec('system.ocr', 'recognize_image_text', '识别图片文字', '从相册选一张图片，识别里面的文字（在本机完成）',
    'system', true, functionJson('recognize_image_text', '让用户从相册选择一张图片（截图、照片），在本机识别其中的文字并返回。', '', '')),
  new AiToolSpec('system.share', 'share_text', '分享', '把一段文字交给系统分享面板，发到微信、备忘录等',
    'system', true, functionJson('share_text', '打开系统分享面板分享一段文字（用户在面板里选择分享到哪个应用）。',
      '"text":{"type":"string","description":"要分享的文字"},"title":{"type":"string","description":"标题，可选"}', '"text"')),
  new AiToolSpec('system.settings', 'open_system_settings', '系统设置', '打开 WLAN、蓝牙、移动网络、位置或本应用权限等系统设置页',
    'system', true, functionJson('open_system_settings',
      '打开手机的系统设置页面让用户自己调整（应用不能直接改系统开关）。page：wifi=WLAN，bluetooth=蓝牙，mobile_network=移动网络，location=位置信息，app_info=本应用的信息与权限，home=设置首页。',
      '"page":{"type":"string","enum":["wifi","bluetooth","mobile_network","location","app_info","home"]}', '"page"')),
  new AiToolSpec('app.connect', 'connect_host', '连接主机', '按名字连接你保存的远程主机（先显示确认卡片）',
    'app', true, functionJson('connect_host',
      '连接用户保存的一台远程主机（RDP、RustDesk、SSH、VNC、Moonlight）。name 用主机名称（可先用 list_hosts 查看）；会先显示确认卡片，确认后开始连接。',
      '"name":{"type":"string","description":"主机名称"},"protocol":{"type":"string","enum":["rdp","rustdesk","ssh","vnc","moonlight",""],"description":"协议，可不填"}',
      '"name"')),
  new AiToolSpec('app.float', 'float_orb', '悬浮球', '把 AI 缩成悬浮球停在当前页面上，点一下回到对话',
    'app', true, functionJson('float_orb', '把 AI 对话（或语音模式）缩成悬浮球停在屏幕上，用户可以继续操作 App，点一下悬浮球回到对话。用户说“缩成悬浮球”“进入悬浮球模式”“先收起来”时使用。', '', '')),
  new AiToolSpec('app.mode', 'switch_mode', '切换模式', '回到文字、进入语音模式、在助理和聊天之间切换，或结束对话',
    'app', true, functionJson('switch_mode',
      '切换 AI 的模式或结束对话：text=回到文字聊天，voice=进入语音模式，assistant=切到助理（诊断、日志、反馈、应用设置），chat=切到聊天，orb=缩成悬浮球，exit=关闭 AI（用户说拜拜、退出、就这样吧时）。用户明确要切换或结束时才用。',
      '"mode":{"type":"string","enum":["text","voice","assistant","chat","orb","exit"]}', '"mode"')),
  new AiToolSpec('web.search', 'web_search', '联网搜索', '用必应搜索网络上的最新信息（只发送搜索词）',
    'web', true, functionJson('web_search', '联网搜索最新信息（新闻、价格、天气、营业时间、产品资料等）。返回前几条结果的标题、网址和摘要。',
      '"query":{"type":"string","description":"搜索词"}', '"query"')),
  new AiToolSpec('web.read', 'read_webpage', '读取网页', '读取一个网页的正文，用来回答细节',
    'web', true, functionJson('read_webpage', '读取一个网页的正文（搜索结果里的网址或用户给的网址），用来回答细节问题。',
      '"url":{"type":"string","description":"http(s) 网址"}', '"url"')),
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
  new AiSkill('schedule', '日程安排', '查看日程、安排会议并加到日历',
    '先调用 read_calendar 看用户这几天已有的安排，避开冲突给出建议时间；用户确定后调用 add_calendar_event 打开系统日历填好日程。' +
    '时间用用户本地时间，“明天”“下周三”按今天的日期换算。', '帮我安排一下：', ['日程', '日历', '会议', '安排', '有空'], 'builtin'),
  new AiSkill('remind-me', '提醒我', '到点提醒你做某件事',
    '把用户说的时间换算成具体时间（YYYY-MM-DD HH:mm）或多少分钟后，调用 set_reminder；提醒内容写清楚要做什么。',
    '提醒我', ['提醒', '记得', '别忘了', '闹钟', '分钟后'], 'builtin'),
  new AiSkill('clipboard', '处理剪贴板', '翻译、总结或改写你刚复制的内容',
    '先调用 read_clipboard 读取用户刚复制的内容，再按用户要求处理；结果较短时调用 copy_to_clipboard 复制好，方便用户直接粘贴。',
    '帮我处理刚复制的内容：', ['剪贴板', '刚复制', '复制的'], 'builtin'),
  new AiSkill('trip', '出行', '查位置、规划路线并打开地图',
    '需要时调用 get_location 了解用户大致位置，给出路线和时间建议；用户要去某地时调用 navigate 打开地图。',
    '帮我规划一下怎么去：', ['导航', '怎么去', '路线', '附近', '出行'], 'builtin'),
  new AiSkill('code-explain', '解释代码', '逐段解释代码或命令，并指出风险',
    '先用一句话说明代码/命令做什么，再逐段解释；指出可能的风险（删除数据、权限、安全问题）和改进建议。',
    '帮我解释这段代码：\n', ['代码', '命令', '脚本', '报错是什么意思'], 'builtin')
];

/** Installed when a user has never changed the list. */
export const AI_DEFAULT_SKILLS: string[] = ['weekly-report', 'schedule', 'remind-me', 'clipboard', 'meeting-minutes',
  'doc-summary', 'translator', 'polish', 'excel-table', 'email-writer', 'ppt-outline', 'trip'];

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
  if (fn === 'list_documents') { return '正在查看生成过的文档'; }
  if (fn === 'read_document') { return detail !== '' ? '正在阅读《' + detail + '》' : '正在阅读文档'; }
  if (fn === 'update_document') { return detail !== '' ? '正在修改《' + detail + '》' : '正在修改文档'; }
  if (fn === 'list_conversations') { return '正在查看对话记录'; }
  if (fn === 'update_memory') { return '正在更新记忆'; }
  if (fn === 'list_reminders') { return '正在查看提醒'; }
  if (fn === 'edit_host' || fn === 'delete_host') { return '正在查找主机'; }
  if (fn === 'delete_document' || fn === 'delete_conversation' || fn === 'cancel_reminder') { return '正在准备确认卡片'; }
  if (fn === 'list_hosts') { return '正在查看主机列表'; }
  if (fn === 'connection_history') { return '正在翻看连接记录'; }
  if (fn === 'app_settings') { return '正在查看应用设置'; }
  if (fn === 'ai_usage') { return '正在统计 AI 用量'; }
  if (fn === 'change_setting') { return '正在准备修改设置'; }
  if (fn === 'open_app_screen') { return '正在打开页面'; }
  if (fn === 'ask_assistant') { return '正在交给 AI 助理'; }
  if (fn === 'web_search') { return detail !== '' ? '正在搜索「' + detail + '」' : '正在联网搜索'; }
  if (fn === 'read_webpage') { return '正在阅读网页'; }
  if (fn === 'connect_host') { return '正在查找主机'; }
  if (fn === 'float_orb') { return '正在缩成悬浮球'; }
  if (fn === 'switch_mode') { return '正在切换'; }
  if (fn === 'share_text') { return '正在打开分享'; }
  if (fn === 'open_system_settings') { return '正在打开系统设置'; }
  if (fn === 'read_clipboard') { return '正在读取剪贴板'; }
  if (fn === 'copy_to_clipboard') { return '正在复制到剪贴板'; }
  if (fn === 'device_status') { return '正在查看设备状态'; }
  if (fn === 'get_location') { return '正在定位'; }
  if (fn === 'read_calendar') { return '正在查看日程'; }
  if (fn === 'add_calendar_event') { return '正在打开日历'; }
  if (fn === 'pick_contact') { return '请在通讯录里选择联系人'; }
  if (fn === 'add_contact') { return '正在打开通讯录'; }
  if (fn === 'flashlight') { return '正在操作手电筒'; }
  if (fn === 'recognize_image_text') { return '请选择图片，正在识别文字'; }
  if (fn === 'set_reminder' || fn === 'call_phone' || fn === 'send_email' || fn === 'navigate' || fn === 'open_link') {
    return '正在准备确认卡片';
  }
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
