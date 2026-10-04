import { diagnosticAiAppActionCatalog } from './DiagnosticAiAppActionPolicy';
import { diagnosticAiSettingCatalog } from './DiagnosticAiSettingsActionPolicy';

/**
 * RemoteDesktop AI 助手的本地知识基线。
 *
 * 这里放的是可以随应用版本一起审查的使用、隐私和安全说明；它不是远端可执行工具，
 * 也不包含密码、主机地址、日志原文或用户资料。后续可以按版本拆成独立文档资源，
 * 但 Agent 必须始终带上知识版本，避免模型把过期操作当成当前 UI。
 */
export const DIAGNOSTIC_AI_KNOWLEDGE_VERSION: string = 'RemoteDesktop-help-2026-10-04-v6';

/**
 * What the AI itself can do and where things are (1.2.0). Shared by 助理 (with the catalogs below) and by 聊天 and
 * AI 语音 (in their system prompt), so every mode describes the same app.
 */
const AI_GUIDE: string[] = [
  'AI 模式：聊天（通用助手，带工具：写作翻译、读文档、生成和修改 Word/Excel、提醒日程、联网搜索、改设置、管理主机等）；助理（专管 RemoteDesktop 的连接、设置、诊断、抓日志和问题反馈）。两者按问题自动转交：诊断和问题反馈去助理，其余在聊天。',
  'AI 语音（Beta，设置 → AI 语音 打开）：像 Siri 一样说话，回答时可随时插话打断，连续对话；朗读可选系统或云端音色，识别可选本机或云端（阿里云百炼）。',
  '模式切换：说或输入“回到文字”“切到语音模式”“切到助理/聊天”“缩成悬浮球”即可切换；说“拜拜”“再见”“退出”“就这样吧”会直接关闭 AI。',
  '悬浮球：AI 可以缩成悬浮球停在屏幕上；主页上单击回到对话、双击打开小对话框、长按说话（开启按住说话时）。',
  '连接中的 AI：RDP、RustDesk、VNC、Moonlight 的侧栏和 SSH 的「更多」里有 AI 入口，以悬浮球加文字小对话框出现；单击悬浮球退出 AI，双击进入语音模式，长按拖动，会自动避开侧栏，横竖屏都适配。',
  'PC 大屏：AI 按钮在左下角，和固定的「+」并排。',
  'AI 能管理的数据：它生成的文档（列出、读取、改写、删除）、提醒（设置、列出、取消）、记忆（记住、改写、忘掉）、对话记录（列出、删除）、主机（列出、连接、编辑、删除）；删除和会改动数据的操作都先给确认卡片。',
  '需求收集：用户提出新功能或改进想法时，AI 会记下来；用户说想要这些功能或“把需求发给开发者”时，整理成邮件，确认后在邮件应用里发送。',
  '反馈邮件：诊断邮件分为问题概述、初步诊断、详细诊断、建议步骤、尚未确认，诊断日志作为附件（不贴进正文）；邮件只在用户的邮件应用里打开，由用户检查后发送。',
  'Pro：1.2.0 起所有用户免费试用全部已开发的 Pro 功能（AI 助理、工作区、高级主机管理、远端显示方案、个性化、同账号接续等），正式收费前会在应用内提前通知；碰一碰两项仍在验证，暂不开放。'
];

/** The short app guide for 聊天 and AI 语音 (their tools read settings, hosts and actions live). */
export function aiAppGuide(): string {
  return AI_GUIDE.join('\n');
}

