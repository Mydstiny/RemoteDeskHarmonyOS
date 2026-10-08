import { abilityAccessCtrl, common, Permissions, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { batteryInfo, BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { calendarManager } from '@kit.CalendarKit';
import { camera } from '@kit.CameraKit';
import { contact } from '@kit.ContactsKit';
import { geoLocationManager } from '@kit.LocationKit';
import { connection } from '@kit.NetworkKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { call } from '@kit.TelephonyKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiDocument, aiDeleteDocument, aiRecognizeImageFile } from './AiDocumentService';
import { DiagnosticAiConversationStore } from './DiagnosticAiConversationStore';
import { AI_DEVELOPER_EMAIL, AiMailDraft, aiOpenMailEditor } from './AiMailService';
import { diagnosticAiAppActionId, diagnosticAiAppActionTarget } from './DiagnosticAiAppActionPolicy';
import { AI_APP_ACTION_REQUEST } from './AiBridgeKeys';
import { DiagnosticAiHostBridge } from './DiagnosticAiTriagePolicy';
import { diagnosticAiApplySetting, diagnosticAiSettingActionText, diagnosticAiSettingCurrent, diagnosticAiSettingValueLabel } from './DiagnosticAiSettingsActionPolicy';

/**
 * 系统能力 for the AI chat. Read-only tools and tools that open a system screen the user confirms in (the calendar's
 * own new-event page, the contacts' own new-contact page, the photo and contact pickers) run at once; anything that
 * acts or leaves the app — a reminder, a call, a mail, a route, a web page — becomes an action card in the chat and
 * runs only when the user taps 确认. Permissions are asked for when a tool first needs them.
 */

/** An action the AI proposed, waiting for the user's tap. */
export class AiChatAction {
  id: string;
  /** The tool's function name (set_reminder, call_phone, send_email, navigate, open_link). */
  tool: string;
  title: string;
  detail: string;
  /** The tool's arguments, as JSON text. */
  args: string;
  /** pending · done · failed · cancelled */
  status: string;
  result: string;

  constructor(id: string, tool: string, title: string, detail: string, args: string) {
    this.id = id;
    this.tool = tool;
    this.title = title;
    this.detail = detail;
    this.args = args;
    this.status = 'pending';
    this.result = '';
  }
}

/** The functions that wait for the user's 确认. */
export const AI_CONFIRM_TOOLS: string[] = ['set_reminder', 'cancel_reminder', 'call_phone', 'send_email', 'navigate',
  'open_link'];

function field(input: Record<string, Object>, key: string): string {
  const value: Object | undefined = input[key];
  return typeof value === 'string' ? (value as string).trim() : typeof value === 'number' ? (value as number).toString() : '';
}

function pad(value: number): string { return (value < 10 ? '0' : '') + value.toString(); }

function timeText(time: number): string {
  const d: Date = new Date(time);
  return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 周' + '日一二三四五六'.charAt(d.getDay()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes());
}

/** "2026-10-04 15:30" (or "2026/10/04 15:30", or a date alone) as local time; NaN when it is not a time. */
export function aiParseLocalTime(value: string): number {
  const m: RegExpMatchArray | null = value.trim().match(/^(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?(?:[ T]+(\d{1,2})[:：](\d{2}))?/);
  if (m === null) { return NaN; }
  const date: Date = new Date(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10),
    m[4] !== undefined ? parseInt(m[4], 10) : 9, m[5] !== undefined ? parseInt(m[5], 10) : 0, 0, 0);
  return date.getTime();
}

function maskNumber(number: string): string {
  const digits: string = number.replace(/[^\d+]/g, '');
  return digits.length > 7 ? digits.slice(0, 3) + '****' + digits.slice(-4) : digits;
}

/** Ask for a permission when it is not granted yet; a refused one goes to the settings dialog once. */
export async function aiEnsurePermission(context: common.UIAbilityContext, permission: Permissions): Promise<boolean> {
  const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  try {
    const token: number = context.applicationInfo.accessTokenId;
    if (manager.checkAccessTokenSync(token, permission) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { return true; }
    const result = await manager.requestPermissionsFromUser(context, [permission]);
    if (result.authResults.length > 0 && result.authResults[0] === 0) { return true; }
    const again: abilityAccessCtrl.GrantStatus[] = await manager.requestPermissionOnSetting(context, [permission]);
    return again.length > 0 && again[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (error) {
    hilog.warn(0x0000, 'AiTools', 'permission %{public}s failed %{public}s', permission, String((error as BusinessError).code));
    return false;
  }
}

// ------------------------------------------------------------------ tools that run at once

async function readClipboard(context: common.UIAbilityContext): Promise<string> {
  if (!(await aiEnsurePermission(context, 'ohos.permission.READ_PASTEBOARD'))) {
    return '用户没有允许读取剪贴板。请告诉用户：可以在系统设置里允许，或直接把内容粘贴进输入框。';
  }
  const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
  if (!board.hasDataSync()) { return '剪贴板是空的。'; }
  const data: pasteboard.PasteData = await board.getData();
  const text: string = data.getPrimaryText() ?? '';
  return text.trim() === '' ? '剪贴板里没有文字（可能是图片或文件）。' : '剪贴板内容：\n' + text.slice(0, 20000);
}

function copyToClipboard(text: string): string {
  if (text === '') { return '没有要复制的内容。'; }
  pasteboard.getSystemPasteboard().setDataSync(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
  return '已复制到剪贴板（' + text.length.toString() + ' 字）。';
}

function deviceStatus(): string {
  const charging: string = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ? '正在充电' :
    batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL ? '已充满' : '未充电';
  let network: string = '未联网';
  try {
    const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(connection.getDefaultNetSync());
    network = caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0 ? 'Wi-Fi' :
      caps.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0 ? '移动数据' :
      caps.bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0 ? '有线网络' : '已联网';
  } catch (_error) { /* no default network */ }
  return '设备：' + deviceInfo.marketName + '（' + deviceInfo.osFullName + '）\n电量：' + batteryInfo.batterySOC.toString() + '%，' +
    charging + '\n网络：' + network + '\n现在：' + timeText(Date.now());
}

async function location(context: common.UIAbilityContext): Promise<string> {
  if (!geoLocationManager.isLocationEnabled()) { return '系统定位已关闭，请提醒用户在控制中心打开“位置”。'; }
  if (!(await aiEnsurePermission(context, 'ohos.permission.APPROXIMATELY_LOCATION'))) { return '用户没有允许获取位置。'; }
  const request: geoLocationManager.SingleLocationRequest = {
    locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED, locatingTimeoutMs: 8000
  };
  const here: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
  try {
    const reverse: geoLocationManager.ReverseGeoCodeRequest = {
      latitude: here.latitude, longitude: here.longitude, maxItems: 1, locale: 'zh'
    };
    const places: geoLocationManager.GeoAddress[] = await geoLocationManager.getAddressesFromLocation(reverse);
    if (places.length > 0) {
      const p: geoLocationManager.GeoAddress = places[0];
      // Down to the road, never the house number (placeName): the AI needs the area, not the doorstep.
      return '用户大致在：' + [p.administrativeArea, p.locality, p.subLocality, p.roadName]
        .filter((part: string | undefined): boolean => part !== undefined && part !== '').join(' ') + ' 一带';
    }
  } catch (_error) { /* no geocoder: coordinates only */ }
  return '用户大致坐标：纬度 ' + here.latitude.toFixed(2) + '，经度 ' + here.longitude.toFixed(2);
}

async function readCalendar(context: common.UIAbilityContext, days: number): Promise<string> {
  if (!(await aiEnsurePermission(context, 'ohos.permission.READ_CALENDAR'))) { return '用户没有允许读取日历。'; }
  const start: Date = new Date();
  start.setHours(0, 0, 0, 0);
  const end: number = start.getTime() + Math.max(1, Math.min(31, days)) * 24 * 3600 * 1000;
  // READ_CALENDAR shows only the calendars this app made; the user's own calendars need READ_WHOLE_CALENDAR (an ACL
  // permission not granted yet), so say plainly what was read rather than "you have nothing on".
  let whole: boolean = false;
  try {
    whole = abilityAccessCtrl.createAtManager().checkAccessTokenSync(context.applicationInfo.accessTokenId,
      'ohos.permission.READ_WHOLE_CALENDAR') === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (_error) { /* not declared */ }
  const scope: string = whole ? '（本机全部日历）' : '（只读到了本应用自己的日历：读取系统日历和其他账号的日程需要的权限还在等华为审批，用户现在也没法在设置里打开，不要让用户去设置里授权）';
  const calendars: calendarManager.Calendar[] = await calendarManager.getCalendarManager(context).getAllCalendars();
  const filter: calendarManager.EventFilter = calendarManager.EventFilter.filterByTime(start.getTime(), end);
  const events: calendarManager.Event[] = [];
  for (const calendar of calendars) {
    try {
      (await calendar.getEvents(filter)).forEach((e: calendarManager.Event): void => { events.push(e); });
    } catch (_error) { /* a calendar it cannot read */ }
  }
  if (events.length === 0) {
    return whole ? '这段时间（' + days.toString() + ' 天内）日历里没有日程。' :
      '读不到用户的日程' + scope + '。不要说用户没有安排；请用户自己看系统日历，或告诉你要加什么日程。';
  }
  return events.sort((a: calendarManager.Event, b: calendarManager.Event): number => a.startTime - b.startTime).slice(0, 60)
    .map((e: calendarManager.Event): string => (e.isAllDay === true ? timeText(e.startTime).replace(/ \d\d:\d\d$/, ' 全天') :
      timeText(e.startTime) + '–' + pad(new Date(e.endTime).getHours()) + ':' + pad(new Date(e.endTime).getMinutes())) + ' ' +
      (e.title ?? '（无标题）') + (e.location !== undefined && e.location.location !== undefined && e.location.location !== '' ?
        ' @' + e.location.location : '')).join('\n') + '\n' + scope;
}

/** The calendar's own new-event page, filled in: the user saves it there (no calendar permission needed). */
async function addCalendarEvent(context: common.UIAbilityContext, input: Record<string, Object>): Promise<string> {
  const title: string = field(input, 'title');
  const start: number = aiParseLocalTime(field(input, 'start'));
  if (title === '' || isNaN(start)) { return '缺少标题或开始时间（格式 YYYY-MM-DD HH:mm）。'; }
  const endValue: number = aiParseLocalTime(field(input, 'end'));
  const allDay: boolean = input['allDay'] === true;
  const event: calendarManager.Event = {
    type: calendarManager.EventType.NORMAL, title: title, startTime: start,
    endTime: !isNaN(endValue) && endValue > start ? endValue : start + (allDay ? 24 : 1) * 3600 * 1000,
    isAllDay: allDay, description: field(input, 'notes'), reminderTime: [15]
  };
  if (field(input, 'location') !== '') { event.location = { location: field(input, 'location') }; }
  const id: number = await calendarManager.getCalendarManager(context).editEvent(event);
  return id > 0 ? '用户已在系统日历里保存日程「' + title + '」（' + timeText(start) + '）。' : '用户没有保存这个日程。';
}

async function pickContact(): Promise<string> {
  const picked: contact.Contact[] = await contact.selectContacts({ isMultiSelect: false });
  if (picked.length === 0) { return '用户没有选择联系人。'; }
  const c: contact.Contact = picked[0];
  const phones: string[] = (c.phoneNumbers ?? []).map((p: contact.PhoneNumber): string => p.phoneNumber).slice(0, 3);
  const mails: string[] = (c.emails ?? []).map((e: contact.Email): string => e.email).slice(0, 3);
  return '用户选择了：' + (c.name?.fullName ?? '（无姓名）') + (phones.length > 0 ? '，电话 ' + phones.join('、') : '') +
    (mails.length > 0 ? '，邮箱 ' + mails.join('、') : '');
}

/** The contacts' own new-contact page, filled in. */
async function addContact(context: common.UIAbilityContext, input: Record<string, Object>): Promise<string> {
  const name: string = field(input, 'name');
  if (name === '') { return '缺少联系人姓名。'; }
  const person: contact.Contact = { name: { fullName: name } };
  if (field(input, 'phone') !== '') { person.phoneNumbers = [{ phoneNumber: field(input, 'phone') }]; }
  if (field(input, 'email') !== '') { person.emails = [{ email: field(input, 'email') }]; }
  if (field(input, 'company') !== '') { person.organization = { name: field(input, 'company') }; }
  const id: number = await contact.addContactViaUI(context, person);
  return id > 0 ? '用户已保存联系人「' + name + '」。' : '用户没有保存这个联系人。';
}

function flashlight(context: common.UIAbilityContext, on: boolean): string {
  const manager: camera.CameraManager = camera.getCameraManager(context);
  if (!manager.isTorchSupported()) { return '这台设备不支持手电筒。'; }
  manager.setTorchMode(on ? camera.TorchMode.ON : camera.TorchMode.OFF);
  return on ? '手电筒已打开。' : '手电筒已关闭。';
}

async function recognizeImage(context: common.UIAbilityContext): Promise<string> {
  const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 1;
  const result: photoAccessHelper.PhotoSelectResult = await new photoAccessHelper.PhotoViewPicker().select(options);
  if (result.photoUris.length === 0) { return '用户没有选择图片。'; }
  const text: string = await aiRecognizeImageFile(result.photoUris[0]);
  return text.trim() === '' ? '图片里没有识别到文字。' : '图片中的文字：\n' + text.slice(0, 20000);
}

/** Tools that do not wait for 确认; their result goes straight back to the model. */
/** The system share sheet with some text (the user picks the app). */
async function shareText(context: common.UIAbilityContext, text: string, title: string): Promise<string> {
  if (text.trim() === '') { return '没有分享：内容为空。'; }
  const record: systemShare.SharedRecord = { utd: 'general.plain-text', content: text.slice(0, 20000) };
  if (title !== '') { record.title = title.slice(0, 60); }
  const controller: systemShare.ShareController = new systemShare.ShareController(new systemShare.SharedData(record));
  await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL, selectionMode: systemShare.SelectionMode.SINGLE });
  return '已打开系统分享面板，由用户选择分享到哪里。';
}

/** System settings pages the AI may open (the user changes things there themselves). */
const SETTINGS_PAGES: string[][] = [['wifi', 'wifi_entry', 'WLAN'], ['bluetooth', 'bluetooth_entry', '蓝牙'],
  ['mobile_network', 'mobile_network_entry', '移动网络'], ['location', 'location_manager_settings', '位置信息'],
  ['app_info', 'application_info_entry', '本应用的应用信息与权限'], ['home', '', '设置首页']];

async function openSystemSettings(context: common.UIAbilityContext, page: string): Promise<string> {
  const entry: string[] = SETTINGS_PAGES.find((p: string[]): boolean => p[0] === page) ?? SETTINGS_PAGES[SETTINGS_PAGES.length - 1];
  const want: Want = { bundleName: 'com.huawei.hmos.settings', abilityName: 'com.huawei.hmos.settings.MainAbility' };
  if (entry[1] !== '') { want.uri = entry[1]; }
  if (entry[0] === 'app_info') {
    const params: Record<string, Object> = {};
    params['pushParams'] = context.abilityInfo.bundleName;
    want.parameters = params;
  }
  await context.startAbility(want);
  return '已打开系统设置的「' + entry[2] + '」页面，请用户在那里自己调整。';
}

/** The reminders this app set that have not gone off yet, with the numbers cancel_reminder takes. */
async function listReminders(): Promise<string> {
  const reminders: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
  if (reminders.length === 0) {
    return '本应用现在没有待触发的提醒。（改用日历设置的提醒在系统日历里，这里看不到。）';
  }
  return '待触发的提醒（编号：内容，时间）：\n' + reminders.slice(0, 30).map((info: reminderAgentManager.ReminderInfo): string => {
    const request: reminderAgentManager.ReminderRequest = info.reminderReq;
    let when: string = '';
    if (request.reminderType === reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR) {
      const t: reminderAgentManager.LocalDateTime = (request as reminderAgentManager.ReminderRequestCalendar).dateTime;
      when = t.year.toString() + '-' + pad(t.month) + '-' + pad(t.day) + ' ' + pad(t.hour) + ':' + pad(t.minute);
    } else if (request.reminderType === reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER) {
      when = '倒计时 ' + Math.round((request as reminderAgentManager.ReminderRequestTimer).triggerTimeInSeconds / 60).toString() +
        ' 分钟（从设置时算起）';
    } else {
      when = '闹钟';
    }
    return info.reminderId.toString() + '：' + (request.title ?? '提醒') + '，' + when;
  }).join('\n');
}

export async function aiRunSystemTool(context: common.UIAbilityContext, fn: string, input: Record<string, Object>): Promise<string> {
  try {
    if (fn === 'list_reminders') { return await listReminders(); }
    if (fn === 'read_clipboard') { return await readClipboard(context); }
    if (fn === 'copy_to_clipboard') { return copyToClipboard(field(input, 'text')); }
    if (fn === 'device_status') { return deviceStatus(); }
    if (fn === 'get_location') { return await location(context); }
    if (fn === 'read_calendar') { return await readCalendar(context, parseInt(field(input, 'days'), 10) || 7); }
    if (fn === 'add_calendar_event') { return await addCalendarEvent(context, input); }
    if (fn === 'pick_contact') { return await pickContact(); }
    if (fn === 'add_contact') { return await addContact(context, input); }
    if (fn === 'flashlight') { return flashlight(context, input['on'] !== false && field(input, 'on') !== 'false'); }
    if (fn === 'share_text') { return await shareText(context, field(input, 'text'), field(input, 'title')); }
    if (fn === 'open_system_settings') { return await openSystemSettings(context, field(input, 'page')); }
    if (fn === 'recognize_image_text') { return await recognizeImage(context); }
  } catch (error) {
    const code: number = (error as BusinessError).code ?? 0;
    hilog.warn(0x0000, 'AiTools', '%{public}s failed code=%{public}s', fn, code.toString());
    return '没有完成（错误 ' + code.toString() + '），可以请用户稍后再试或手动操作。';
  }
  return '没有这个工具：' + fn;
}

// ------------------------------------------------------------------ actions that wait for 确认

/** The card for a proposed action; null when its arguments are not usable (the model is told why). */
export function aiActionFor(id: string, fn: string, input: Record<string, Object>): AiChatAction | string {
  const args: string = JSON.stringify(input);
  if (fn === 'set_reminder') {
    const title: string = field(input, 'title') || '提醒';
    const minutes: number = parseInt(field(input, 'minutes'), 10);
    const at: number = aiParseLocalTime(field(input, 'time'));
    if (!isNaN(minutes) && minutes > 0) {
      return new AiChatAction(id, fn, '提醒：' + title, minutes.toString() + ' 分钟后提醒', args);
    }
    if (isNaN(at) || at <= Date.now()) { return '提醒时间无效或已经过去：time 用 YYYY-MM-DD HH:mm，或用 minutes 表示多少分钟后。'; }
    return new AiChatAction(id, fn, '提醒：' + title, timeText(at), args);
  }
  if (fn === 'cancel_reminder') {
    const reminderId: number = parseInt(field(input, 'id'), 10);
    if (isNaN(reminderId)) { return '缺少提醒编号：先用 list_reminders 查看。'; }
    return new AiChatAction(id, fn, '取消提醒' + (field(input, 'title') !== '' ? '：' + field(input, 'title') : ''),
      '到点不会再弹出', args);
  }
  if (fn === 'call_phone') {
    const number: string = field(input, 'number').replace(/[^\d+]/g, '');
    if (number.length < 3) { return '电话号码无效。'; }
    return new AiChatAction(id, fn, '拨打' + (field(input, 'name') !== '' ? field(input, 'name') : '电话'), maskNumber(number), args);
  }
  if (fn === 'send_email') {
    const subject: string = field(input, 'subject');
    if (subject === '' && field(input, 'body') === '') { return '邮件没有主题和正文。'; }
    const files: Object | undefined = input['attachment_paths'];
    const count: number = Array.isArray(files) ? (files as Object[]).length : 0;
    return new AiChatAction(id, fn, '写邮件：' + (subject !== '' ? subject : '（无主题）'),
      (field(input, 'to') !== '' ? '发给 ' + field(input, 'to') + ' · ' : '') +
        (count > 0 ? '附 ' + count.toString() + ' 个文件 · ' : '') + '在邮件应用里检查后再发送', args);
  }
  if (fn === 'navigate') {
    const place: string = field(input, 'destination');
    if (place === '') { return '缺少目的地。'; }
    return new AiChatAction(id, fn, '导航到 ' + place, '在地图应用里打开', args);
  }
  if (fn === 'open_link') {
    const url: string = field(input, 'url');
    if (!/^https?:\/\//i.test(url)) { return '只能打开 http 或 https 网址。'; }
    return new AiChatAction(id, fn, field(input, 'title') !== '' ? '打开：' + field(input, 'title') : '打开网页', url.slice(0, 80), args);
  }
  return '没有这个操作：' + fn;
}

function errorCode(error: Object): number {
  const code: Object | undefined = (error as Record<string, Object>)['code'];
  return typeof code === 'number' ? code as number : typeof code === 'string' ? parseInt(code as string, 10) || 0 : 0;
}

function errorMessage(error: Object): string {
  if (error instanceof Error && error.message !== '') { return error.message; }
  const message: Object | undefined = (error as Record<string, Object>)['message'];
  return typeof message === 'string' ? message as string : '';
}

/** What went wrong with a confirmed action, in words, with the system's code when it gave one. */
export function aiActionErrorText(error: Object): string {
  const code: number = errorCode(error);
  if (code === 201) { return '没有权限（201），请在设置里允许后再试'; }
  if (code === 1700001) { return '通知被关闭（1700001），请在设置里允许 RemoteDesktop 发送通知'; }
  if (code === 1700002) { return '提醒数量已达上限（1700002），请先清理一些提醒'; }
  if (code === 401) { return '参数无效（401）'; }
  const message: string = errorMessage(error);
  if (code !== 0) { return '系统返回错误 ' + code.toString() + (message !== '' ? '：' + message.slice(0, 40) : ''); }
  return message !== '' ? message.slice(0, 60) : '没有完成，请稍后再试';
}

function wait(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

/** Notifications must be on for a reminder: ask once, and give the system a moment to apply the answer. */
async function ensureNotifications(context: common.UIAbilityContext): Promise<boolean> {
  if (await notificationManager.isNotificationEnabled()) { return true; }
  try { await notificationManager.requestEnableNotification(context); }
  catch (error) { hilog.warn(0x0000, 'AiTools', 'enable notification %{public}s', errorCode(error as Object).toString()); }
  for (let i: number = 0; i < 5; i++) {
    if (await notificationManager.isNotificationEnabled()) { return true; }
    await wait(200);
  }
  return false;
}

async function publish(request: reminderAgentManager.ReminderRequest): Promise<number> {
  try {
    return await reminderAgentManager.publishReminder(request);
  } catch (error) {
    // Right after notifications were allowed the service may not know yet: once more, a moment later.
    if (errorCode(error as Object) !== 1700001) { throw error as Error; }
    await wait(800);
    return await reminderAgentManager.publishReminder(request);
  }
}

/**
 * The system refused a reminder although this app has none (1700002 with zero reminders): agent reminders are not
 * open to the app. From then on reminders go straight to the calendar.
 */
let remindersRefused: boolean = false;

async function setReminder(context: common.UIAbilityContext, input: Record<string, Object>): Promise<string> {
  const title: string = field(input, 'title') || '提醒';
  const minutes: number = parseInt(field(input, 'minutes'), 10);
  const at: number = !isNaN(minutes) && minutes > 0 ? Date.now() + minutes * 60000 : aiParseLocalTime(field(input, 'time'));
  const when: string = !isNaN(minutes) && minutes > 0 ? minutes.toString() + ' 分钟后' : timeText(at);
  try {
    if (remindersRefused) { throw new Error('系统暂不允许本应用设置提醒'); }
    if (!(await ensureNotifications(context))) { throw new Error('通知被关闭，请在设置里允许 RemoteDesktop 发送通知'); }
    if (!isNaN(minutes) && minutes > 0) {
      const timer: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER, triggerTimeInSeconds: minutes * 60,
        title: title, content: field(input, 'notes') || title
      };
      const id: number = await publish(timer);
      hilog.info(0x0000, 'AiTools', 'timer reminder %{public}s', id.toString());
    } else {
      const date: Date = new Date(at);
      const reminder: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(), hour: date.getHours(),
          minute: date.getMinutes(), second: 0 },
        title: title, content: field(input, 'notes') || title
      };
      const id: number = await publish(reminder);
      hilog.info(0x0000, 'AiTools', 'calendar reminder %{public}s', id.toString());
    }
    return '已设置：' + when + '提醒「' + title + '」';
  } catch (error) {
    let why: string = aiActionErrorText(error as Object);
    let mine: number = -1;
    try { mine = (await reminderAgentManager.getValidReminders()).length; } catch (_e) { /* unknown */ }
    if (errorCode(error as Object) === 1700002 && mine === 0) {
      // Not too many reminders: none are allowed to this app.
      remindersRefused = true;
      why = '系统暂不允许本应用设置提醒';
    }
    hilog.warn(0x0000, 'AiTools', 'reminder failed code=%{public}s valid=%{public}s %{public}s',
      errorCode(error as Object).toString(), mine.toString(), why);
    // The system calendar reminds just as well: its new-event page, with an alert at the time.
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL, title: title, startTime: at, endTime: at + 15 * 60000,
      description: field(input, 'notes'), reminderTime: [0]
    };
    const saved: number = await calendarManager.getCalendarManager(context).editEvent(event);
    if (saved > 0) { return remindersRefused ? '已设为日历提醒：' + when : '已改用日历提醒：' + when + '（' + why + '）'; }
    throw new Error('没有保存日历提醒');
  }
}

/** Open the app the system offers for a kind of task ('mail', 'navigation'); throws when there is none. */
async function startByType(context: common.UIAbilityContext, type: string, params: Record<string, Object>): Promise<void> {
  let failed: string = '';
  const callback: common.AbilityStartCallback = {
    onError: (code: number, name: string, message: string): void => {
      failed = code.toString() + ' ' + name + ' ' + message;
      hilog.warn(0x0000, 'AiTools', 'start %{public}s failed %{public}s', type, failed);
    },
    onResult: (_result: common.AbilityResult): void => { /* nothing to read back */ }
  };
  await context.startAbilityByType(type, params, callback);
  if (failed !== '') { throw new Error(failed); }
}

async function sendEmail(context: common.UIAbilityContext, input: Record<string, Object>): Promise<string> {
  const to: string = field(input, 'to');
  const paths: Object | undefined = input['attachment_paths'];
  const attachments: string[] = Array.isArray(paths) ? (paths as Object[]).map((p: Object): string => String(p)) : [];
  const note: string = await aiOpenMailEditor(context, new AiMailDraft(to !== '' ? [to] : [], field(input, 'subject'),
    field(input, 'body'), attachments));
  return '已打开邮件应用' + (attachments.length > 0 ? '（带 ' + attachments.length.toString() + ' 个附件）' : '') +
    (note !== '' ? '。' + note : '');
}

async function navigate(context: common.UIAbilityContext, input: Record<string, Object>): Promise<string> {
  const params: Record<string, Object> = {};
  // 3: place search. The system map panel reads the place from destinationName (searchText alone fails with 401).
  params['sceneType'] = 3;
  params['destinationName'] = field(input, 'destination');
  params['searchText'] = field(input, 'destination');
  await startByType(context, 'navigation', params);
  return '已在地图应用里搜索「' + field(input, 'destination') + '」';
}

/**
 * Run an action the user confirmed; the text says what happened (or throws with why it did not). `owner`: the
 * account whose saved conversations a delete_conversation card removes.
 */
export async function aiRunAction(context: common.UIAbilityContext, action: AiChatAction, owner: string = ''): Promise<string> {
  const input: Record<string, Object> = JSON.parse(action.args) as Record<string, Object>;
  if (action.tool === 'cancel_reminder') {
    await reminderAgentManager.cancelReminder(parseInt(field(input, 'id'), 10));
    return '已取消这个提醒';
  }
  if (action.tool === 'delete_document') {
    const name: string = field(input, 'name');
    if (!aiDeleteDocument(new AiDocument(name, field(input, 'format'), field(input, 'path'), 0, 0))) {
      throw new Error('没有删掉「' + name + '」，可能已经不在了');
    }
    return '已删除「' + name + '」';
  }
  if (action.tool === 'send_feature_requests') {
    const ids: Object | undefined = input['ids'];
    const note: string = await aiOpenMailEditor(context, new AiMailDraft([AI_DEVELOPER_EMAIL], field(input, 'subject'),
      field(input, 'body')));
    // Opened in the mail app: the requests count as sent (the user sends it there).
    if (owner !== '' && Array.isArray(ids)) {
      const store: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
      store.init(context, owner);
      store.markFeatureRequestsSent((ids as Object[]).map((id: Object): string => String(id)), Date.now());
    }
    return '已打开邮件应用，检查后发送即可' + (note !== '' ? '。' + note : '');
  }
  if (action.tool === 'delete_conversation') {
    if (owner === '') { throw new Error('不知道是哪个账号的对话'); }
    const store: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
    store.init(context, owner);
    const sessionId: string = field(input, 'id');
    if (store.session(sessionId) === undefined) { return '这条对话已经不在了'; }
    if (!store.deleteSession(sessionId)) { throw new Error('没有删除成功，请稍后再试'); }
    return '已删除对话「' + field(input, 'title') + '」';
  }
  if (action.tool === 'edit_host') {
    if (!DiagnosticAiHostBridge.edit(field(input, 'host_id'))) { throw new Error('没有找到这台主机，可能已被删除'); }
    return '已打开编辑页，在那里修改后保存';
  }
  if (action.tool === 'delete_host') {
    if (!DiagnosticAiHostBridge.remove(field(input, 'host_id'))) { throw new Error('没有找到这台主机，可能已被删除'); }
    return '已弹出删除确认，在对话框里确认后才会删除';
  }
  if (action.tool === 'set_reminder') {
    if (!(await aiEnsurePermission(context, 'ohos.permission.PUBLISH_AGENT_REMINDER'))) { throw new Error('没有提醒权限'); }
    return await setReminder(context, input);
  }
  if (action.tool === 'call_phone') {
    await call.makeCall(field(input, 'number').replace(/[^\d+]/g, ''));
    return '已打开拨号';
  }
  if (action.tool === 'change_setting') {
    const settingId: string = field(input, 'setting_id');
    const value: string = field(input, 'value');
    if (diagnosticAiSettingCurrent(settingId) === value) {
      return '「' + diagnosticAiSettingActionText(settingId) + '」已经是「' + diagnosticAiSettingValueLabel(settingId, value) + '」';
    }
    if (!diagnosticAiApplySetting(settingId, value)) { throw new Error('设置没有改成功，请到设置里手动修改'); }
    return '已把「' + diagnosticAiSettingActionText(settingId) + '」改为「' + diagnosticAiSettingValueLabel(settingId, value) + '」';
  }
  if (action.tool === 'connect_host') {
    if (!DiagnosticAiHostBridge.connect(field(input, 'host_id'))) { throw new Error('没有找到这台主机，可能已被删除'); }
    return '正在连接';
  }
  if (action.tool === 'open_app_screen') {
    const screen: string = field(input, 'screen');
    const id = diagnosticAiAppActionId(screen);
    if (id === null) { throw new Error('没有这个页面'); }
    AppStorage.setOrCreate(AI_APP_ACTION_REQUEST, id + '@' + Date.now().toString());
    return '已打开「' + diagnosticAiAppActionTarget(id) + '」';
  }
  if (action.tool === 'send_email') { return await sendEmail(context, input); }
  if (action.tool === 'navigate') { return await navigate(context, input); }
  if (action.tool === 'open_link') {
    await context.openLink(field(input, 'url'), { appLinkingOnly: false });
    return '已打开';
  }
  throw new Error('不支持的操作');
}
