import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { util } from '@kit.ArkTS';
import rdpnapi from 'librdpnapi.so';
import { sessionEvidenceFileName } from './SessionEvidencePolicy';

/** One captured remote frame. The caller releases `pixelMap`. */
export interface SessionFrame {
  width: number;
  height: number;
  pixelMap: image.PixelMap;
  capturedAt: number;
}

/** Screenshots and packs live here for a day; the next capture removes older ones. */
const EVIDENCE_KEEP_MS: number = 24 * 3600 * 1000;

function evidenceDir(context: common.Context): string {
  const dir: string = context.cacheDir + '/session-evidence';
  try { if (!fileIo.accessSync(dir)) { fileIo.mkdirSync(dir, true); } } catch (_error) { /* write fails visibly later */ }
  try {
    fileIo.listFileSync(dir).forEach((name: string): void => {
      const path: string = dir + '/' + name;
      try {
        if (Date.now() - fileIo.statSync(path).mtime * 1000 > EVIDENCE_KEEP_MS) { fileIo.unlinkSync(path); }
      } catch (_error) { /* removed later */ }
    });
  } catch (_error) { /* empty */ }
  return dir;
}

/** The next presented remote frame at its own size. Throws when the session shows no frame within the timeout. */
export async function captureSessionFrame(rendererHandle: number): Promise<SessionFrame> {
  if (rendererHandle <= 0) { throw new Error('E-SCREENSHOT-NO-RENDERER'); }
  const capture: rdpnapi.RendererFrameCapture = await rdpnapi.captureRendererFrame(rendererHandle, 2500);
  if (capture.width <= 0 || capture.height <= 0 || capture.pixels.byteLength < capture.width * capture.height * 4) {
    throw new Error('E-SCREENSHOT-EMPTY');
  }
  const pixelMap: image.PixelMap = await image.createPixelMap(capture.pixels, {
    size: { width: capture.width, height: capture.height },
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false,
    alphaType: image.AlphaType.OPAQUE
  });
  return { width: capture.width, height: capture.height, pixelMap, capturedAt: Date.now() };
}

/** The frame as a PNG in the app's cache; returns its path. */
export async function writeSessionFramePng(context: common.Context, frame: SessionFrame): Promise<string> {
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const data: ArrayBuffer = await packer.packing(frame.pixelMap, { format: 'image/png', quality: 100 });
    const path: string = evidenceDir(context) + '/' + sessionEvidenceFileName('screenshot', frame.capturedAt);
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, data); } finally { fileIo.closeSync(file); }
    return path;
  } finally {
    await packer.release();
  }
}

/** A text file next to the screenshot (the session summary or the 诊断时间线); returns its path. */
export function writeSessionEvidenceText(context: common.Context, capturedAt: number, text: string,
  kind: 'summary' | 'timeline' = 'summary'): string {
  const path: string = evidenceDir(context) + '/' + sessionEvidenceFileName(kind, capturedAt);
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  } finally {
    fileIo.closeSync(file);
  }
  return path;
}

/** The text in the frame, read on this device (nothing leaves it). '' when none; throws when OCR is unavailable. */
export async function recognizeSessionFrameText(frame: SessionFrame): Promise<string> {
  if (!canIUse('SystemCapability.AI.OCR.TextRecognition')) { throw new Error('E-SCREENSHOT-OCR-UNAVAILABLE'); }
  await textRecognition.init();
  const result: textRecognition.TextRecognitionResult = await textRecognition.recognizeText({ pixelMap: frame.pixelMap });
  return result.value;
}

/**
 * Saves the PNG to 图库. Call it from the 保存 button's click (a SaveButton): that click is what lets the app create
 * the photo without the storage permission.
 */
export async function saveSessionFrameToGallery(context: common.Context, pngPath: string): Promise<void> {
  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  try {
    const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
    const target: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    const source: fileIo.File = fileIo.openSync(pngPath, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.copyFileSync(source.fd, target.fd);
    } finally {
      fileIo.closeSync(source);
      fileIo.closeSync(target);
    }
  } finally {
    await helper.release();
  }
}

/** The system share sheet with these files (screenshot PNG, summary text); the user picks where they go. */
export async function shareSessionEvidence(context: common.UIAbilityContext, paths: string[]): Promise<void> {
  if (paths.length === 0) { throw new Error('E-EVIDENCE-EMPTY'); }
  const records: systemShare.SharedRecord[] = paths.map((path: string): systemShare.SharedRecord => ({
    utd: path.endsWith('.png') ? 'general.png' : 'general.plain-text',
    uri: fileUri.getUriFromPath(path)
  }));
  const data: systemShare.SharedData = new systemShare.SharedData(records[0]);
  for (let i = 1; i < records.length; i++) { data.addRecord(records[i]); }
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  await controller.show(context, {
    previewMode: systemShare.SharePreviewMode.DETAIL,
    selectionMode: records.length > 1 ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE
  });
}
