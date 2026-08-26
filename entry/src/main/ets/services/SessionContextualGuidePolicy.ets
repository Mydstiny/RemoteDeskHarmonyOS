import { GuideDevice } from './GuideContentRegistry';
import {
  MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY,
  shouldPresentAutomaticGuide,
  SSH_CONTEXTUAL_GUIDE_STORAGE_KEY
} from './GuideVisibilityPolicy';

export type SessionContextualGuideSurface = 'ssh' | 'moonlight';

export interface SessionContextualGuide {
  storageKey: string;
  message: string;
  durationMs: number;
}

export function shouldShowSessionContextualGuide(ready: boolean, alreadyShown: boolean,
  blockingOverlayVisible: boolean, alwaysVisible: boolean = false,
  shownThisSession: boolean = false): boolean {
  return ready && !blockingOverlayVisible &&
    shouldPresentAutomaticGuide(alreadyShown, alwaysVisible, shownThisSession);
}

export function shouldRetrySessionContextualGuide(ready: boolean,
  alreadyShown: boolean, alwaysVisible: boolean = false,
  shownThisSession: boolean = false): boolean {
  return ready && shouldPresentAutomaticGuide(
    alreadyShown, alwaysVisible, shownThisSession);
}

export function sessionContextualGuide(surface: SessionContextualGuideSurface,
  device: GuideDevice): SessionContextualGuide {
  if (surface === 'ssh') {
    if (device === 'phone') {
      return {
        storageKey: SSH_CONTEXTUAL_GUIDE_STORAGE_KEY,
        message: '已连接：点终端输入区唤起键盘；从“会话工具”打开 SFTP、隧道和更多功能。',
        durationMs: 3200
      };
    }
    return {
      storageKey: SSH_CONTEXTUAL_GUIDE_STORAGE_KEY,
      message: '已连接：顶部工具可打开分屏、SFTP、搜索、命令与日志；主机可从标签切换。',
      durationMs: 3200
    };
  }
  if (device === 'desktop') {
    return {
      storageKey: MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY,
      message: '串流已就绪：从顶部工具栏打开键盘、手柄、画面与断开；先在会话内安全退出。',
      durationMs: 3400
    };
  }
  return {
    storageKey: MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY,
    message: '串流已就绪：点顶部或贴边工具栏打开控制中心、键盘、虚拟手柄与画中画。',
    durationMs: 3400
  };
}
