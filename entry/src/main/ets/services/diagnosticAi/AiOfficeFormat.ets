import { AiMdBlock, AiMdSpan, aiMarkdownBlocks, aiMarkdownPlain } from './AiMarkdownPolicy';
import { AiZipEntry, aiZipStore, aiZipTextEntry } from './AiZipWriter';

/**
 * Office Open XML for the chat's documents, both ways: a Word or Excel file written from the AI's Markdown, and the
 * plain text read back out of a .docx/.xlsx/.pptx the user added. Pure string work; the file I/O is elsewhere.
 */

const XML_HEAD: string = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const W_NS: string = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const REL_NS: string = 'http://schemas.openxmlformats.org/package/2006/relationships';
const OFFICE_REL: string = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

export function aiXmlEscape(value: string): string {
  return value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export function aiXmlUnescape(value: string): string {
  let text: string = value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, '\'');
  // Numeric references one by one (a replacer callback is avoided on purpose).
  let match: RegExpMatchArray | null = text.match(/&#(x[0-9a-fA-F]+|\d+);/);
  let guard: number = 0;
  while (match !== null && guard < 10000) {
    const code: string = match[1];
    const ch: string = String.fromCharCode(code.startsWith('x') ? parseInt(code.slice(1), 16) : parseInt(code, 10));
    text = text.replace(match[0], ch);
    match = text.match(/&#(x[0-9a-fA-F]+|\d+);/);
    guard++;
  }
  return text.replace(/&amp;/g, '&');
}

// ---------------------------------------------------------------- Word

function runXml(text: string, bold: boolean, code: boolean, extra: string = ''): string {
  const props: string = (bold ? '<w:b/>' : '') + (code ? '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/>' : '') + extra;
  // A line break inside a paragraph is a <w:br/> between runs.
  return text.split('\n').map((part: string, index: number): string =>
    (index > 0 ? '<w:r><w:br/></w:r>' : '') + '<w:r>' + (props !== '' ? '<w:rPr>' + props + '</w:rPr>' : '') +
      '<w:t xml:space="preserve">' + aiXmlEscape(part) + '</w:t></w:r>').join('');
}

function spansXml(spans: AiMdSpan[], extra: string = ''): string {
  return spans.map((span: AiMdSpan): string => runXml(span.text, span.bold, span.code, extra)).join('');
}

function paragraphXml(props: string, runs: string): string {
  return '<w:p>' + (props !== '' ? '<w:pPr>' + props + '</w:pPr>' : '') + runs + '</w:p>';
}

function tableXml(rows: string[][]): string {
  const columns: number = rows.reduce((most: number, row: string[]): number => Math.max(most, row.length), 0);
  if (columns === 0) { return ''; }
  const width: number = Math.floor(9000 / columns);
  const border = (side: string): string => '<w:' + side + ' w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>';
  let xml: string = '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblBorders>' +
    ['top', 'left', 'bottom', 'right', 'insideH', 'insideV'].map(border).join('') +
    '</w:tblBorders><w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>';
  for (let c: number = 0; c < columns; c++) { xml += '<w:gridCol w:w="' + width.toString() + '"/>'; }
  xml += '</w:tblGrid>';
  rows.forEach((row: string[], r: number): void => {
    xml += '<w:tr>';
    for (let c: number = 0; c < columns; c++) {
      const cell: string = c < row.length ? row[c] : '';
      xml += '<w:tc><w:tcPr><w:tcW w:w="' + width.toString() + '" w:type="dxa"/>' +
        (r === 0 ? '<w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/>' : '') + '</w:tcPr>' +
        paragraphXml('<w:spacing w:before="40" w:after="40"/>', runXml(aiMarkdownPlain(cell), r === 0, false)) + '</w:tc>';
    }
    xml += '</w:tr>';
  });
  return xml + '</w:tbl>';
}

function blockXml(block: AiMdBlock): string {
  switch (block.kind) {
    case 'h1': return paragraphXml('<w:pStyle w:val="Heading1"/>', spansXml(block.spans));
    case 'h2': return paragraphXml('<w:pStyle w:val="Heading2"/>', spansXml(block.spans));
    case 'h3': return paragraphXml('<w:pStyle w:val="Heading3"/>', spansXml(block.spans));
    case 'bullet':
      return paragraphXml('<w:ind w:left="' + (420 + block.level * 420).toString() + '" w:hanging="300"/>',
        runXml('•\t', false, false) + spansXml(block.spans));
    case 'number':
      return paragraphXml('<w:ind w:left="' + (420 + block.level * 420).toString() + '" w:hanging="420"/>',
        runXml(block.marker + '\t', false, false) + spansXml(block.spans));
    case 'quote':
      return paragraphXml('<w:ind w:left="420"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="BFBFBF"/></w:pBdr>',
        spansXml(block.spans, '<w:color w:val="595959"/>'));
    case 'rule':
      return paragraphXml('<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="BFBFBF"/></w:pBdr>', '');
    case 'code':
      return block.text.split('\n').map((line: string): string =>
        paragraphXml('<w:spacing w:before="0" w:after="0"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/>',
          runXml(line, false, true))).join('');
    case 'table': return tableXml(block.rows) + paragraphXml('', '');
    default: return paragraphXml('', spansXml(block.spans));
  }
}

const DOCX_STYLES: string = XML_HEAD + '<w:styles xmlns:w="' + W_NS + '">' +
  '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="微软雅黑" w:cs="Calibri"/>' +
  '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault>' +
  '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="312" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>' +
  '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>' +
  '<w:pPr><w:jc w:val="center"/><w:spacing w:before="120" w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>' +
  '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>' +
  '<w:pPr><w:keepNext/><w:spacing w:before="200" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>' +
  '<w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>' +
  '</w:styles>';

/** A .docx from Markdown; the title opens the document unless the Markdown already starts with a top heading. */
export function aiDocxBytes(title: string, markdown: string): Uint8Array {
  const blocks: AiMdBlock[] = aiMarkdownBlocks(markdown);
  let body: string = '';
  if (title.trim() !== '' && (blocks.length === 0 || blocks[0].kind !== 'h1')) {
    body += paragraphXml('<w:pStyle w:val="Title"/>', runXml(title.trim(), false, false));
  }
  blocks.forEach((block: AiMdBlock): void => { body += blockXml(block); });
  const document: string = XML_HEAD + '<w:document xmlns:w="' + W_NS + '"><w:body>' + body +
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ' +
    'w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>';
  const entries: AiZipEntry[] = [
    aiZipTextEntry('[Content_Types].xml', XML_HEAD +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
      '</Types>'),
    aiZipTextEntry('_rels/.rels', XML_HEAD + '<Relationships xmlns="' + REL_NS + '">' +
      '<Relationship Id="rId1" Type="' + OFFICE_REL + '/officeDocument" Target="word/document.xml"/></Relationships>'),
    aiZipTextEntry('word/_rels/document.xml.rels', XML_HEAD + '<Relationships xmlns="' + REL_NS + '">' +
      '<Relationship Id="rId1" Type="' + OFFICE_REL + '/styles" Target="styles.xml"/></Relationships>'),
    aiZipTextEntry('word/document.xml', document),
    aiZipTextEntry('word/styles.xml', DOCX_STYLES)
  ];
  return aiZipStore(entries);
}

// ---------------------------------------------------------------- Excel

/** One CSV line, quotes honoured. */
function csvCells(line: string, separator: string): string[] {
  const cells: string[] = [];
  let cell: string = '';
  let quoted: boolean = false;
  for (let i: number = 0; i < line.length; i++) {
    const ch: string = line.charAt(i);
    if (quoted) {
      if (ch === '"' && line.charAt(i + 1) === '"') { cell += '"'; i++; }
      else if (ch === '"') { quoted = false; }
      else { cell += ch; }
    } else if (ch === '"' && cell === '') { quoted = true; }
    else if (ch === separator) { cells.push(cell.trim()); cell = ''; }
    else { cell += ch; }
  }
  cells.push(cell.trim());
  return cells;
}

/** The rows of a sheet the AI wrote: its first Markdown table, or tab / comma separated lines. */
export function aiSheetRows(content: string): string[][] {
  const table: AiMdBlock | undefined = aiMarkdownBlocks(content).find((block: AiMdBlock): boolean => block.kind === 'table');
  if (table !== undefined) { return table.rows.map((row: string[]): string[] => row.map((cell: string): string => aiMarkdownPlain(cell))); }
  const lines: string[] = content.replace(/\r\n?/g, '\n').split('\n').filter((line: string): boolean => line.trim() !== '' &&
    !line.trim().startsWith('```'));
  const separator: string = lines.some((line: string): boolean => line.indexOf('\t') >= 0) ? '\t' : ',';
  return lines.map((line: string): string[] => csvCells(line, separator));
}

function columnName(index: number): string {
  let n: number = index + 1;
  let name: string = '';
  while (n > 0) {
    const rem: number = (n - 1) % 26;
    name = String.fromCharCode(65 + rem) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

function displayWidth(text: string): number {
  let width: number = 0;
  for (let i: number = 0; i < text.length; i++) { width += text.charCodeAt(i) > 0x2E80 ? 2 : 1; }
  return width;
}

/** A .xlsx with one sheet: the first row in bold, numbers stored as numbers, columns sized to their text. */
export function aiXlsxBytes(title: string, content: string): Uint8Array {
  const rows: string[][] = aiSheetRows(content).slice(0, 5000);
  const columns: number = rows.reduce((most: number, row: string[]): number => Math.max(most, row.length), 0);
  const widths: number[] = [];
  for (let c: number = 0; c < columns; c++) {
    const widest: number = rows.reduce((most: number, row: string[]): number =>
      Math.max(most, c < row.length ? displayWidth(row[c]) : 0), 0);
    widths.push(Math.min(60, Math.max(8, widest + 2)));
  }
  let sheetData: string = '';
  rows.forEach((row: string[], r: number): void => {
    sheetData += '<row r="' + (r + 1).toString() + '">';
    row.forEach((cell: string, c: number): void => {
      const ref: string = columnName(c) + (r + 1).toString();
      const style: string = r === 0 ? ' s="1"' : '';
      if (r > 0 && /^-?\d+(\.\d+)?$/.test(cell) && cell.length < 16) {
        sheetData += '<c r="' + ref + '"' + style + '><v>' + cell + '</v></c>';
      } else if (cell !== '') {
        sheetData += '<c r="' + ref + '"' + style + ' t="inlineStr"><is><t xml:space="preserve">' + aiXmlEscape(cell) + '</t></is></c>';
      }
    });
    sheetData += '</row>';
  });
  const cols: string = widths.length === 0 ? '' : '<cols>' + widths.map((w: number, c: number): string =>
    '<col min="' + (c + 1).toString() + '" max="' + (c + 1).toString() + '" width="' + w.toString() + '" customWidth="1"/>').join('') + '</cols>';
  const sheetName: string = (title.replace(/[\[\]:*?\/\\]/g, ' ').trim() || 'Sheet1').slice(0, 31);
  const ns: string = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  const entries: AiZipEntry[] = [
    aiZipTextEntry('[Content_Types].xml', XML_HEAD +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
      '</Types>'),
    aiZipTextEntry('_rels/.rels', XML_HEAD + '<Relationships xmlns="' + REL_NS + '">' +
      '<Relationship Id="rId1" Type="' + OFFICE_REL + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'),
    aiZipTextEntry('xl/workbook.xml', XML_HEAD + '<workbook xmlns="' + ns + '" xmlns:r="' + OFFICE_REL + '">' +
      '<sheets><sheet name="' + aiXmlEscape(sheetName) + '" sheetId="1" r:id="rId1"/></sheets></workbook>'),
    aiZipTextEntry('xl/_rels/workbook.xml.rels', XML_HEAD + '<Relationships xmlns="' + REL_NS + '">' +
      '<Relationship Id="rId1" Type="' + OFFICE_REL + '/worksheet" Target="worksheets/sheet1.xml"/>' +
      '<Relationship Id="rId2" Type="' + OFFICE_REL + '/styles" Target="styles.xml"/></Relationships>'),
    aiZipTextEntry('xl/styles.xml', XML_HEAD + '<styleSheet xmlns="' + ns + '">' +
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>' +
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
      '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>' +
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'),
    aiZipTextEntry('xl/worksheets/sheet1.xml', XML_HEAD + '<worksheet xmlns="' + ns + '">' +
      (rows.length > 1 ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' : '') +
      cols + '<sheetData>' + sheetData + '</sheetData></worksheet>')
  ];
  return aiZipStore(entries);
}

// ---------------------------------------------------------------- reading

/** The text of word/document.xml: one line per paragraph, table cells separated by " | ". */
export function aiDocxText(xml: string): string {
  const out: string[] = [];
  let line: string = '';
  let cellDepth: number = 0;
  const pattern: RegExp = /<w:t(?:\s[^>]*)?>([^<]*)<\/w:t>|<w:tab\/>|<w:br\/>|<w:tc[ >]|<\/w:tc>|<\/w:tr>|<\/w:p>/g;
  let match: RegExpExecArray | null = pattern.exec(xml);
  while (match !== null) {
    const token: string = match[0];
    if (token.startsWith('<w:t') && !token.startsWith('<w:tab') && !token.startsWith('<w:tc')) { line += aiXmlUnescape(match[1] ?? ''); }
    else if (token === '<w:tab/>') { line += '\t'; }
    else if (token === '<w:br/>') { line += cellDepth > 0 ? ' ' : '\n'; }
    else if (token.startsWith('<w:tc')) { cellDepth++; }
    else if (token === '</w:tc>') { cellDepth = Math.max(0, cellDepth - 1); line = line.replace(/\s+$/, '') + ' | '; }
    else if (token === '</w:tr>') { out.push(line.replace(/\s*\|\s*$/, '')); line = ''; }
    else if (token === '</w:p>') {
      if (cellDepth > 0) { line += ' '; } else { out.push(line); line = ''; }
    }
    match = pattern.exec(xml);
  }
  if (line !== '') { out.push(line); }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}

/** The strings of xl/sharedStrings.xml, in order. */
export function aiXlsxSharedStrings(xml: string): string[] {
  const strings: string[] = [];
  const items: RegExpMatchArray | null = xml.match(/<si>[\s\S]*?<\/si>/g);
  (items ?? []).forEach((item: string): void => {
    const parts: RegExpMatchArray | null = item.match(/<t(?:\s[^>]*)?>[^<]*<\/t>/g);
    strings.push((parts ?? []).map((part: string): string => aiXmlUnescape(part.replace(/<[^>]+>/g, ''))).join(''));
  });
  return strings;
}

/** One worksheet as tab separated lines (shared strings resolved). */
export function aiXlsxSheetText(xml: string, shared: string[]): string {
  const lines: string[] = [];
  const rows: RegExpMatchArray | null = xml.match(/<row[\s>][\s\S]*?<\/row>/g);
  (rows ?? []).forEach((row: string): void => {
    const cells: string[] = [];
    const found: RegExpMatchArray | null = row.match(/<c[\s>][\s\S]*?(?:<\/c>|\/>)/g);
    (found ?? []).forEach((cell: string): void => {
      const type: RegExpMatchArray | null = cell.match(/\bt="([a-zA-Z]+)"/);
      const value: RegExpMatchArray | null = cell.match(/<v>([^<]*)<\/v>/);
      if (type !== null && type[1] === 's' && value !== null) { cells.push(shared[parseInt(value[1], 10)] ?? ''); }
      else if (type !== null && type[1] === 'inlineStr') {
        const parts: RegExpMatchArray | null = cell.match(/<t(?:\s[^>]*)?>[^<]*<\/t>/g);
        cells.push((parts ?? []).map((part: string): string => aiXmlUnescape(part.replace(/<[^>]+>/g, ''))).join(''));
      } else { cells.push(value !== null ? aiXmlUnescape(value[1]) : ''); }
    });
    if (cells.some((cell: string): boolean => cell !== '')) { lines.push(cells.join('\t')); }
  });
  return lines.join('\n');
}

/** The text of one slide: one line per paragraph. */
export function aiPptxSlideText(xml: string): string {
  const lines: string[] = [];
  const paragraphs: RegExpMatchArray | null = xml.match(/<a:p>[\s\S]*?<\/a:p>|<a:p\s[\s\S]*?<\/a:p>/g);
  (paragraphs ?? []).forEach((paragraph: string): void => {
    const parts: RegExpMatchArray | null = paragraph.match(/<a:t>[^<]*<\/a:t>/g);
    const text: string = (parts ?? []).map((part: string): string => aiXmlUnescape(part.slice(5, part.length - 6))).join('');
    if (text.trim() !== '') { lines.push(text); }
  });
  return lines.join('\n');
}

/** HTML as readable text (tags dropped, block ends as line breaks). */
export function aiHtmlText(html: string): string {
  return aiXmlUnescape(html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, '')
    .replace(/<(br|\/p|\/div|\/li|\/h\d|\/tr)\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' '))
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
