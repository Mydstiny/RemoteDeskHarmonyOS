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
}
