import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { ExtensionLoader } from './ExtensionLoader';
import { ClipboardCoordinator, ClipboardLease, RemoteClipboardSnapshot } from './ClipboardCoordinator';
import { clipboardUtf8Bytes, validateClipboardText } from './ClipboardSyncPolicy';
import { ClipboardPublicationResult, SessionRdpClipboardContent, SessionRdpClipboardFormats,
  SessionRdpClipboardFormatResult } from '../types/rdpnapi';

const MAX_PNG_BYTES: number = 8 * 1024 * 1024;
const MAX_RICH_BYTES: number = 1024 * 1024;
const MAX_PIXELS: number = 4194304;
const MAX_RGBA_BYTES: number = MAX_PIXELS * 4;
const MAX_DIMENSION: number = 8192;
const MIME_PNG: string = 'image/png';
const MIME_RTF: string = 'text/rtf';
const MIME_RTF_APPLICATION: string = 'application/rtf';
const FORMAT_TEXT: number = 1;
const FORMAT_PNG: number = 2;
const FORMAT_DIBV5: number = 3;
const FORMAT_HTML: number = 4;
const FORMAT_RTF: number = 5;

type ClipboardCurrentGuard = () => boolean;

interface ClipboardImageSize { width: number; height: number; }
interface ClipboardImageContent { png: ArrayBuffer; rgbaStraight: ArrayBuffer; width: number; height: number; }

/** Image/rich representations stay within one captured RDP session and one copy event. */
export class RdpClipboardContentService {
  private authorityWriter: ((operation: () => boolean) => boolean) | undefined;
  private loader: ExtensionLoader;
  private sessionId: number;
  private generation: number;
  private protocol: string;
  private localInFlight: boolean = false;
  private remoteInFlight: boolean = false;
  private diagnosticCode: string = '';

  constructor(loader: ExtensionLoader, lease: ClipboardLease,
    authorityWriter?: (operation: () => boolean) => boolean) {
    this.authorityWriter = authorityWriter;
    this.loader = loader;
    // Copy scalar identity now. Never follow ExtensionLoader's current session
    // or a caller mutating its lease while ImageKit/native requests await.
    this.sessionId = lease.sessionId;
    this.generation = lease.nativeGeneration;
    this.protocol = lease.protocol;
  }

  getDiagnosticCode(): string { return this.diagnosticCode; }

  private current(isCurrent: ClipboardCurrentGuard): boolean {
    return this.protocol === 'rdp' && Number.isSafeInteger(this.sessionId) && this.sessionId > 0 &&
      Number.isSafeInteger(this.generation) && this.generation > 0 && isCurrent();
  }

  private validSize(width: number, height: number): boolean {
    return Number.isSafeInteger(width) && Number.isSafeInteger(height) && width > 0 && height > 0 &&
      width <= MAX_DIMENSION && height <= MAX_DIMENSION && width * height <= MAX_PIXELS;
  }

  private validHtml(text: string): boolean {
    const bytes: number = clipboardUtf8Bytes(text);
    return text.indexOf('\u0000') < 0 && bytes >= 0 && bytes <= MAX_RICH_BYTES;
  }

  private validRtf(buffer: ArrayBuffer): boolean {
    if (buffer.byteLength < 7 || buffer.byteLength > MAX_RICH_BYTES) { return false; }
    const bytes: Uint8Array = new Uint8Array(buffer);
    const prefix: number[] = [123, 92, 114, 116, 102, 49];
    for (let i: number = 0; i < prefix.length; i++) { if (bytes[i] !== prefix[i]) { return false; } }
    const separator: number = bytes[6];
    const last: number = bytes[bytes.length - 1];
    return (separator === 32 || separator === 92 || separator === 13 || separator === 10) &&
      (last === 125 || (last === 0 && bytes[bytes.length - 2] === 125));
  }

