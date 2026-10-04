import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME: string = 'RemoteDeskAiOrbHints';
/** Bumped when the hint changes, so everyone sees the new one once (v2: the first hint was cut to a thin strip). */
const HINT_VERSION: string = '.v2';

/** What the floating orb's one-time hint says. */
export const AI_ORB_HINT_TEXT: string = '单击展开主对话 · 双击启动小对话框';
/** The same with AI 语音 on: a long press starts voice mode. */
export const AI_ORB_VOICE_HINT_TEXT: string = '单击主对话 · 双击小对话框 · 长按语音';
/** The same in a remote session, where the orb taps differently ('session' path). */
export const AI_SESSION_ORB_HINT_TEXT: string = '单击退出 AI · 双击语音 · 按住拖动';

/**
 * The floating orb explains its taps the first time it appears by each way in: after an app action ('action'), when
 * 聊天 is floated ('chat'), and as the island's own orb during a capture or a floating action ('compact').
 */
export function aiOrbHintWanted(context: common.Context | undefined, path: string): boolean {
  if (context === undefined) { return false; }
  try {
    const prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
    if (prefs.getSync(path + HINT_VERSION, false) === true) { return false; }
    prefs.putSync(path + HINT_VERSION, true);
    prefs.flush();
    return true;
  } catch (_error) { return false; }
}
