import { common, Want, wantConstant } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { pdfService } from '@kit.PDFKit';
import { systemShare } from '@kit.ShareKit';
import { image } from '@kit.ImageKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { print } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { aiDocxBytes, aiDocxText, aiHtmlText, aiPptxSlideText, aiXlsxBytes, aiXlsxSharedStrings, aiXlsxSheetText } from './AiOfficeFormat';

/**
 * The chat's documents: files the user adds (picked, or shared from another app) read as text for the model, and
 * files the AI writes (Word, Excel, Markdown, text) kept in the app's own storage, from where they open in WPS or
 * another app, go to the share sheet, or are saved where the user chooses. Nothing is read without the user picking
 * or sharing it.
 */

const IMPORT_LIMIT_BYTES: number = 20 * 1024 * 1024;
const UNZIPPED_LIMIT_BYTES: number = 80 * 1024 * 1024;
/** Text kept per added document; the chat sends a part of it and reads on with read_attachment. */
const TEXT_LIMIT: number = 200000;
const PDF_PAGE_LIMIT: number = 200;

export class AiAttachment {
  id: string;
  name: string;
  /** docx · xlsx · pptx · pdf · html · text */
  kind: string;
  text: string;
  bytes: number;
  truncated: boolean;

  constructor(id: string, name: string, kind: string, text: string, bytes: number) {
    this.id = id;
    this.name = name;
    this.kind = kind;
    this.text = text.length > TEXT_LIMIT ? text.slice(0, TEXT_LIMIT) : text;
    this.bytes = bytes;
    this.truncated = text.length > TEXT_LIMIT;
  }
}

/** A document the AI wrote. */
export class AiDocument {
  name: string;
  /** docx · xlsx · md · txt */
  format: string;
  path: string;
  bytes: number;
  createdAt: number;

  constructor(name: string, format: string, path: string, bytes: number, createdAt: number) {
    this.name = name;
    this.format = format;
    this.path = path;
    this.bytes = bytes;
    this.createdAt = createdAt;
  }
}

export function aiDocumentKind(name: string): string {
  const ext: string = name.lastIndexOf('.') >= 0 ? name.slice(name.lastIndexOf('.') + 1).toLowerCase() : '';
  if (ext === 'docx' || ext === 'xlsx' || ext === 'pptx' || ext === 'pdf') { return ext; }
  if (ext === 'html' || ext === 'htm') { return 'html'; }
  if (['jpg', 'jpeg', 'png', 'webp', 'bmp', 'heic', 'heif', 'gif'].indexOf(ext) >= 0) { return 'image'; }
  if (['txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log', 'xml', 'yaml', 'yml', 'ini', 'conf', 'sh', 'py', 'js', 'ts',
    'ets', 'java', 'c', 'cpp', 'h', 'go', 'rs', 'sql'].indexOf(ext) >= 0) { return 'text'; }
  if (ext === 'doc' || ext === 'xls' || ext === 'ppt' || ext === 'wps' || ext === 'et' || ext === 'dps') { return 'legacy'; }
  return '';
}

export function aiDocumentKindLabel(kind: string): string {
  switch (kind) {
    case 'docx': return 'Word';
    case 'xlsx': return 'Excel';
    case 'pptx': return 'PPT';
    case 'pdf': return 'PDF';
    case 'md': return 'Markdown';
    case 'html': return '网页';
    case 'image': return '图片';
    default: return '文本';
  }
}

/** The file pickers' filter: the documents the chat can read. */
const PICK_FILTER: string[] = ['文档和图片|.docx,.xlsx,.pptx,.pdf,.txt,.md,.csv,.json,.html,.log,.jpg,.jpeg,.png,.webp,.heic'];

export async function aiPickDocuments(context: common.UIAbilityContext, max: number): Promise<string[]> {
  const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
  options.maxSelectNumber = Math.max(1, Math.min(5, max));
  options.fileSuffixFilters = PICK_FILTER;
  return await new picker.DocumentViewPicker(context).select(options);
}

function nameFromUri(uri: string): string {
  const path: string = uri.split('?')[0];
  const last: string = path.slice(path.lastIndexOf('/') + 1);
  try { return decodeURIComponent(last); } catch (_error) { return last; }
}

function newId(): string {
  return Date.now().toString(36) + Math.floor(Math.random() * 1679616).toString(36);
}