/** Built per request: the settings catalog carries live values. */
function knowledge(): string {
  return [
    '产品：RemoteDesktop 是 HarmonyOS 的 RDP、RustDesk、SSH/SFTP、VNC、Moonlight 客户端。',
    '主机：主机列表底部“+”添加连接；按用途选择协议，保存后点击主机卡片连接。',
    'RDP：Windows 远程桌面；连接问题先检查远端服务、地址端口、凭据、证书和网络/VPN。',
    'RustDesk：跨平台远程协助；连接问题先检查 ID/中继、被控端批准、网络和中继配置。',
    'SSH/SFTP：终端和文件传输；先核对主机指纹、认证方式、密钥/密码和 SFTP 目录权限。',
    'VNC：兼容型远程桌面；先核对服务端地址、端口、认证、TLS/Gateway 和画面缩放。',
    'Moonlight：低延迟串流；先确认主机串流服务、配对码、网络可达和应用是否允许启动。',
    '会话：顶部或贴边控制栏可打开键盘、组合键、显示、画质、文件和输入设置；手机支持触控板手势。',
    '设置：设置页包含外观、显示与交互、协议、云同步、安全、教程、反馈和“AI 助理”（AI 配置、AI 助手、用量、个性化、AI 动效和传统日志抓取）。',
    'AI：AI 助手可以回答应用使用问题、提出安全设置建议、组织脱敏诊断、生成开发者邮件草稿；不会直接执行任意命令。',
    ...AI_GUIDE,
    '设置操作：用户想改设置时，给出设置目录里的 settingProposals；应用把每条显示成一键应用的按钮（多条时有“全部应用”），点按后立即生效并保存，每条都能撤销。密码、密钥、Token、地址、代理、VPN、证书/TLS、账号和付款不在目录内，只能引导用户到对应页面。',
    '诊断：需要日志时，AI 按问题选择日志子模块、时长和复现步骤（capturePlan），用户可增删子模块，点“开始抓取”后才抓取结构化脱敏事件；到时或点“结束并分析”后自动分析，只把所选子模块的事件交给 AI；可取消；不会读取 raw hilog、屏幕、音频、剪贴板、终端正文、文件内容或凭据。',
    '邮件：诊断结论先预览（结构见“反馈邮件”），诊断日志写成附件，用户确认后打开系统邮件；应用不会自动发送。',
    '会话：完成问答后会在本机按账号保存最近 50 个会话；配置页可以恢复会话、查看 Token/费用估算并调整助手名称、语气和本地偏好。',
    '失败恢复：Provider 请求失败或页面重建时，完整脱敏诊断包会保留；启动 AI 辅助后可选择重试分析或丢弃。',
    '动作：AI 只能返回动作目录中的 typed appActions；普通设置导航使用 execute 执行胶囊，日志和长任务使用 floating 悬浮球，远程会话轻量开关使用 inline 原地执行；敏感动作必须确认。',
    '入口：主机列表标题栏（PC 在左下角）、设置和各协议连接的侧栏里都有 AI 入口；抓取或思考时会变成不遮挡内容的浮动胶囊。',
    '隐私：Provider API Key 只保存在本机安全存储；不进入日志、云同步、备份、导出或邮件。外发前显示数据范围、Provider、模型和地区。',
    'Pro：AI 配置、AI 助手、设置建议和诊断分析属于 Pro（1.2.0 免费试用期间全部开放）；传统脱敏日志保留独立入口。账号切换会取消请求并清理内存秘密。',
    '回答约束：先给直接答案，再给操作步骤；不确定时明确说明；不捏造设备、网络、Provider、付款或邮件发送结果。',
    '动作目录（只能从这里选择 appActions；mode=execute 执行后回到卡片，mode=floating 进入悬浮球，mode=inline 留在当前卡片；confirm 必须先让用户确认）：\n' +
      diagnosticAiAppActionCatalog(),
    '设置目录（ID|名称|取值=显示名|当前=实际值|说明；proposedValue 只能用取值）：\n' +
      diagnosticAiSettingCatalog()
  ].join('\n');
}

export function diagnosticAiKnowledgeSnapshot(): string {
  return '知识版本：' + DIAGNOSTIC_AI_KNOWLEDGE_VERSION + '\n' + knowledge();
}
