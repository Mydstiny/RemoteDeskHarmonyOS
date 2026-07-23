/**
 * RemoteKeyDispatcher.ets — 远程桌面按键发送服务 (无状态)
 *
 * 从 RemoteDesktop.ets 抽取的纯发送逻辑。不持有 @State, 不持有连接状态。
 * 所有方法接受 loader + sessionId + 回调函数作为参数。
 */
import { ExtensionLoader } from './ExtensionLoader';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'KeyDispatcher';
const DOMAIN = 0x0014;

// Key codes (与 RemoteDesktop.ets 保持一致)
const KEYCODE_CTRL_LEFT = 2072;
const KEYCODE_CTRL_RIGHT = 2073;
const KEYCODE_ALT_LEFT = 2045;
const KEYCODE_ALT_RIGHT = 2046;
const KEYCODE_SHIFT_LEFT = 2047;
const KEYCODE_SHIFT_RIGHT = 2048;
const KEYCODE_META_LEFT = 2076;
const KEYCODE_META_RIGHT = 2077;
const KEYCODE_FORWARD_DEL = 2071;

type LatchGetter = (mod: string) => string;
type LatchSetter = (mod: string, val: string) => void;
type RemoteDownGetter = (mod: string) => boolean;
type RemoteDownSetter = (mod: string, down: boolean) => void;
type SourceSpaceFn = (x: number, y: number) => Record<string, number>;

export class RemoteKeyDispatcher {

