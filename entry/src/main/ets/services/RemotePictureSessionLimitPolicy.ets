import { ActiveRemoteSessionRecord, remoteVideoSessionBusyMessage } from './ActiveRemoteSessionRegistry';

/**
 * 同时打开的远程画面（RDP、RustDesk、VNC）数量上限：PC 4 个（多窗口）、平板 2 个（左右分屏）、手机 1 个（与以前一样）。
 * 原生层支持多个画面会话并存；上限由 ExtensionLoader.connect() 在发起原生连接前检查。
 */

/** connect() result when the device's limit is reached; no native connection was started. */
export const REMOTE_PICTURE_SESSION_LIMIT_CODE: number = -91;

export function remotePictureSessionLimit(deviceType: string): number {
  if (deviceType === 'pc' || deviceType === '2in1') {
    return 4;
  }
  return deviceType === 'tablet' ? 2 : 1;
}

export function isRemotePictureProtocolName(protocol: string): boolean {
  return protocol === 'rdp' || protocol === 'rustdesk' || protocol === 'vnc';
}

/** Whether one more picture session may start while `liveCount` are open. */
export function remotePictureSessionAllowed(liveCount: number, limit: number): boolean {
  return liveCount < Math.max(1, limit);
}

/**
 * What to tell the user when the limit is reached. A one-session device keeps the old wording, naming the session in
 * the way when it is known.
 */
export function remotePictureSessionLimitMessage(limit: number, active: ActiveRemoteSessionRecord | null,
  hostId: string, activeLabel: string): string {
  if (limit <= 1) {
    const busy: string = remoteVideoSessionBusyMessage(active, hostId, activeLabel);
    return busy !== '' ? busy :
      '已有远程画面（RDP、RustDesk、VNC）在运行。本设备同一时间只能打开一个，请先断开它再连接。';
  }
  return '已经同时打开 ' + limit.toString() + ' 个远程画面（RDP、RustDesk、VNC），本设备最多 ' +
    limit.toString() + ' 个。请先关闭一个再连接。';
}
