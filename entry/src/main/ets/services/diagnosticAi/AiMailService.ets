import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';

/** Where the developer reads feedback (设置 › 反馈 uses the same address). */
export const AI_DEVELOPER_EMAIL: string = 'lijiong1219@petalmail.com';

/** Attachments older than this are removed the next time one is written. */
const ATTACHMENT_KEEP_MS: number = 7 * 24 * 3600 * 1000;

/** A mail the AI drafted, for the user to check and send in their mail app. */
export class AiMailDraft {
  to: string[];
  subject: string;
  body: string;
  /** Files in the app's sandbox (absolute paths) to attach. */
  attachments: string[];

  constructor(to: string[], subject: string, body: string, attachments: string[] = []) {
    this.to = to;
    this.subject = subject;
    this.body = body;
    this.attachments = attachments;
  }
}

function pad(value: number): string { return (value < 10 ? '0' : '') + value.toString(); }

/** YYYYMMDD-HHMMSS, for attachment names. */
export function aiMailStamp(time: number): string {
  const d: Date = new Date(time);
  return d.getFullYear().toString() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' + pad(d.getHours()) +
    pad(d.getMinutes()) + pad(d.getSeconds());
}

function exists(path: string): boolean {
  try { return fileIo.accessSync(path); } catch (_error) { return false; }
}

/** Drops attachment folders from earlier mails (each mail has its own folder, named by its time). */
function pruneOld(root: string): void {
  try {
    fileIo.listFileSync(root).forEach((name: string): void => {
      const stamp: number = parseInt(name.split('-')[0], 36);
      if (!isNaN(stamp) && Date.now() - stamp > ATTACHMENT_KEEP_MS) {
        try { fileIo.rmdirSync(root + '/' + name); } catch (_error) { /* removed later */ }
      }
    });
  } catch (_error) { /* nothing there yet */ }
}

/**
 * Writes a text attachment (a diagnostic log, a list of requests…) into the app's own files, under
 * filesDir/ai-mail/<time>/<name>, and returns its path. The name should be ASCII so every mail app shows it right.
 */
export function aiMailAttachment(context: common.Context, name: string, text: string): string {
  const root: string = context.filesDir + '/ai-mail';
  if (!exists(root)) { fileIo.mkdirSync(root, true); }
  pruneOld(root);
  const folder: string = root + '/' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 46656).toString(36);
  fileIo.mkdirSync(folder, true);
  const safe: string = name.replace(/[\\/:*?"<>|\s]+/g, '-').slice(0, 96);
  const path: string = folder + '/' + (safe !== '' ? safe : 'attachment.txt');
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
  finally { fileIo.closeSync(file); }
  hilog.info(0x0000, 'AiChat', 'mail attachment bytes=%{public}s', bytes.length.toString());
  return path;
}

function mailtoUri(draft: AiMailDraft): string {
  return 'mailto:' + draft.to.map((to: string): string => encodeURIComponent(to)).join(',') +
    '?subject=' + encodeURIComponent(draft.subject) + '&body=' + encodeURIComponent(draft.body);
}

function startMailPanel(context: common.UIAbilityContext, params: Record<string, Object>): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
    let failed: string = '';
    const callback: common.AbilityStartCallback = {
      onError: (code: number, name: string, message: string): void => {
        failed = code.toString() + ' ' + name + ' ' + message;
        hilog.warn(0x0000, 'AiChat', 'mail panel failed %{public}s', failed);
      },
      onResult: (_result: common.AbilityResult): void => { /* nothing to read back */ }
    };
    context.startAbilityByType('mail', params, callback, (error: BusinessError): void => {
      if (error || failed !== '') { reject(new Error(error ? String(error.code) : failed)); return; }
      resolve();
    });
  });
}

/**
 * Opens the user's mail app with the draft filled in, for them to check and send — nothing is ever sent from here.
 * Attachments go with the system mail panel or a sendToData request (file URIs with read permission). If neither
 * opens, a mail with attachments goes to the share sheet (text and files; the user picks the mail app there and fills
 * in the recipient, which the returned note names); without attachments a mailto link is enough. Throws when nothing
 * opens.
 */
export async function aiOpenMailEditor(context: common.UIAbilityContext, draft: AiMailDraft): Promise<string> {
  const files: string[] = draft.attachments.filter((path: string): boolean => exists(path));
  const uris: string[] = files.map((path: string): string => fileUri.getUriFromPath(path));
  // 1. The system mail panel: recipients, subject, body and attachments (each value URL-encoded, as it expects).
  try {
    const params: Record<string, Object> = {};
    params['sceneType'] = 1;
    if (draft.to.length > 0) { params['email'] = draft.to.map((to: string): string => encodeURI(to)); }
    params['subject'] = encodeURI(draft.subject);
    params['body'] = encodeURI(draft.body);
    if (uris.length > 0) {
      params[wantConstant.Params.PARAMS_STREAM] = uris.map((uri: string): string => encodeURI(uri));
      params['ability.want.params.uriPermissionFlag'] = wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION;
    }
    await startMailPanel(context, params);
    hilog.info(0x0000, 'AiChat', 'mail opened (panel) attachments=%{public}s', uris.length.toString());
    return '';
  } catch (_error) { /* next way */ }
  // 2. A mail app that takes mailto with the files alongside.
  try {
    const want: Want = { action: 'ohos.want.action.sendToData', uri: mailtoUri(draft) };
    if (uris.length > 0) {
      const parameters: Record<string, Object> = {};
      parameters[wantConstant.Params.PARAMS_STREAM] = uris;
      want.parameters = parameters;
      want.flags = wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION;
    }
    await context.startAbility(want);
    hilog.info(0x0000, 'AiChat', 'mail opened (sendToData) attachments=%{public}s', uris.length.toString());
    return '';
  } catch (_error) { /* next way */ }
  // 3. With attachments: the share sheet carries the files (the sandbox is out of the user's reach otherwise).
  if (uris.length > 0) {
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({ utd: 'general.plain-text',
        content: draft.subject + '\n\n' + draft.body, title: draft.subject });
      files.forEach((path: string, index: number): void => {
        data.addRecord({ utd: path.endsWith('.json') ? 'general.json' : 'general.plain-text', uri: uris[index],
          title: path.slice(path.lastIndexOf('/') + 1) });
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE });
      hilog.info(0x0000, 'AiChat', 'mail handed to the share sheet attachments=%{public}s', uris.length.toString());
      return '没有找到能直接带附件的邮件应用，已打开分享面板：选择邮件应用后，收件人填 ' + draft.to.join('、') + '。';
    } catch (_error) { /* last way */ }
  }
  // 4. Anything that opens mailto: the text only.
  await context.openLink(mailtoUri(draft), { appLinkingOnly: false });
  hilog.info(0x0000, 'AiChat', 'mail opened (mailto) without attachments');
  return uris.length > 0 ? '这个邮件应用没有带上附件，正文已填好。' : '';
}
