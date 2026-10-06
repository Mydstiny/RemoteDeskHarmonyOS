/**
 * 设置 › AI 语音 › 连接中语音回答: when the AI in a remote session reads its answers aloud. The session has no voice ball
 * of its own (it would cover the remote screen): the orb listens and the orb answers.
 */
export const AI_SESSION_REPLY_MODES: string[][] = [['spoken', '语音提问时朗读'], ['always', '每次都朗读'], ['off', '不朗读']];

export function aiSessionReplyMode(value: string): string {
  return value === 'always' || value === 'off' ? value : 'spoken';
}

export function aiSessionReplyLabel(value: string): string {
  const mode: string = aiSessionReplyMode(value);
  const found: string[] | undefined = AI_SESSION_REPLY_MODES.find((pair: string[]): boolean => pair[0] === mode);
  return found !== undefined ? found[1] : AI_SESSION_REPLY_MODES[0][1];
}

/**
 * Whether an answer in a session is read aloud. `talk` is the orb's voice mode for this session: 'on' (语音模式, 用语音
 * 回答我: every answer, then it listens again), 'off' (回到文字, 用文字回答: none), '' (the setting decides — a question
 * the orb heard is answered aloud with 语音提问时朗读). Nothing is read while AI 语音 is off.
 */
export function aiSessionReadsAnswer(mode: string, talk: string, spokenAsk: boolean, voiceEnabled: boolean): boolean {
  if (!voiceEnabled) { return false; }
  if (talk === 'on') { return true; }
  if (talk === 'off') { return false; }
  const reply: string = aiSessionReplyMode(mode);
  return reply === 'always' || (reply === 'spoken' && spokenAsk);
}

/** After an answer was read in the orb's voice mode, it listens again — with 连续对话 on. */
export function aiSessionListensAgain(talk: string, continuous: boolean): boolean {
  return talk === 'on' && continuous;
}
