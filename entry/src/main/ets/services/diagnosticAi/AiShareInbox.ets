import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';

/** AppStorage key bumped whenever something is shared to the app for the AI chat. */
export const AI_SHARE_REQUEST_KEY: string = 'aiShareRequest';
/** AppStorage key bumped when the chat's memory changed from outside (a share, a resumed chat). */
export const AI_CHAT_REFRESH_KEY: string = 'aiChatRefresh';

/** One shared item: a file (uri) or plain text. */
export class AiSharedItem {
  uri: string;
  name: string;
  text: string;

  constructor(uri: string, name: string, text: string) {
    this.uri = uri;
    this.name = name;
    this.text = text;
  }
}

/**
 * 分享 → RemoteDesktop from WPS, Files or the browser: the shared documents and text wait here until the AI chat
 * opens and reads them. Only what the user shared arrives; the app never goes looking for files itself.
 */
export class AiShareInbox {
  private static items: AiSharedItem[] = [];

  static pending(): boolean { return AiShareInbox.items.length > 0; }

  static take(): AiSharedItem[] {
    const items: AiSharedItem[] = AiShareInbox.items;
    AiShareInbox.items = [];
    return items;
  }

  static push(items: AiSharedItem[]): void {
    if (items.length === 0) { return; }
    AiShareInbox.items = AiShareInbox.items.concat(items).slice(-5);
    AppStorage.setOrCreate<number>(AI_SHARE_REQUEST_KEY, (AppStorage.get<number>(AI_SHARE_REQUEST_KEY) ?? 0) + 1);
  }
}

export function aiChatRefresh(): void {
  AppStorage.setOrCreate<number>(AI_CHAT_REFRESH_KEY, (AppStorage.get<number>(AI_CHAT_REFRESH_KEY) ?? 0) + 1);
}

/** A share sheet Want (ohos.want.action.sendData): its files and text go to the inbox. Returns whether it was one. */
export function aiShareInboxAccept(want: Want): boolean {
  if (want.action !== 'ohos.want.action.sendData') { return false; }
  systemShare.getSharedData(want).then((data: systemShare.SharedData): void => {
    const items: AiSharedItem[] = [];
    data.getRecords().slice(0, 5).forEach((record: systemShare.SharedRecord): void => {
      if (typeof record.uri === 'string' && record.uri !== '') {
        items.push(new AiSharedItem(record.uri, typeof record.title === 'string' ? record.title : '', ''));
      } else if (typeof record.content === 'string' && record.content.trim() !== '') {
        items.push(new AiSharedItem('', typeof record.title === 'string' && record.title !== '' ? record.title : '分享的文字',
          record.content));
      }
    });
    hilog.info(0x0000, 'AiChat', 'shared items=%{public}s', items.length.toString());
    AiShareInbox.push(items);
  }).catch((error: Error): void => {
    hilog.warn(0x0000, 'AiChat', 'shared data unreadable %{public}s', error.message ?? '');
  });
  return true;
}
