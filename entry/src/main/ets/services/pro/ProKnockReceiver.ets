import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo, fileUri, statfs } from '@kit.CoreFileKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { KNOCK_MAX_BYTES, KNOCK_MAX_FILES, KNOCK_SPACE_RESERVE, KnockPoint } from './ProKnockPolicy';

export const KNOCK_SHARE_CAPABILITY: string = 'SystemCapability.Collaboration.HarmonyShare';
export function proKnockSupported(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= 26 &&
      (deviceInfo.deviceType === 'pc' || deviceInfo.deviceType === '2in1') && canIUse(KNOCK_SHARE_CAPABILITY);
  } catch (_err) { return false; }
}
export interface ProKnockReceiverOptions {
  windowId: number;
  cacheDir: string;
  isCurrent: () => boolean;
  confirm: (point: KnockPoint | null) => Promise<boolean>;
  deliver: (uris: string[], root: string, isCurrent: () => boolean) => Promise<boolean>;
  status: (message: string, active: boolean) => void;
}

/** One explicitly armed window and one incoming transfer. A revoked/cancelled
 * receive is quarantined until the platform reports completion; off() does not
 * pretend to cancel Share Kit's in-flight write permission. */
export class ProKnockReceiver {
  private registry: harmonyShare.RecvCapabilityRegistry | null = null;
  private callback: ((target: harmonyShare.ReceivableTarget) => void) | null = null;
  private options: ProKnockReceiverOptions | null = null;
  private epoch: number = 0;
  private timer: number = -1;
  private receiving: boolean = false;
  private static sequence: number = 0;

  stop(): void {
    this.epoch++;
    this.unregister();
    this.options = null;
  }
  private unregister(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.registry !== null && this.callback !== null) {
      try { harmonyShare.off('dataReceive', this.registry, this.callback); } catch (_err) { /* stale callback is fenced */ }
    }
    this.registry = null;
    this.callback = null;
  }
  arm(options: ProKnockReceiverOptions): boolean {
    this.stop();
    if (this.receiving || !proKnockSupported() || !Number.isInteger(options.windowId) ||
      options.windowId <= 0 || !options.isCurrent()) { return false; }
    const epoch: number = this.epoch;
    this.options = options;
    this.registry = { windowId: options.windowId,
      capabilities: [{ utd: 'general.file', maxSupportedCount: KNOCK_MAX_FILES }] };
    this.callback = (target: harmonyShare.ReceivableTarget): void => {
      void this.accept(target, options, epoch);
    };
    try { harmonyShare.on('dataReceive', this.registry, this.callback); }
    catch (_err) { this.stop(); return false; }
    this.timer = setTimeout((): void => {
      this.stop();
      options.status('碰一碰等待已结束，可重新准备接收', false);
    }, 120000);
    options.status('已准备接收手机文件，请在 2 分钟内碰一碰当前窗口', true);
    return true;
  }
  private async reject(target: harmonyShare.ReceivableTarget): Promise<void> {
    try { await target.reject(harmonyShare.ReceivableErrorCode.NO_RECEIVABLE_ERROR); }
    catch (_err) { /* never retry into another window */ }
  }
  private async accept(target: harmonyShare.ReceivableTarget, options: ProKnockReceiverOptions,
    epoch: number): Promise<void> {
    let valid: boolean = true;
    const current = (): boolean => valid && this.epoch === epoch && this.options === options && options.isCurrent();
    if (this.receiving || !current()) { await this.reject(target); return; }
    this.receiving = true;
    this.unregister();
    let root: string = '';
    let dataHandled: boolean = false;
    let copying: boolean = false;
    let nativeStarted: boolean = false;
    let terminal: boolean = false;
    let failed: boolean = false;
    let cleaning: boolean = false;
    const cleanup = async (): Promise<void> => {
      if (!terminal || copying || cleaning) { return; }
      cleaning = true;
      if (root.length > 0) {
        try { await fileIo.rmdir(root); } catch (_err) { /* app cache remains available for OS cleanup */ }
        root = '';
      }
      this.receiving = false;
      if (this.options === options) { this.options = null; }
    };
    try {
      let point: KnockPoint | null = null;
      // The namespace predates API23; this member is never accessed before 26.
      if (deviceInfo.sdkApiVersion >= 26) {
        try {
          const info = target.getInfo();
          if (info.coordinate !== undefined) {
            point = { x: info.coordinate.screenX, y: info.coordinate.screenY };
          }
        } catch (_err) { /* missing coordinates require explicit directory confirmation */ }
      }
      if (!await options.confirm(point) || !current()) {
        if (current()) { options.status('已取消本次接收', false); }
        await this.reject(target); terminal = true; return;
      }
      if (await statfs.getFreeSize(options.cacheDir) < KNOCK_MAX_BYTES + KNOCK_SPACE_RESERVE) {
        throw new Error('本机接收空间不足，需要至少 544 MB 可用空间');
      }
      if (!current()) { await this.reject(target); terminal = true; return; }
      const candidate: string = options.cacheDir + '/pro-knock-' + Date.now().toString(36) + '-' +
        (++ProKnockReceiver.sequence).toString(36);
      await fileIo.mkdir(candidate);
      root = candidate;
      if (!current()) { await this.reject(target); terminal = true; return; }
      options.status('正在接收手机文件，接收完成后上传到已确认目录', true);
      nativeStarted = true;
      await target.receive(fileUri.getUriFromPath(root), {
        onDataReceived: (data: systemShare.SharedData): void => {
          if (dataHandled || failed) { return; }
          dataHandled = true;
          terminal = true;
          copying = true;
          const process = async (): Promise<void> => {
            try {
              if (!current()) { return; }
              const records: systemShare.SharedRecord[] = data.getRecords();
              if (records.length === 0 || records.length > KNOCK_MAX_FILES ||
                records.some((record: systemShare.SharedRecord): boolean => !record.uri)) {
                throw new Error('接收文件数量或类型不受支持');
              }
              const uris: string[] = records.map((record: systemShare.SharedRecord): string => record.uri || '');
              const delivered: boolean = await options.deliver(uris, root, current);
              if (current()) { options.status(delivered ?
                '手机文件已加入 SFTP 上传队列，远端结果请查看传输进度' :
                '文件未加入远端上传队列，请重新接收', false); }
            } catch (err) {
              if (current()) { options.status(err instanceof Error ? err.message : '接收文件处理失败', false); }
            } finally { copying = false; await cleanup(); }
          };
          void process();
        },
        onResult: (result: harmonyShare.ShareResultCode): void => {
          if (result !== harmonyShare.ShareResultCode.SHARE_SUCCESS) {
            failed = true;
            terminal = true;
            if (current()) { options.status('手机文件接收未完成，已停止远端投递', false); }
            valid = false;
            void cleanup();
          }
        }
      });
    } catch (err) {
      if (current()) { options.status(err instanceof Error ? err.message : '碰一碰接收失败', false); }
      if (!nativeStarted) { await this.reject(target); }
      // A rejected receive call has not accepted a transfer. Once callbacks
      // already began, their completion owns cleanup instead.
      if (!dataHandled) { terminal = true; }
    } finally { await cleanup(); }
  }
}
