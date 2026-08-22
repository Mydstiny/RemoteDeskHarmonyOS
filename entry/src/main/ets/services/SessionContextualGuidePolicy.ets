import { GuideDevice } from './GuideContentRegistry';

export type SessionContextualGuideSurface = 'ssh' | 'moonlight';

export interface SessionContextualGuide {
  storageKey: string;
  message: string;
  durationMs: number;
}

export function shouldShowSessionContextualGuide(ready: boolean, alreadyShown: boolean,
  blockingOverlayVisible: boolean): boolean {
  return ready && !alreadyShown && !blockingOverlayVisible;
}

export function sessionContextualGuide(surface: SessionContextualGuideSurface,
  device: GuideDevice): SessionContextualGuide {
  if (surface === 'ssh') {
    if (device === 'phone') {
      return {
        storageKey: 'sshSessionContextualGuideShownV1',
        message: '已连接：点终端输入区唤起键盘；从“会话工具”打开语言、SFTP 和隧道。',
        durationMs: 3200
      };
    }
    return {
      storageKey: 'sshSessionContextualGuideShownV1',
      message: '已连接：顶部工具可打开 SFTP、隧道与会话设置；多主机会话可从标签切换。',
      durationMs: 3200
    };
  }
  if (device === 'desktop') {
    return {
      storageKey: 'moonlightSessionContextualGuideShownV1',
      message: '串流已就绪：从顶部工具栏打开键盘、手柄、画面与断开；先在会话内安全退出。',
      durationMs: 3400
    };
  }
  return {
    storageKey: 'moonlightSessionContextualGuideShownV1',
    message: '串流已就绪：点顶部或贴边工具栏打开控制中心、键盘和虚拟手柄。',
    durationMs: 3400
  };
}
