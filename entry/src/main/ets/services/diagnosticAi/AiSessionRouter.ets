/** Pages that run a remote session: their system bars are theirs (most run full screen). */
const AI_SESSION_PAGES: string[] = ['RemoteDesktop', 'SshTerminal', 'MoonlightStreamPage'];

export function aiIsSessionPage(pageName: string): boolean {
  return AI_SESSION_PAGES.indexOf(pageName) >= 0;
}

/**
 * Which window's AI answers AI requests (voice mode, hold to talk, app actions). While a remote session shows its own
 * AI (SessionAiHost), the host list — still alive under the session on a phone, or in another window on a PC — leaves
 * those requests to it, so voice mode opens over the session rather than on a hidden page. A session whose window is
 * not in front (a PC session window behind the main one) answers nothing: the window the user is in does.
 */
export class AiSessionRouter {
  private static active: string[] = [];
  /** Claims whose window is not in front now. */
  private static behind: string[] = [];

  /** A session's AI host is in front (the most recent claim wins). */
  static claim(id: string): void {
    AiSessionRouter.active = AiSessionRouter.active.filter((item: string): boolean => item !== id).concat([id]);
  }

  static release(id: string): void {
    AiSessionRouter.active = AiSessionRouter.active.filter((item: string): boolean => item !== id);
    AiSessionRouter.behind = AiSessionRouter.behind.filter((item: string): boolean => item !== id);
  }

  /** The host's window came to the front or went behind another (window active / inactive events). */
  static setInFront(id: string, inFront: boolean): void {
    AiSessionRouter.behind = AiSessionRouter.behind.filter((item: string): boolean => item !== id);
    if (!inFront) { AiSessionRouter.behind.push(id); }
  }

  /** The session host that should answer now ('' : the host list). */
  static current(): string {
    for (let i = AiSessionRouter.active.length - 1; i >= 0; i--) {
      const id: string = AiSessionRouter.active[i];
      if (AiSessionRouter.behind.indexOf(id) < 0) { return id; }
    }
    return '';
  }

  static sessionActive(): boolean { return AiSessionRouter.current() !== ''; }
}
