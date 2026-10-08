import { AiStylePalette } from '../../services/ai/AiStylePalette';
import { AiRemoteMarkdown } from './AiRemoteMarkdown';

/**
 * A reply as it streams in. The page keeps one per streaming reply and only sets its text, so the row is not made
 * again for every batch of words.
 */
@Observed
export class AiStreamText {
  text: string = '';
  constructor(text: string) { this.text = text; }
}

const TICK_MS: number = 33;

/** How many characters to show next: a few at a time when close behind, faster the further behind it falls. */
export function aiTypewriterStep(shown: number, total: number): number {
  if (shown >= total) { return total; }
  const behind = total - shown;
  return Math.min(total, shown + Math.max(1, Math.ceil(behind / 7)));
}

/** Never cut a character in two (an emoji or other surrogate pair). */
export function aiTypewriterCut(text: string, count: number): number {
  if (count <= 0 || count >= text.length) { return Math.max(0, Math.min(count, text.length)); }
  const code = text.charCodeAt(count - 1);
  return code >= 0xD800 && code <= 0xDBFF ? count + 1 : count;
}

/**
 * Types a streaming reply out character by character (the apps' 吐字): it follows the text as it grows, a few
 * characters a frame, catching up faster when a large batch arrives, so the words flow rather than appear in lumps.
 */
@Component
export struct AiTypewriter {
  @ObjectLink source: AiStreamText;
  @Prop textSize: number = 15;
  @Prop palette: AiStylePalette = {
    bg: '#FFFFFF', surface: '#F7F7F8', raised: '#FFFFFF', border: '#E5E5E5', text: '#0D0D0D', text2: '#5D5D5D',
    text3: '#8F8F8F', userBubble: '#F4F4F4', codeBg: '#F7F7F8', codeText: '#24292F', accent: '#0D0D0D',
    onAccent: '#FFFFFF', addBg: '#E6F4EA', addText: '#1A7F37', delBg: '#FDECEA', delText: '#CF222E',
    danger: '#CF222E', ok: '#1A7F37'
  };
  @State private shown: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval((): void => {
      const total = this.source.text.length;
      if (this.shown < total) { this.shown = aiTypewriterCut(this.source.text, aiTypewriterStep(this.shown, total)); }
      else if (this.shown > total) { this.shown = total; }
    }, TICK_MS);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  build() {
    AiRemoteMarkdown({ text: this.source.text.slice(0, this.shown), textSize: this.textSize, palette: this.palette })
  }
}