function readBytes(path: string): Uint8Array {
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const size: number = fileIo.statSync(file.fd).size;
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const read: number = fileIo.readSync(file.fd, buffer);
    return new Uint8Array(buffer, 0, read);
  } finally { fileIo.closeSync(file); }
}

/** UTF-8 first; a file that is not valid UTF-8 is read as GB18030 (what Chinese Windows tools write). */
function decodeText(bytes: Uint8Array): string {
  try { return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes); }
  catch (_error) {
    try { return util.TextDecoder.create('gb18030', { fatal: false, ignoreBOM: true }).decodeToString(bytes); }
    catch (_second) { return util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true }).decodeToString(bytes); }
  }
}

function readText(path: string): string { return decodeText(readBytes(path)); }

function exists(path: string): boolean {
  try { return fileIo.accessSync(path); } catch (_error) { return false; }
}

function removeTree(path: string): void {
  try { if (exists(path)) { fileIo.rmdirSync(path); } } catch (_error) { /* cache, cleaned by the system later */ }
}

function ensureDir(path: string): void {
  if (!exists(path)) { fileIo.mkdirSync(path, true); }
}

function numbered(names: string[], prefix: string): string[] {
  return names.filter((name: string): boolean => name.startsWith(prefix) && name.endsWith('.xml'))
    .sort((a: string, b: string): number => parseInt(a.slice(prefix.length), 10) - parseInt(b.slice(prefix.length), 10));
}

/** The text of an Office Open XML file, unzipped into the cache and removed afterwards. */
async function officeText(context: common.Context, path: string, kind: string): Promise<string> {
  const unpacked: number = await zlib.getOriginalSize(path);
  if (unpacked > UNZIPPED_LIMIT_BYTES) { throw new Error('AI_DOC_TOO_LARGE'); }
  const dir: string = context.cacheDir + '/ai-unzip-' + newId();
  ensureDir(dir);
  try {
    await zlib.decompressFile(path, dir);
    if (kind === 'docx') {
      return aiDocxText(readText(dir + '/word/document.xml'));
    }
    if (kind === 'xlsx') {
      const shared: string[] = exists(dir + '/xl/sharedStrings.xml') ? aiXlsxSharedStrings(readText(dir + '/xl/sharedStrings.xml')) : [];
      const sheets: string[] = numbered(fileIo.listFileSync(dir + '/xl/worksheets'), 'sheet');
      return sheets.slice(0, 12).map((sheet: string, index: number): string =>
        (sheets.length > 1 ? '【工作表 ' + (index + 1).toString() + '】\n' : '') +
          aiXlsxSheetText(readText(dir + '/xl/worksheets/' + sheet), shared)).join('\n\n');
    }
    const slides: string[] = numbered(fileIo.listFileSync(dir + '/ppt/slides'), 'slide');
    return slides.map((slide: string, index: number): string =>
      '【第 ' + (index + 1).toString() + ' 页】\n' + aiPptxSlideText(readText(dir + '/ppt/slides/' + slide))).join('\n\n');
  } finally { removeTree(dir); }
}

function pdfText(path: string): string {
  if (!canIUse('SystemCapability.OfficeService.PDFService.Core')) { throw new Error('AI_DOC_PDF_UNAVAILABLE'); }
  const document: pdfService.PdfDocument = new pdfService.PdfDocument();
  const result: pdfService.ParseResult = document.loadDocument(path);
  if (result === pdfService.ParseResult.PARSE_ERROR_PASSWORD) { throw new Error('AI_DOC_PDF_LOCKED'); }
  if (result !== pdfService.ParseResult.PARSE_SUCCESS) { throw new Error('AI_DOC_UNREADABLE'); }
  try {
    const pages: number = Math.min(PDF_PAGE_LIMIT, document.getPageCount());
    const parts: string[] = [];
    let total: number = 0;
    for (let i: number = 0; i < pages && total < TEXT_LIMIT; i++) {
      const text: string = document.getPage(i).getTextContent().replace(/\r\n?/g, '\n').trim();
      if (text !== '') { parts.push('【第 ' + (i + 1).toString() + ' 页】\n' + text); total += text.length; }
    }
    if (parts.length === 0) { throw new Error('AI_DOC_PDF_NO_TEXT'); }
    return parts.join('\n\n');
  } finally { document.releaseDocument(); }
}