  /** 发送单键 down+up */
  sendVirtualKeyTap(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string): void {
    try {
      loader.sendKey(sessionId, keyCode, true);
      loader.sendKey(sessionId, keyCode, false);
      hilog.info(DOMAIN, TAG, 'key-tap: ' + label + ' code=' + keyCode.toString());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'key-tap failed: ' + JSON.stringify(err));
    }
  }

  /** 发送带修饰键的按键序列 + once 自动释放 */
  sendModifiedKey(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string,
    getLatch: LatchGetter, setLatch: LatchSetter,
    isRemoteDown: RemoteDownGetter | null): void {
    try {
      const mods: number[] = this.collectModifierCodes(getLatch);
      if (mods.length === 0) {
        this.sendVirtualKeyTap(loader, sessionId, keyCode, label);
        return;
      }
      // P0-2: locked 且已 remote-down 的修饰键不重复发 down (由 setLatch 锁定时刻发送)
      for (let i = 0; i < mods.length; i++) {
        const modName: string = this.modifierName(mods[i]);
        if (getLatch(modName) === 'locked' && isRemoteDown && isRemoteDown(modName)) {
          continue; // 已按下, 跳过
        }
        loader.sendKey(sessionId, mods[i], true);
      }
      loader.sendKey(sessionId, keyCode, true);
      loader.sendKey(sessionId, keyCode, false);
      // 逆序释放 once 状态的修饰键 (locked 保持)
      for (let i = mods.length - 1; i >= 0; i--) {
        const modName: string = this.modifierName(mods[i]);
        if (getLatch(modName) === 'once') {
          loader.sendKey(sessionId, mods[i], false);
          setLatch(modName, 'off');
        }
      }
      hilog.info(DOMAIN, TAG, 'modified-key: ' + label + ' mods=' + mods.length.toString());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'modified-key failed: ' + JSON.stringify(err));
    }
  }

  /** 发送快捷键序列 (全部 down → 逆序 up) */
  sendShortcutSequence(loader: ExtensionLoader, sessionId: number,
    keyCodes: number[], label: string,
    getLatch: LatchGetter | null = null,
    isRemoteDown: RemoteDownGetter | null = null,
    setRemoteDown: RemoteDownSetter | null = null): void {
    try {
      const pressedCodes: number[] = [];
      for (let i = 0; i < keyCodes.length; i++) {
        const modName: string = this.modifierName(keyCodes[i]);
        const isLockedModifier: boolean = modName.length > 0 &&
          getLatch !== null && getLatch(modName) === 'locked';
        if (isLockedModifier) {
          if (isRemoteDown === null || !isRemoteDown(modName)) {
            loader.sendKey(sessionId, keyCodes[i], true);
            if (setRemoteDown !== null) {
              setRemoteDown(modName, true);
            }
            hilog.info(DOMAIN, TAG, 'shortcut restore locked modifier down: ' + modName);
          } else {
            hilog.info(DOMAIN, TAG, 'shortcut keep locked modifier down: ' + modName);
          }
          continue;
        }
        loader.sendKey(sessionId, keyCodes[i], true);
        pressedCodes.push(keyCodes[i]);
      }
      for (let i = pressedCodes.length - 1; i >= 0; i--) {
        loader.sendKey(sessionId, pressedCodes[i], false);
      }
      hilog.info(DOMAIN, TAG, 'shortcut: ' + label + ' keys=' + keyCodes.length.toString() +
        ' transient=' + pressedCodes.length.toString());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'shortcut failed: ' + JSON.stringify(err));
    }
  }

  /** Ctrl+Alt+Del — 弹出确认对话框 + best-effort 发送 */
  sendCtrlAltDel(loader: ExtensionLoader, sessionId: number, accentColor: string,
    getLatch: LatchGetter | null = null,
    isRemoteDown: RemoteDownGetter | null = null,
    setRemoteDown: RemoteDownSetter | null = null): void {
    promptAction.showDialog({
      title: 'Ctrl+Alt+Del',
      message: '这是 Windows 安全序列，远程桌面普通按键模拟通常无效。\n\nRDP 需 FreeRDP SAS 支持；RustDesk 需远端服务模式。\n\n是否尝试发送按键序列？',
      buttons: [
        { text: '取消', color: 'rgba(255,255,255,0.6)' },
        { text: '尝试发送', color: accentColor }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        this.sendShortcutSequence(loader, sessionId,
          [KEYCODE_CTRL_LEFT, KEYCODE_ALT_LEFT, KEYCODE_FORWARD_DEL], 'Ctrl+Alt+Del',
          getLatch, isRemoteDown, setRemoteDown);
        promptAction.showToast({
          message: '已尝试发送，如无效需协议级 SAS 支持',
          duration: 3000
        });
      }
    }).catch((_err: Error): void => { /* 取消 */ });
  }

  /**
   * Release remote keys, and optionally mouse buttons.
   *
   * Keyboard focus transitions are not pointer cancellations: a physical
   * mouse drag may legitimately move focus away from the hidden keyboard
   * proxy while its primary button remains held.
   */
  releaseAllHeldKeys(loader: ExtensionLoader, sessionId: number,
    toSource: SourceSpaceFn, cursorX: number, cursorY: number,
    releaseMouseButtons: boolean = true): void {
    try {
      loader.sendKey(sessionId, KEYCODE_CTRL_LEFT, false);
      loader.sendKey(sessionId, KEYCODE_CTRL_RIGHT, false);
      loader.sendKey(sessionId, KEYCODE_ALT_LEFT, false);
      loader.sendKey(sessionId, KEYCODE_ALT_RIGHT, false);
      loader.sendKey(sessionId, KEYCODE_SHIFT_LEFT, false);
      loader.sendKey(sessionId, KEYCODE_SHIFT_RIGHT, false);
      loader.sendKey(sessionId, KEYCODE_META_LEFT, false);
      loader.sendKey(sessionId, KEYCODE_META_RIGHT, false);
      if (releaseMouseButtons) {
        const src: Record<string, number> = toSource(cursorX, cursorY);
        loader.sendMouse(sessionId, src['x'], src['y'], 0, false);
        loader.sendMouse(sessionId, src['x'], src['y'], 1, false);
        loader.sendMouse(sessionId, src['x'], src['y'], 2, false);
      }
      hilog.info(DOMAIN, TAG, 'release-all-held-keys done mouse=' +
        (releaseMouseButtons ? 'yes' : 'no'));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'release-all-held-keys failed: ' + JSON.stringify(err));
    }
  }

  // ============================================================
  // 内部辅助
  // ============================================================

  private collectModifierCodes(getLatch: LatchGetter): number[] {
    const codes: number[] = [];
    if (getLatch('ctrl') !== 'off') {
      codes.push(KEYCODE_CTRL_LEFT);
    }
    if (getLatch('alt') !== 'off') {
      codes.push(KEYCODE_ALT_LEFT);
    }
    if (getLatch('shift') !== 'off') {
      codes.push(KEYCODE_SHIFT_LEFT);
    }
    if (getLatch('win') !== 'off') {
      codes.push(KEYCODE_META_LEFT);
    }
    return codes;
  }

  private modifierName(keyCode: number): string {
    if (keyCode === KEYCODE_CTRL_LEFT || keyCode === KEYCODE_CTRL_RIGHT) {
      return 'ctrl';
    }
    if (keyCode === KEYCODE_ALT_LEFT || keyCode === KEYCODE_ALT_RIGHT) {
      return 'alt';
    }
    if (keyCode === KEYCODE_SHIFT_LEFT || keyCode === KEYCODE_SHIFT_RIGHT) {
      return 'shift';
    }
    if (keyCode === KEYCODE_META_LEFT || keyCode === KEYCODE_META_RIGHT) {
      return 'win';
    }
    return '';
  }
}