  private pngSize(buffer: ArrayBuffer): ClipboardImageSize | null {
    if (buffer.byteLength < 33 || buffer.byteLength > MAX_PNG_BYTES) { return null; }
    const bytes: Uint8Array = new Uint8Array(buffer);
    const signature: number[] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
    for (let i: number = 0; i < signature.length; i++) { if (bytes[i] !== signature[i]) { return null; } }
    const view: DataView = new DataView(buffer);
    const width: number = view.getUint32(16, false);
    const height: number = view.getUint32(20, false);
    return this.validSize(width, height) ? { width, height } : null;
  }

  private async releasePixelMap(value: image.PixelMap | null): Promise<void> {
    if (value !== null) { try { await value.release(); } catch (_error) { /* Best-effort cleanup only. */ } }
  }

  /** Metadata is checked before allocating decoded pixels, and again afterward. */
  private async decodePng(buffer: ArrayBuffer, isCurrent: ClipboardCurrentGuard): Promise<image.PixelMap | null> {
    const dimensions: ClipboardImageSize | null = this.pngSize(buffer);
    if (dimensions === null || !this.current(isCurrent)) { return null; }
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      source = image.createImageSource(buffer);
      const before: image.ImageInfo = source.getImageInfoSync();
      if (!this.current(isCurrent) || !this.validSize(before.size.width, before.size.height) ||
        before.size.width !== dimensions.width || before.size.height !== dimensions.height || before.mimeType !== MIME_PNG) {
        return null;
      }
      pixelMap = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredDynamicRange: image.DecodingDynamicRange.SDR,
        desiredColorSpace: colorSpaceManager.create(colorSpaceManager.ColorSpace.SRGB) });
      if (!this.current(isCurrent)) { return null; }
      const actual: image.ImageInfo = pixelMap.getImageInfoSync();
      const actualBytes: number = pixelMap.getPixelBytesNumber();
      if (!this.validSize(actual.size.width, actual.size.height) || actual.size.width !== dimensions.width ||
        actual.size.height !== dimensions.height || actual.pixelFormat !== image.PixelMapFormat.RGBA_8888 ||
        !Number.isSafeInteger(actualBytes) || actualBytes <= 0 || actualBytes > MAX_RGBA_BYTES) { return null; }
      const accepted: image.PixelMap = pixelMap;
      pixelMap = null;
      return accepted;
    } catch (_error) {
      return null;
    } finally {
      await this.releasePixelMap(pixelMap);
      if (source !== null) { try { await source.release(); } catch (_error) { /* Cleanup must not replace the result. */ } }
    }
  }

  private async straightPixels(pixelMap: image.PixelMap, isCurrent: ClipboardCurrentGuard): Promise<ArrayBuffer | null> {
    if (!this.current(isCurrent)) { return null; }
    const info: image.ImageInfo = pixelMap.getImageInfoSync();
    const width: number = info.size.width;
    const height: number = info.size.height;
    const byteCount: number = pixelMap.getPixelBytesNumber();
    const stride: number = pixelMap.getBytesNumberPerRow();
    if (!this.validSize(width, height) || info.pixelFormat !== image.PixelMapFormat.RGBA_8888 ||
      !Number.isSafeInteger(byteCount) || byteCount <= 0 || byteCount > MAX_RGBA_BYTES ||
      !Number.isSafeInteger(stride) || stride < width * 4 || stride * height > byteCount ||
      (info.alphaType !== image.AlphaType.OPAQUE && info.alphaType !== image.AlphaType.PREMUL &&
       info.alphaType !== image.AlphaType.UNPREMUL)) { return null; }
    const raw: ArrayBuffer = new ArrayBuffer(byteCount);
    await pixelMap.readPixelsToBuffer(raw);
    if (!this.current(isCurrent)) { return null; }
    const after: image.ImageInfo = pixelMap.getImageInfoSync();
    if (after.size.width !== width || after.size.height !== height || after.pixelFormat !== info.pixelFormat ||
      after.alphaType !== info.alphaType || pixelMap.getPixelBytesNumber() !== byteCount ||
      pixelMap.getBytesNumberPerRow() !== stride) { return null; }
    const source: Uint8Array = new Uint8Array(raw);
    const result: Uint8Array = new Uint8Array(width * height * 4);
    for (let y: number = 0; y < height; y++) {
      for (let x: number = 0; x < width; x++) {
        const from: number = y * stride + x * 4;
        const to: number = (y * width + x) * 4;
        const alpha: number = info.alphaType === image.AlphaType.OPAQUE ? 255 : source[from + 3];
        result[to + 3] = alpha;
        for (let channel: number = 0; channel < 3; channel++) {
          result[to + channel] = info.alphaType === image.AlphaType.PREMUL
            ? (alpha === 0 ? 0 : Math.min(255, Math.round(source[from + channel] * 255 / alpha)))
            : source[from + channel];
        }
      }
    }
    return result.buffer;
  }

  private async imageContentFromPng(buffer: ArrayBuffer, isCurrent: ClipboardCurrentGuard): Promise<ClipboardImageContent | null> {
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await this.decodePng(buffer, isCurrent);
      if (pixelMap === null || !this.current(isCurrent)) { return null; }
      const info: image.ImageInfo = pixelMap.getImageInfoSync();
      const rgba: ArrayBuffer | null = await this.straightPixels(pixelMap, isCurrent);
      if (rgba === null || !this.current(isCurrent)) { return null; }
      return { png: buffer, rgbaStraight: rgba, width: info.size.width, height: info.size.height };
    } catch (_error) { return null; }
    finally { await this.releasePixelMap(pixelMap); }
  }

  private async imageContentFromPixelMap(pixelMap: image.PixelMap,
    isCurrent: ClipboardCurrentGuard): Promise<ClipboardImageContent | null> {
    let packer: image.ImagePacker | null = null;
    try {
      if (!this.current(isCurrent)) { return null; }
      const info: image.ImageInfo = pixelMap.getImageInfoSync();
      const byteCount: number = pixelMap.getPixelBytesNumber();
      if (!this.validSize(info.size.width, info.size.height) || !Number.isSafeInteger(byteCount) ||
        byteCount <= 0 || byteCount > MAX_RGBA_BYTES) { return null; }
      packer = image.createImagePacker();
      const png: ArrayBuffer = await packer.packing(pixelMap,
        { format: MIME_PNG, quality: 100, bufferSize: MAX_PNG_BYTES, needsPackProperties: false });
      if (!this.current(isCurrent) || png.byteLength > MAX_PNG_BYTES) { return null; }
      const result: ClipboardImageContent | null = await this.imageContentFromPng(png, isCurrent);
      if (!this.current(isCurrent) || result === null || result.width !== info.size.width || result.height !== info.size.height) {
        return null;
      }
      return result;
    } catch (_error) {
      return null;
    } finally {
      if (packer !== null) { try { await packer.release(); } catch (_error) { /* Cleanup only. */ } }
      await this.releasePixelMap(pixelMap);
    }
  }

  /** Uses getData(type), since primary getters omit secondary MIME entries. */
  private async readValue(data: pasteboard.PasteData, types: string[],
    isCurrent: ClipboardCurrentGuard): Promise<pasteboard.ValueType | null> {
    try {
      const count: number = data.getRecordCount();
      if (!Number.isSafeInteger(count) || count < 0 || count > 128 || !this.current(isCurrent)) { return null; }
      for (let index: number = 0; index < count; index++) {
        const record: pasteboard.PasteDataRecord = data.getRecord(index);
        const available: string[] = record.getValidTypes(types);
        if (available.length === 0) { continue; }
        if (!this.current(isCurrent)) { return null; }
        const value: pasteboard.ValueType = await record.getData(available[0]);
        if (!this.current(isCurrent)) {
          // PixelMap returned after losing ownership is still ours to release.
          if (available[0] === pasteboard.MIMETYPE_PIXELMAP && value !== null) {
            await this.releasePixelMap(value as image.PixelMap);
          }
          return null;
        }
        return value;
      }
      return null;
    } catch (_error) { return null; }
  }

  /** null means no rich representation; the bridge can use its existing text snapshot. */
  async publishLocal(isCurrent: ClipboardCurrentGuard, supplied?: pasteboard.PasteData): Promise<boolean | null> {
    if (!this.current(isCurrent) || this.localInFlight) { return false; }
    this.localInFlight = true;
    this.diagnosticCode = '';
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const count: number = board.getChangeCount();
      const data: pasteboard.PasteData = supplied === undefined ? await board.getData() : supplied;
      if (!this.current(isCurrent) || board.getChangeCount() !== count ||
        ClipboardCoordinator.getInstance().isRemoteTag(data.getTag())) { return false; }
      const rich: boolean = data.hasType(pasteboard.MIMETYPE_PIXELMAP) || data.hasType(MIME_PNG) ||
        data.hasType(pasteboard.MIMETYPE_TEXT_HTML) || data.hasType(MIME_RTF) || data.hasType(MIME_RTF_APPLICATION);
      if (!rich) { return null; }
      const guard: ClipboardCurrentGuard = (): boolean => this.current(isCurrent) && board.getChangeCount() === count;
      const content: SessionRdpClipboardContent = {};
      const text: pasteboard.ValueType | null = await this.readValue(data, [pasteboard.MIMETYPE_TEXT_PLAIN], guard);
      if (!guard()) { return false; }
      if (typeof text === 'string' && validateClipboardText(text, true).ok) { content.textUtf8 = text; }
      const html: pasteboard.ValueType | null = await this.readValue(data, [pasteboard.MIMETYPE_TEXT_HTML], guard);
      if (!guard()) { return false; }
      if (typeof html === 'string' && this.validHtml(html)) { content.htmlUtf8 = html; }
      const rtf: pasteboard.ValueType | null = await this.readValue(data, [MIME_RTF, MIME_RTF_APPLICATION], guard);
      if (!guard()) { return false; }
      if (rtf instanceof ArrayBuffer && this.validRtf(rtf)) { content.rtfBytes = rtf; }
      const png: pasteboard.ValueType | null = await this.readValue(data, [MIME_PNG], guard);
      if (!guard()) { return false; }
      let picture: ClipboardImageContent | null = null;
      if (png instanceof ArrayBuffer) { picture = await this.imageContentFromPng(png, guard); }
      if (!guard()) { return false; }
      if (picture === null && data.hasType(pasteboard.MIMETYPE_PIXELMAP)) {
        const pixels: pasteboard.ValueType | null = await this.readValue(data, [pasteboard.MIMETYPE_PIXELMAP], guard);
        if (pixels !== null) { picture = await this.imageContentFromPixelMap(pixels as image.PixelMap, guard); }
      }
      if (!guard()) { return false; }
      if (picture !== null) {
        content.png = picture.png; content.rgbaStraight = picture.rgbaStraight;
        content.width = picture.width; content.height = picture.height;
      }
      if (content.png === undefined && content.htmlUtf8 === undefined && content.rtfBytes === undefined) {
        this.diagnosticCode = content.textUtf8 === undefined ? 'clipboard_content_unavailable' : 'clipboard_plain_text_fallback';
      }
      if (content.png === undefined && content.htmlUtf8 === undefined && content.rtfBytes === undefined &&
        content.textUtf8 === undefined) { return false; }
      if (!guard()) { return false; }
      let publication: ClipboardPublicationResult = { publicationId: 0, state: 0 };
      const publish = (): boolean => {
        if (!guard()) { return false; }
        publication = this.loader.publishSessionRdpClipboardContent(this.sessionId, this.generation, content);
        return publication.publicationId > 0;
      };
      if (!(this.authorityWriter !== undefined ? this.authorityWriter(publish) : publish())) { return false; }
      if (!guard() || publication.publicationId <= 0) { return false; }
      const started: number = Date.now();
      let state: number = publication.state;
      while (guard() && Date.now() - started < 16000) {
        if (state === 2) { return guard(); }
        if (state !== 1) { this.diagnosticCode = 'clipboard_publication_failed'; return false; }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
        if (!guard()) { return false; }
        state = this.loader.getSessionClipboardPublicationState(this.sessionId, this.generation, publication.publicationId);
      }
      this.diagnosticCode = 'clipboard_publication_timeout';
      return false;
    } catch (_error) {
      this.diagnosticCode = 'clipboard_content_unavailable';
      return false;
    } finally { this.localInFlight = false; }
  }

  private async requestFormat(sequence: number, format: number,
    isCurrent: ClipboardCurrentGuard): Promise<SessionRdpClipboardContent | null> {
    if (!this.current(isCurrent)) { return null; }
    const id: number = this.loader.requestSessionRdpClipboardFormat(this.sessionId, this.generation, sequence, format);
    if (!Number.isSafeInteger(id) || id <= 0) { return null; }
    try {
      const started: number = Date.now();
      while (this.current(isCurrent) && Date.now() - started < 16000) {
        const result: SessionRdpClipboardFormatResult = this.loader.getSessionRdpClipboardFormatResult(this.sessionId, this.generation, id);
        if (!this.current(isCurrent) || result.requestId !== id || result.sequence !== sequence || result.format !== format) { return null; }
        if (result.state === 'ready') { return result.content; }
        if (result.state !== 'loading') { return null; }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
        if (!this.current(isCurrent)) { return null; }
      }
      return null;
    } catch (_error) { return null; }
    finally {
      // Always release the captured generation, including ownership loss. Native
      // release discards payloads but retains an in-flight response tombstone.
      this.loader.releaseSessionRdpClipboardFormat(this.sessionId, this.generation, id);
    }
  }

  private async createDibPixelMap(content: SessionRdpClipboardContent,
    isCurrent: ClipboardCurrentGuard): Promise<image.PixelMap | null> {
    const width: number = content.width ?? 0;
    const height: number = content.height ?? 0;
    const bytes: ArrayBuffer | undefined = content.rgbaStraight;
    if (!this.current(isCurrent) || !this.validSize(width, height) || bytes === undefined ||
      bytes.byteLength !== width * height * 4) { return null; }
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await image.createPixelMap(bytes, { size: { width, height },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888, pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.UNPREMUL, editable: false });
      if (!this.current(isCurrent)) { return null; }
      const actual: image.ImageInfo = pixelMap.getImageInfoSync();
      if (actual.size.width !== width || actual.size.height !== height ||
        pixelMap.getPixelBytesNumber() <= 0 || pixelMap.getPixelBytesNumber() > MAX_RGBA_BYTES) { return null; }
      const accepted: image.PixelMap = pixelMap;
      pixelMap = null;
      return accepted;
    } catch (_error) { return null; }
    finally { await this.releasePixelMap(pixelMap); }
  }

  /** No HTML rendering or URL access: store only explicit offered representations. */
  async receiveRemote(snapshot: RemoteClipboardSnapshot, isCurrent: ClipboardCurrentGuard,
    remoteTag: string): Promise<boolean> {
    if (!this.current(isCurrent) || snapshot.kind !== 'rich' || !snapshot.ready || this.remoteInFlight ||
      !ClipboardCoordinator.getInstance().isRemoteTag(remoteTag)) { return false; }
    this.remoteInFlight = true;
    this.diagnosticCode = '';
    let pixelMap: image.PixelMap | null = null;
    try {
      const offer: SessionRdpClipboardFormats = this.loader.getSessionRdpClipboardFormats(this.sessionId, this.generation);
      if (!this.current(isCurrent) || offer.sequence !== snapshot.sequence) { return false; }
      const supported: number[] = [FORMAT_TEXT, FORMAT_PNG, FORMAT_DIBV5, FORMAT_HTML, FORMAT_RTF];
      const selected: number[] = supported.filter((format: number): boolean => offer.formats.indexOf(format) >= 0);
      const requests: Promise<SessionRdpClipboardContent | null>[] = selected.map((format: number): Promise<SessionRdpClipboardContent | null> =>
        this.requestFormat(snapshot.sequence, format, isCurrent));
      const received: (SessionRdpClipboardContent | null)[] = await Promise.all(requests);
      if (!this.current(isCurrent)) { return false; }
      const content: SessionRdpClipboardContent = {};
      for (let index: number = 0; index < selected.length; index++) {
        const candidate: SessionRdpClipboardContent | null = received[index];
        if (candidate === null) { continue; }
        const format: number = selected[index];
        if (format === FORMAT_TEXT && candidate.textUtf8 !== undefined && validateClipboardText(candidate.textUtf8, true).ok) {
          content.textUtf8 = candidate.textUtf8;
        } else if (format === FORMAT_PNG && candidate.png !== undefined && this.pngSize(candidate.png) !== null) {
          content.png = candidate.png;
        } else if (format === FORMAT_DIBV5) {
          content.rgbaStraight = candidate.rgbaStraight; content.width = candidate.width; content.height = candidate.height;
        } else if (format === FORMAT_HTML && candidate.htmlUtf8 !== undefined && this.validHtml(candidate.htmlUtf8)) {
          content.htmlUtf8 = candidate.htmlUtf8;
        } else if (format === FORMAT_RTF && candidate.rtfBytes !== undefined && this.validRtf(candidate.rtfBytes)) {
          content.rtfBytes = candidate.rtfBytes;
        }
      }
      if (content.png !== undefined) { pixelMap = await this.decodePng(content.png, isCurrent); }
      if (!this.current(isCurrent)) { return false; }
      if (pixelMap === null && content.rgbaStraight !== undefined) { pixelMap = await this.createDibPixelMap(content, isCurrent); }
      if (!this.current(isCurrent)) { return false; }
      const values: Record<string, pasteboard.ValueType> = {};
      if (pixelMap !== null) { values[pasteboard.MIMETYPE_PIXELMAP] = pixelMap; }
      if (content.htmlUtf8 !== undefined) { values[pasteboard.MIMETYPE_TEXT_HTML] = content.htmlUtf8; }
      if (content.rtfBytes !== undefined) { values[MIME_RTF] = content.rtfBytes; }
      if (content.textUtf8 !== undefined) { values[pasteboard.MIMETYPE_TEXT_PLAIN] = content.textUtf8; }
      if (Object.keys(values).length === 0) { this.diagnosticCode = 'clipboard_content_unavailable'; return false; }
      if (pixelMap === null && content.htmlUtf8 === undefined && content.rtfBytes === undefined) {
        this.diagnosticCode = 'clipboard_plain_text_fallback';
      }
      const data: pasteboard.PasteData = pasteboard.createData(values);
      const property: pasteboard.PasteDataProperty = data.getProperty(); property.tag = remoteTag; data.setProperty(property);
      if (!this.current(isCurrent)) { return false; }
      const write = (): boolean => {
        if (!this.current(isCurrent)) { return false; }
        pasteboard.getSystemPasteboard().setDataSync(data);
        return this.current(isCurrent);
      };
      return this.authorityWriter !== undefined ? this.authorityWriter(write) : write();
    } catch (_error) {
      this.diagnosticCode = 'clipboard_content_delivery_failed';
      return false;
    } finally {
      // setDataSync has serialized the value; retain no PixelMap/ImageSource/
      // ImagePacker beyond delivery, including failures and late completions.
      await this.releasePixelMap(pixelMap);
      this.remoteInFlight = false;
    }
  }
}
