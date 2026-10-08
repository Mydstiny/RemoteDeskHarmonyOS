/** Closed numeric evidence only. Codec IDs: H264=0, H265=1, VP8=2, VP9=3, AV1=4.
 * Preference IDs: auto=0, VP8=1, VP9=2, AV1=3, H264=4, H265=5; -1=unknown.
 * Orientation: 0=not reported, 1=normal, 2=upside down, 3=mirrored horizontally.
 * Flip source: 0=unknown, 1=restored, 2=user, 3=reset. Corners: TL, TR, BL, BR.
 */
export interface DecoderAttemptEvidence {
  serial: number;
  decoderGeneration: number;
  codec: number;
  width: number;
  height: number;
  stage: number;
  result: number;
  platformCode: number;
  capabilityHardware: number;
  capabilitySizeSupported: number;
  outputWidth: number;
  outputHeight: number;
  outputPixelFormat: number;
  asyncErrors: number;
  lastAsyncError: number;
  /** Output description (-1 not reported). */
  outputStride: number;
  outputSliceHeight: number;
  outputCropTop: number;
  outputCropBottom: number;
  outputCropLeft: number;
  outputCropRight: number;
  outputRotation: number;
  outputTransformType: number;
  /** NativeImage buffer transform and V1 matrix class on the desktop path (-1 not sampled). */
  bufferTransform: number;
  producerV1Class: number;
  /** Transform class the orientation self-test correction undid, +256 when undone in texture space (-1 none). */
  orientationCorrection: number;
  /** First key frames: NAL types (bits 0..31 / 32..63), SEI payload types, display-orientation SEI. */
  streamNalMaskLow: number;
  streamNalMaskHigh: number;
  streamSeiMaskLow: number;
  streamSeiMaskHigh: number;
  streamDisplayOrientation: number;
  streamInspectedFrames: number;
}

/**
 * The known four-colour picture decoded through this device's decoder →
 * NativeImage → GPU path. Classes are NativeImageTransformClass values
 * (0 not sampled, 1 identity, 2 flip x, 3 flip y, 4 rotate 180, 5 rotate 90,
 * 6 rotate 270, 7 transpose, 8 transverse, 9 other, 10 read failed), identity and applied made relative to the
 * ordinary-texture reference; mode is
 * the presentation mode (0 identity, 4 top-left producer). Corners are RGBA
 * read at TL, TR, BL, BR. Strings are platform names limited to
 * [A-Za-z0-9 ._()/-], at most 64 characters.
 */
export interface OrientationSelfTestEvidence {
  codec: number;
  mode: number;
  stage: number;
  platformCode: number;
  hardware: number;
  outputPixelFormat: number;
  outputRotation: number;
  outputTransformType: number;
  bufferTransform: number;
  v2Class: number;
  v1Class: number;
  /** The same picture as an ordinary texture, read back the same way: the readback's own turn (1 = conformant). */
  referenceOrientation: number;
  identityOrientation: number;
  appliedOrientation: number;
  identityCorners: number[];
  appliedCorners: number[];
  elapsedMs: number;
  decoderName: string;
  glVendor: string;
  glRenderer: string;
}

export interface NativeOrientationSelfTest {
  codec?: number;
  mode?: number;
  stage?: number;
  platformCode?: number;
  hardware?: number;
  outputPixelFormat?: number;
  outputRotation?: number;
  outputTransformType?: number;
  bufferTransform?: number;
  v2Class?: number;
  v1Class?: number;
  referenceOrientation?: number;
  identityOrientation?: number;
  appliedOrientation?: number;
  identityCorners0?: number;
  identityCorners1?: number;
  identityCorners2?: number;
  identityCorners3?: number;
  appliedCorners0?: number;
  appliedCorners1?: number;
  appliedCorners2?: number;
  appliedCorners3?: number;
  elapsedMs?: number;
  decoderName?: string;
  glVendor?: string;
  glRenderer?: string;
}

export interface VideoDiagnosticEvidence {
  evidenceVersion: number;
  queuedCodecPreference: number;
  requestedVisualFlipX: number;
  requestedVisualFlipY: number;
  requestedTransformVersion: number;
  moonlightNegotiatedCodec: number;
  moonlightNegotiatedBitDepth: number;
  moonlightActiveStage: number;
  moonlightTerminalCode: number;
  currentCodecPreference: number;
  connectionCodecPreference: number;
  sentCodecPreference: number;
  wireCodecPreference: number;
  advertisedDecoderMask: number;
  peerEncoderMask: number;
  codecOptionStage: number;
  loginOptionSends: number;
  runtimeOptionSubmissions: number;
  codecOptionSendFailures: number;
  firstFrameCodec: number;
  codecChanges: number;
  lastDecodeResult: number;
  decodeRetNotReady: number;
  decodeRetBadCodec: number;
  decodeRetMismatch: number;
  decodeRetOther: number;
  decodedFrames: number;
  presentedFrames: number;
  controlFlipX: number;
  controlFlipY: number;
  flipSource: number;
  observedOrientation: number;
  finalSamplingCorners: number[];
  decoderAttempts: DecoderAttemptEvidence[];
  orientationSelfTests: OrientationSelfTestEvidence[];
}

export interface NativeVideoDiagnosticEvidence {
  queuedCodecPreference?: number;
  requestedVisualFlipX?: number;
  requestedVisualFlipY?: number;
  requestedTransformVersion?: number;
  moonlightNegotiatedCodec?: number;
  moonlightNegotiatedBitDepth?: number;
  moonlightActiveStage?: number;
  moonlightTerminalCode?: number;
  currentCodecPreference?: number;
  connectionCodecPreference?: number;
  sentCodecPreference?: number;
  wireCodecPreference?: number;
  advertisedDecoderMask?: number;
  peerEncoderMask?: number;
  codecOptionStage?: number;
  loginOptionSends?: number;
  runtimeOptionSubmissions?: number;
  codecOptionSendFailures?: number;
  firstFrameCodec?: number;
  codecChanges?: number;
  lastDecodeResult?: number;
  decodeRetNotReady?: number;
  decodeRetBadCodec?: number;
  decodeRetMismatch?: number;
  decodeRetOther?: number;
  presentedFrames?: number;
  decodeOk?: number;
  decoderAttempts?: DecoderAttemptEvidence[];
  orientationSelfTests?: NativeOrientationSelfTest[];
}
