/**
 * Remote AI conversations in a Pro workspace. An entry's host reference is `ai:<host>`, with `@<conversation>` when it
 * names one, and `#2` when the same host (without a conversation) is in the pair twice: workspace references must differ.
 */
export interface AiPairTarget { hostId: string; sessionId: string; }

const ID = /^[A-Za-z0-9_-]{1,100}$/;

/** The reference for a pane: its host, the conversation it shows, set apart from `other` if they would match. */
export function aiPairRef(hostId: string, sessionId: string, other: string): string {
  const base = 'ai:' + hostId + (sessionId !== '' && ID.test(sessionId) ? '@' + sessionId : '');
  return base === other ? base + '#2' : base;
}

/** The host and conversation a reference names, or null for one that is not a remote AI reference. */
export function aiPairTarget(ref: string): AiPairTarget | null {
  const match = /^ai:([A-Za-z0-9_-]{1,100})(?:@([A-Za-z0-9_-]{1,100}))?(?:#2)?$/.exec(ref);
  return match === null ? null : { hostId: match[1], sessionId: match[2] ?? '' };
}