/** The text in a picture (a screenshot, a photo of a page), read on the device. */
export async function aiRecognizeImageFile(uriOrPath: string): Promise<string> {
  if (!canIUse('SystemCapability.AI.OCR.TextRecognition')) { throw new Error('AI_DOC_OCR_UNAVAILABLE'); }
  const file: fileIo.File = fileIo.openSync(uriOrPath, fileIo.OpenMode.READ_ONLY);
  let pixels: image.PixelMap | null = null;
  try {
    const source: image.ImageSource = image.createImageSource(file.fd);
    pixels = await source.createPixelMap();
    await source.release();
    await textRecognition.init();
    const result: textRecognition.TextRecognitionResult = await textRecognition.recognizeText({ pixelMap: pixels });
    return result.value;
  } finally {
    if (pixels !== null) { await pixels.release(); }
    fileIo.closeSync(file);
  }
}

/**
 * Copy a picked or shared file into the cache and read its text. Errors are AI_DOC_* codes for aiDocumentErrorText.
 */
export async function aiImportDocument(context: common.Context, uri: string, nameHint: string = ''): Promise<AiAttachment> {
  const name: string = (nameHint.trim() !== '' ? nameHint.trim() : nameFromUri(uri)).slice(0, 120);
  const kind: string = aiDocumentKind(name);
  if (kind === 'legacy') { throw new Error('AI_DOC_LEGACY'); }
  if (kind === '') { throw new Error('AI_DOC_UNSUPPORTED'); }
  const id: string = newId();
  const dir: string = context.cacheDir + '/ai-import';
  ensureDir(dir);
  const path: string = dir + '/' + id + '.' + (kind === 'text' || kind === 'html' ? 'txt' : kind === 'image' ? 'img' : kind);
  const source: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  let bytes: number = 0;
  try {
    bytes = fileIo.statSync(source.fd).size;
    if (bytes > IMPORT_LIMIT_BYTES) { throw new Error('AI_DOC_TOO_LARGE'); }
    fileIo.copyFileSync(source.fd, path);
  } finally { fileIo.closeSync(source); }
  try {
    let text: string = '';
    if (kind === 'text') { text = readText(path); }
    else if (kind === 'html') { text = aiHtmlText(readText(path)); }
    else if (kind === 'pdf') { text = pdfText(path); }
    else if (kind === 'image') { text = await aiRecognizeImageFile(path); if (text.trim() === '') { throw new Error('AI_DOC_IMAGE_NO_TEXT'); } }
    else { text = await officeText(context, path, kind); }
    if (text.trim() === '') { throw new Error('AI_DOC_EMPTY'); }
    hilog.info(0x0000, 'AiChat', 'imported %{public}s chars=%{public}s', kind, text.length.toString());
    return new AiAttachment(id, name, kind, text, bytes);
  } catch (error) {
    const message: string = error instanceof Error ? error.message : '';
    hilog.warn(0x0000, 'AiChat', 'import failed kind=%{public}s %{public}s', kind, message.slice(0, 60));
    throw new Error(message.startsWith('AI_DOC_') ? message : 'AI_DOC_UNREADABLE');
  } finally {
    try { fileIo.unlinkSync(path); } catch (_error) { /* cache */ }
  }
}

/** Text shared from another app (no file): an attachment like any other. */
export function aiTextAttachment(name: string, text: string): AiAttachment {
  return new AiAttachment(newId(), name, 'text', text, text.length);
}

export function aiDocumentErrorText(error: Object): string {
  const code: string = error instanceof Error ? error.message : '';
  if (code === 'AI_DOC_LEGACY') { return '暂不支持旧版 .doc/.xls/.ppt，请在 WPS 里另存为 .docx/.xlsx/.pptx 后再添加'; }
  if (code === 'AI_DOC_UNSUPPORTED') { return '暂不支持这种文件，可以添加 Word、Excel、PPT、PDF、文本文件或图片'; }
  if (code === 'AI_DOC_TOO_LARGE') { return '文件太大（上限 20 MB）'; }
  if (code === 'AI_DOC_PDF_LOCKED') { return '这个 PDF 有密码，请先在其他应用里去掉密码'; }
  if (code === 'AI_DOC_PDF_NO_TEXT') { return '这个 PDF 里没有可读的文字（可能是扫描件）'; }
  if (code === 'AI_DOC_PDF_UNAVAILABLE') { return '当前设备不支持读取 PDF'; }
  if (code === 'AI_DOC_EMPTY') { return '文件里没有读到文字'; }
  if (code === 'AI_DOC_IMAGE_NO_TEXT') { return '图片里没有识别到文字'; }
  if (code === 'AI_DOC_OCR_UNAVAILABLE') { return '当前设备不支持识别图片文字'; }
  return '读取文件失败，请确认文件没有损坏';
}

