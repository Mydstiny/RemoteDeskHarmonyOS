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
const KEYCODE_MOVE_END = 2082;

type LatchGetter = (mod: string) => string;
type LatchSetter = (mod: string, val: string) => void;
type RemoteDownGetter = (mod: string) => boolean;
type RemoteDownSetter = (mod: string, down: boolean, wireCode?: number) => void;
type SourceSpaceFn = (x: number, y: number) => Record<string, number>;
type KeyCodeMapper = (keyCode: number) => number;

export class RemoteKeyDispatcher {

  /** 发送单键 down+up */
  sendVirtualKeyTap(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string): void {
    this.sendVirtualKeyTapMapped(loader, sessionId, keyCode, label, null);
  }

  /** 发送单键 down+up，并允许面板为协议附加私有传输标记。 */
  sendVirtualKeyTapMapped(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string, mapKeyCode: KeyCodeMapper | null): void {
    try {
      const wireCode: number = this.transportCode(keyCode, mapKeyCode);
      if (loader.sendKeySequence(sessionId, [wireCode])) {
        hilog.info(DOMAIN, TAG, 'key-tap batch: ' + label + ' code=' + keyCode.toString() +
          ' wire=' + wireCode.toString());
      } else {
        hilog.warn(DOMAIN, TAG, 'key-tap batch rejected: ' + label);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'key-tap failed: ' + JSON.stringify(err));
    }
  }

  /** 发送带修饰键的按键序列 + once 自动释放 */
  sendModifiedKey(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string,
    getLatch: LatchGetter, setLatch: LatchSetter,
    isRemoteDown: RemoteDownGetter | null): void {
    this.sendModifiedKeyMapped(loader, sessionId, keyCode, label,
      getLatch, setLatch, isRemoteDown, null);
  }

  /** 发送带修饰键的按键序列，并在发送边界映射整组键码。 */
  sendModifiedKeyMapped(loader: ExtensionLoader, sessionId: number,
    keyCode: number, label: string,
    getLatch: LatchGetter, setLatch: LatchSetter,
    isRemoteDown: RemoteDownGetter | null,
    mapKeyCode: KeyCodeMapper | null,
    setRemoteDown: RemoteDownSetter | null = null): void {
    try {
      const mods: number[] = this.collectModifierCodes(getLatch);
      if (mods.length === 0) {
        this.sendVirtualKeyTapMapped(loader, sessionId, keyCode, label, mapKeyCode);
        return;
      }
      const eventCodes: Array<number> = [];
      const eventPressed: Array<boolean> = [];
      const onceMods: Array<string> = [];
      const newlyLockedMods: Array<string> = [];
      const transientWireCodes: Array<number> = [];
      for (let i = 0; i < mods.length; i++) {
        const modName: string = this.modifierName(mods[i]);
        if (getLatch(modName) === 'locked' && isRemoteDown && isRemoteDown(modName)) {
          continue;
        }
        const wireModifierCode: number = this.transportCode(mods[i], mapKeyCode);
        eventCodes.push(wireModifierCode);
        eventPressed.push(true);
        if (getLatch(modName) === 'locked') {
          newlyLockedMods.push(modName);
        } else {
          onceMods.push(modName);
          transientWireCodes.push(wireModifierCode);
        }
      }
      const wireKeyCode: number = this.transportCode(keyCode, mapKeyCode);
      eventCodes.push(wireKeyCode);
      eventPressed.push(true);
      eventCodes.push(wireKeyCode);
      eventPressed.push(false);
      for (let i = transientWireCodes.length - 1; i >= 0; i--) {
        eventCodes.push(transientWireCodes[i]);
        eventPressed.push(false);
      }
      const accepted: boolean = loader.sendKeyEvents(sessionId, eventCodes, eventPressed);
      for (let i = 0; i < onceMods.length; i++) {
        setLatch(onceMods[i], 'off');
      }
      if (!accepted) {
        hilog.warn(DOMAIN, TAG, 'modified-key batch rejected: ' + label);
        return;
      }
      if (setRemoteDown !== null) {
        for (let i = 0; i < newlyLockedMods.length; i++) {
          const modName: string = newlyLockedMods[i];
          const sourceCode: number = this.modifierCode(modName);
          setRemoteDown(modName, true, this.transportCode(sourceCode, mapKeyCode));
        }
      }
      hilog.info(DOMAIN, TAG, 'modified-key batch: ' + label + ' mods=' + mods.length.toString());
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
    this.sendShortcutSequenceMapped(loader, sessionId, keyCodes, label,
      getLatch, isRemoteDown, setRemoteDown, null);
  }

  /** 发送快捷键序列，并在发送边界映射整组键码。 */
  sendShortcutSequenceMapped(loader: ExtensionLoader, sessionId: number,
    keyCodes: number[], label: string,
    getLatch: LatchGetter | null,
    isRemoteDown: RemoteDownGetter | null,
    setRemoteDown: RemoteDownSetter | null,
    mapKeyCode: KeyCodeMapper | null): void {
    try {
      const eventCodes: Array<number> = [];
      const eventPressed: Array<boolean> = [];
      const transientCodes: Array<number> = [];
      const newlyLockedNames: Array<string> = [];
      for (let i = 0; i < keyCodes.length; i++) {
        const modName: string = this.modifierName(keyCodes[i]);
        const isLockedModifier: boolean = modName.length > 0 &&
          getLatch !== null && getLatch(modName) === 'locked';
        if (isLockedModifier) {
          if (isRemoteDown === null || !isRemoteDown(modName)) {
            const wireModifierCode: number = this.transportCode(keyCodes[i], mapKeyCode);
            eventCodes.push(wireModifierCode);
            eventPressed.push(true);
            newlyLockedNames.push(modName);
          }
          continue;
        }
        const wireCode: number = this.transportCode(keyCodes[i], mapKeyCode);
        eventCodes.push(wireCode);
        eventPressed.push(true);
        transientCodes.push(wireCode);
      }
      for (let i = transientCodes.length - 1; i >= 0; i--) {
        eventCodes.push(transientCodes[i]);
        eventPressed.push(false);
      }
      if (!loader.sendKeyEvents(sessionId, eventCodes, eventPressed)) {
        hilog.warn(DOMAIN, TAG, 'shortcut batch rejected: ' + label);
        return;
      }
      if (setRemoteDown !== null) {
        for (let i = 0; i < newlyLockedNames.length; i++) {
          const modName: string = newlyLockedNames[i];
          const sourceCode: number = this.modifierCode(modName);
          setRemoteDown(modName, true, this.transportCode(sourceCode, mapKeyCode));
        }
      }
      hilog.info(DOMAIN, TAG, 'shortcut batch: ' + label + ' keys=' + keyCodes.length.toString() +
        ' transient=' + transientCodes.length.toString());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'shortcut failed: ' + JSON.stringify(err));
    }
  }

