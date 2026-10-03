/**
 * The small part of Markdown the chat uses: headings, paragraphs, bullet and numbered lists, quotes, rules, code
 * blocks and tables, with **bold** and `code` inside a line. The chat draws answers from these blocks, and a created
 * Word document is written from the same blocks, so what the user reads is what the document holds.
 */

export class AiMdSpan {
  text: string;
  bold: boolean;
  code: boolean;

  constructor(text: string, bold: boolean, code: boolean) {
    this.text = text;
    this.bold = bold;
    this.code = code;
  }
}

/** kind: h1 · h2 · h3 · p · bullet · number · quote · rule · code · table. */
export class AiMdBlock {
  kind: string;
  spans: AiMdSpan[];
  /** A numbered item's number ("3."), a bullet's level (0, 1, …) as text. */
  marker: string;
  level: number;
  /** A code block's text. */
  text: string;
  /** A table's rows (the header first), cells already trimmed. */
  rows: string[][];

  constructor(kind: string, spans: AiMdSpan[]) {
    this.kind = kind;
    this.spans = spans;
    this.marker = '';
    this.level = 0;
    this.text = '';
    this.rows = [];
  }
}

/** **bold** / __bold__ and `code` inside a line; other markers are left as typed. */
export function aiMarkdownSpans(line: string): AiMdSpan[] {
  const spans: AiMdSpan[] = [];
  const pattern: RegExp = /(\*\*[^*]+\*\*|__[^_]+__|`[^`]+`)/g;
  let last: number = 0;
  let match: RegExpExecArray | null = pattern.exec(line);
  while (match !== null) {
    if (match.index > last) { spans.push(new AiMdSpan(line.slice(last, match.index), false, false)); }
    const token: string = match[0];
    if (token.startsWith('`')) { spans.push(new AiMdSpan(token.slice(1, token.length - 1), false, true)); }
    else { spans.push(new AiMdSpan(token.slice(2, token.length - 2), true, false)); }
    last = match.index + token.length;
    match = pattern.exec(line);
  }
  if (last < line.length) { spans.push(new AiMdSpan(line.slice(last), false, false)); }
  return spans.length > 0 ? spans : [new AiMdSpan('', false, false)];
}

/** The plain text of a line (markers dropped). */
export function aiMarkdownPlain(line: string): string {
  return aiMarkdownSpans(line).map((span: AiMdSpan): string => span.text).join('');
}

function tableCells(line: string): string[] {
  let value: string = line.trim();
  if (value.startsWith('|')) { value = value.slice(1); }
  if (value.endsWith('|')) { value = value.slice(0, value.length - 1); }
  return value.split('|').map((cell: string): string => cell.trim());
}

function isTableSeparator(line: string): boolean {
  return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);
}

export function aiMarkdownBlocks(text: string): AiMdBlock[] {
  const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
  const blocks: AiMdBlock[] = [];
  let paragraph: string[] = [];
  const flush = (): void => {
    if (paragraph.length === 0) { return; }
    blocks.push(new AiMdBlock('p', aiMarkdownSpans(paragraph.join('\n'))));
    paragraph = [];
  };
  let i: number = 0;
  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();
    if (trimmed.startsWith('```')) {
      flush();
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) { code.push(lines[i]); i++; }
      const block: AiMdBlock = new AiMdBlock('code', []);
      block.text = code.join('\n');
      blocks.push(block);
      i++;
      continue;
    }
    if (trimmed === '') { flush(); i++; continue; }
    if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      flush();
      const block: AiMdBlock = new AiMdBlock('table', []);
      block.rows.push(tableCells(line));
      i += 2;
      while (i < lines.length && lines[i].trim() !== '' && lines[i].indexOf('|') >= 0) {
        block.rows.push(tableCells(lines[i]));
        i++;
      }
      blocks.push(block);
      continue;
    }
    const heading: RegExpMatchArray | null = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (heading !== null) {
      flush();
      const level: number = heading[1].length;
      blocks.push(new AiMdBlock(level === 1 ? 'h1' : level === 2 ? 'h2' : 'h3', aiMarkdownSpans(heading[2].replace(/\s*#+\s*$/, ''))));
      i++;
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) { flush(); blocks.push(new AiMdBlock('rule', [])); i++; continue; }
    const bullet: RegExpMatchArray | null = line.match(/^(\s*)[-*+•]\s+(.*)$/);
    if (bullet !== null) {
      flush();
      const block: AiMdBlock = new AiMdBlock('bullet', aiMarkdownSpans(bullet[2]));
      block.level = Math.min(3, Math.floor(bullet[1].replace(/\t/g, '  ').length / 2));
      blocks.push(block);
      i++;
      continue;
    }
    const numbered: RegExpMatchArray | null = line.match(/^(\s*)(\d{1,3})[.)、]\s+(.*)$/);
    if (numbered !== null) {
      flush();
      const block: AiMdBlock = new AiMdBlock('number', aiMarkdownSpans(numbered[3]));
      block.marker = numbered[2] + '.';
      block.level = Math.min(3, Math.floor(numbered[1].replace(/\t/g, '  ').length / 2));
      blocks.push(block);
      i++;
      continue;
    }
    const quote: RegExpMatchArray | null = trimmed.match(/^>\s?(.*)$/);
    if (quote !== null) { flush(); blocks.push(new AiMdBlock('quote', aiMarkdownSpans(quote[1]))); i++; continue; }
    paragraph.push(trimmed);
    i++;
  }
  flush();
  return blocks;
}
