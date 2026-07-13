/**
 * ClipboardBridgeService — 系统剪贴板 ↔ 远程桌面桥接
 *
 * 复用项目中已有的 pasteboard API 模式 (SshTerminal / KeyVaultPage / SshKeyCard)。
 * 轮询检测本地系统剪贴板变化并推送远端；接收远端剪贴板并写入本地系统剪贴板。
 * 防回环: setSystemText 后 1.2s 窗口期内忽略轮询到的相同/相似内容。
 */
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { validateClipboardText } from './ClipboardSyncPolicy';

const TAG = 'ClipboardBridge';

export class ClipboardBridgeService {
  private pollingTimer: number = -1;
  private lastHash: number = 0;
  private remoteSetAt: number = 0;
  private remoteSetHash: number = 0;
  private onLocalTextChanged?: (text: string) => void;
  private enabled: boolean = false;
  private readRemoteText?: () => string;
  private lastRemoteHash: number = 0;

  /** 读系统剪贴板纯文本 (异步) */
  getSystemText(): Promise<string> {
    return new Promise<string>((resolve) => {
      try {
        const sysPb = pasteboard.getSystemPasteboard();
        sysPb.getData((err: BusinessError, pd: pasteboard.PasteData) => {
          if (err) {
            hilog.warn(0x0001, TAG, `getData failed: ${err.code} ${err.message}`);
            resolve('');
            return;
          }
          try {
            const text: string = pd.getPrimaryText();
            resolve(text);
          } catch (e) {
            resolve('');
          }
        });
      } catch (e) {
        resolve('');
      }
    });
  }

  /** 写系统剪贴板纯文本 (来自远端) — 同时标记防回环窗口 */
  setSystemText(text: string): void {
    if (!validateClipboardText(text).ok) {
      return;
    }
    try {
      const pd: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(pd);
      this.remoteSetAt = Date.now();
      this.remoteSetHash = this.hashText(text);
      hilog.info(0x0001, TAG, `setSystemText: ${text.length} chars, antiLoop=true`);
    } catch (err) {
      hilog.warn(0x0001, TAG, `setSystemText failed: ${JSON.stringify(err)}`);
    }
  }

  /** 启动监听 (定时轮询) */
  startMonitoring(callback: (text: string) => void, readRemoteText?: () => string): void {
    if (this.enabled) {
      return;
    }
    try {
      this.enabled = true;
      this.onLocalTextChanged = callback;
      this.readRemoteText = readRemoteText;
      this.lastHash = 0;

      // 先读一次建立基线
      this.getSystemText().then((text: string) => {
        this.lastHash = this.hashText(text);
      }).catch((err: Error) => {
        hilog.warn(0x0001, TAG, `initial clipboard read failed: ${err.message}`);
      });

      // 500ms 轮询
      this.pollingTimer = setInterval(() => {
        this.pollOnce();
      }, 500);
      hilog.info(0x0001, TAG, 'monitoring started (500ms poll)');
    } catch (err) {
      this.enabled = false;
      this.onLocalTextChanged = undefined;
      hilog.warn(0x0001, TAG, `monitoring start failed: ${JSON.stringify(err)}`);
    }
  }

  /** 停止监听 */
  stopMonitoring(): void {
    if (!this.enabled) {
      return;
    }
    this.enabled = false;
    this.onLocalTextChanged = undefined;
    this.readRemoteText = undefined;
    if (this.pollingTimer >= 0) {
      clearInterval(this.pollingTimer);
      this.pollingTimer = -1;
    }
    this.remoteSetAt = 0;
    this.remoteSetHash = 0;
    hilog.info(0x0001, TAG, 'monitoring stopped');
  }

  /** 单次轮询 */
  private pollOnce(): void {
    if (!this.enabled || !this.onLocalTextChanged) {
      return;
    }
    if (this.readRemoteText) {
      const remoteText: string = this.readRemoteText();
      const remoteHash: number = this.hashText(remoteText);
      if (remoteHash !== 0 && remoteHash !== this.lastRemoteHash && validateClipboardText(remoteText).ok) {
        this.lastRemoteHash = remoteHash;
        this.setSystemText(remoteText);
      }
    }
    this.getSystemText().then((text: string) => {
      if (!this.enabled) {
        return;
      }
      const hash: number = this.hashText(text);

      // 防回环: 远端写入后 1200ms 内忽略匹配的本地变化
      if (this.remoteSetAt > 0) {
        const elapsed: number = Date.now() - this.remoteSetAt;
        if (elapsed < 1200 && (hash === this.remoteSetHash || hash === 0)) {
          return;
        }
        if (elapsed >= 1200) {
          this.remoteSetAt = 0;
          this.remoteSetHash = 0;
        }
      }

      // 内容变化且非空 → 推送到远端
      if (hash !== this.lastHash && text.length > 0) {
        if (!validateClipboardText(text).ok) { return; }
        this.lastHash = hash;
        try {
          this.onLocalTextChanged!(text);
        } catch (err) {
          hilog.warn(0x0001, TAG, `local clipboard callback failed: ${JSON.stringify(err)}`);
        }
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, `clipboard poll failed: ${err.message}`);
    });
  }

  /** 纯文本内容哈希 (djb2 — 轻量去重，不要求密码学强度) */
  private hashText(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    let h: number = 5381;
    for (let i: number = 0; i < text.length; i++) {
      h = ((h << 5) + h) + text.charCodeAt(i);
      h = h & 0x7fffffff; // 保持正数
    }
    return h;
  }
}