/** A file name the AI asked for, made safe and given the format's extension. */
export function aiDocumentFileName(title: string, format: string): string {
  const base: string = title.replace(/\.(docx|xlsx|md|txt|markdown)$/i, '').replace(/[\\/:*?"<>|\r\n\t]/g, ' ')
    .replace(/\s+/g, ' ').trim().slice(0, 60);
  return (base !== '' ? base : 'AI 文档') + '.' + format;
}

function documentsDir(context: common.Context): string {
  const dir: string = context.filesDir + '/ai-documents';
  ensureDir(dir);
  return dir;
}

/** Write a document the AI produced. format: docx · xlsx · md · txt (anything else is written as docx). */
export function aiCreateDocument(context: common.Context, title: string, format: string, content: string): AiDocument {
  const kind: string = ['docx', 'xlsx', 'md', 'txt'].indexOf(format) >= 0 ? format : 'docx';
  const name: string = aiDocumentFileName(title, kind);
  const folder: string = documentsDir(context) + '/' + newId();
  ensureDir(folder);
  const path: string = folder + '/' + name;
  const bytes: Uint8Array = kind === 'docx' ? aiDocxBytes(title.replace(/\.(docx)$/i, ''), content) :
    kind === 'xlsx' ? aiXlsxBytes(title.replace(/\.(xlsx)$/i, ''), content) :
    new util.TextEncoder().encodeInto(content);
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
  finally { fileIo.closeSync(file); }
  hilog.info(0x0000, 'AiChat', 'created %{public}s bytes=%{public}s', kind, bytes.length.toString());
  return new AiDocument(name, kind, path, bytes.length, Date.now());
}

export function aiDocumentAvailable(document: AiDocument): boolean { return exists(document.path); }

function documentUtd(format: string): string {
  if (format === 'docx') { return 'org.openxmlformats.wordprocessingml.document'; }
  if (format === 'xlsx') { return 'org.openxmlformats.spreadsheetml.sheet'; }
  if (format === 'md') { return 'general.markdown'; }
  return 'general.plain-text';
}

function documentMime(format: string): string {
  if (format === 'docx') { return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'; }
  if (format === 'xlsx') { return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'; }
  if (format === 'md') { return 'text/markdown'; }
  return 'text/plain';
}

/** Open in the app the system picks for the type (WPS when it is installed), with read access to this one file. */
export async function aiOpenDocument(context: common.UIAbilityContext, document: AiDocument): Promise<void> {
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: fileUri.getUriFromPath(document.path),
    type: documentUtd(document.format),
    flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
  };
  try {
    await context.startAbility(want);
  } catch (_error) {
    // Older handlers register MIME types only.
    want.type = documentMime(document.format);
    await context.startAbility(want);
  }
}

export async function aiShareDocument(context: common.UIAbilityContext, document: AiDocument): Promise<void> {
  const record: systemShare.SharedRecord = {
    utd: documentUtd(document.format), uri: fileUri.getUriFromPath(document.path), title: document.name
  };
  const controller: systemShare.ShareController = new systemShare.ShareController(new systemShare.SharedData(record));
  await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL,
    selectionMode: systemShare.SelectionMode.SINGLE });
}

/** Save a copy where the user chooses (Files, a cloud drive folder, …). Returns false when the picker was closed. */
export async function aiSaveDocumentAs(context: common.UIAbilityContext, document: AiDocument): Promise<boolean> {
  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  options.newFileNames = [document.name];
  const targets: string[] = await new picker.DocumentViewPicker(context).save(options);
  if (targets.length === 0) { return false; }
  const target: fileIo.File = fileIo.openSync(targets[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try { fileIo.copyFileSync(document.path, target.fd); } finally { fileIo.closeSync(target); }
  return true;
}

/** Send a document to the system print dialog (printers on the network, or save as PDF). */
export async function aiPrintDocument(context: common.UIAbilityContext, document: AiDocument): Promise<void> {
  await print.print([fileUri.getUriFromPath(document.path)], context);
}