  /** Ctrl+Alt+Del — 弹出确认对话框 + best-effort 发送 */
  sendCtrlAltDel(loader: ExtensionLoader, sessionId: number, accentColor: string,
    getLatch: LatchGetter | null = null,
    isRemoteDown: RemoteDownGetter | null = null,
    setRemoteDown: RemoteDownSetter | null = null,
    rdpSession: boolean = false): void {
    promptAction.showDialog({
      title: 'Ctrl+Alt+Del',
      message: rdpSession ?
        'RDP 会把该操作按远程安全键 Ctrl+Alt+End 提交给 Windows。是否继续？' :
        '这是 Windows 安全序列，RustDesk 需要远端服务模式支持。是否尝试发送？',
      buttons: [
        { text: '取消', color: 'rgba(255,255,255,0.6)' },
        { text: '尝试发送', color: accentColor }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        this.sendShortcutSequence(loader, sessionId,
          [KEYCODE_CTRL_LEFT, KEYCODE_ALT_LEFT,
            rdpSession ? KEYCODE_MOVE_END : KEYCODE_FORWARD_DEL], 'Ctrl+Alt+Del',
          getLatch, isRemoteDown, setRemoteDown);
        promptAction.showToast({
          message: rdpSession ? '已发送 RDP 远程安全键 Ctrl+Alt+End' :
            '已尝试发送；若无效，请确认远端服务权限',
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

  private transportCode(keyCode: number, mapKeyCode: KeyCodeMapper | null): number {
    return mapKeyCode === null ? keyCode : mapKeyCode(keyCode);
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

  private modifierCode(modifierName: string): number {
    if (modifierName === 'ctrl') {
      return KEYCODE_CTRL_LEFT;
    }
    if (modifierName === 'alt') {
      return KEYCODE_ALT_LEFT;
    }
    if (modifierName === 'shift') {
      return KEYCODE_SHIFT_LEFT;
    }
    if (modifierName === 'win') {
      return KEYCODE_META_LEFT;
    }
    return 0;
  }
}
