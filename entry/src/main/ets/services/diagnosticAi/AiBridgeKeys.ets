/** AppStorage: the AI (chat, voice) asks the host page to open an app screen ('<action id>@<time>'). */
export const AI_APP_ACTION_REQUEST: string = 'aiAppActionRequest';
/** AppStorage: a question handed to 助理 ('<time>|<question>'); the panel switches to 助理 and asks it. */
export const AI_ASSISTANT_HANDOFF: string = 'aiAssistantHandoff';
/** AppStorage: the AI asks the island (or voice mode) to float as the orb ('<time>'). */
export const AI_FLOAT_REQUEST: string = 'aiFloatRequest';
/**
 * AppStorage: voice mode hands the conversation to the chat panel. The panel, laid out but not yet shown, says where
 * its glass is ('<top>,<width>,<height>,<radius>,<time>'); the voice card grows to exactly that and the two cross-fade.
 */
export const AI_HANDOVER_RECT: string = 'aiIsland.handoverRect';
/** The handover's timing, shared by both sides: the cross-fade starts this long after the rect, and lasts this long. */
export const AI_HANDOVER_FADE_DELAY_MS: number = 240;
export const AI_HANDOVER_FADE_MS: number = 320;
/**
 * AppStorage: the AI (switch_mode) asks to change mode ('<mode>@<time>'; text · voice · assistant · chat · exit). The
 * open text panel acts on it; voice mode checks it after the answer.
 */
export const AI_MODE_REQUEST: string = 'aiModeRequest';
