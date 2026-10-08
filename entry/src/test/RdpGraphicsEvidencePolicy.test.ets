import { describe, expect, it } from '@ohos/hypium';
import { RdpGfxEvidenceStats, RdpRenderStats } from '../main/ets/types/rdpnapi';
import { EMPTY_RDP_RENDER_STATS } from '../main/ets/components/RdpDiagnosticsHud';
import {
  DiagnosticRdpGraphicsFacts,
  copyDiagnosticRdpGraphicsFacts,
  diagnosticRdpGraphicsFactsAreValid,
  parseDiagnosticRdpGraphicsFacts,
  rdpGraphicsFactsFromRenderStats,
  rdpGraphicsPresentationLabel,
  rdpH264StatusLabel,
  rdpWireCodecLabel
} from '../main/ets/services/RdpGraphicsEvidencePolicy';

function gfxEvidence(): RdpGfxEvidenceStats {
  return {
    requestedApplied: true, compiledGfx: true, compiledH264: true, h264PathSafe: false,
    supportGraphicsPipeline: true, remoteFxCodec: true, h264Advertised: false,
    fallbackConsumed: false, fallbackReason: '', capsAdvertisedCount: 6,
    capsAdvertisedMaxVersion: '10.7', capsAdvertisedAvc: false, capsConfirmed: false,
    capsConfirmedVersion: 'unknown', capsConfirmedFlags: 0, capsConfirmedAvc: false,
    surfaceCommands: 0, surfaceCommandBytes: 0, avcSurfaceCommands: 0,
    unknownCodecCommands: 0, wireCodecMask: 0, wireCodec: 'none'
  };
}

function stats(gfx: RdpGfxEvidenceStats | undefined, mode: string,
  channelConnected: boolean): RdpRenderStats {
  const result: RdpRenderStats = JSON.parse(JSON.stringify(EMPTY_RDP_RENDER_STATS)) as RdpRenderStats;
  result.graphicsMode = mode;
  result.gfxChannelConnected = channelConnected;
  result.copiedBytes = 8294400;
  result.gfxEvidence = gfx;
  return result;
}

export default function rdpGraphicsEvidencePolicyTest(): void {
  describe('RdpGraphicsEvidencePolicy', () => {
    it('keeps missing native evidence distinct from an observed codec', 0, () => {
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(undefined, 'unknown', false));
      expect(facts.evidenceLevel).assertEqual('missing');
      expect(facts.wireCodec).assertEqual('none');
      expect(facts.h264Status).assertEqual('unknown');
      expect(diagnosticRdpGraphicsFactsAreValid(facts)).assertTrue();
    });

    it('labels a requested GFX mode without wire evidence as configured, not observed', 0, () => {
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfxEvidence(), 'gfx', false));
      expect(facts.evidenceLevel).assertEqual('configured');
      expect(facts.requestedMode).assertEqual('gfx');
      expect(facts.presentation).assertEqual('gdi_bgra');
      expect(facts.h264Status).assertEqual('gated_off');
      expect(facts.copiedBytes).assertEqual(8294400);
      expect(facts.wireBytes).assertEqual(0);
      expect(rdpGraphicsPresentationLabel(facts)).assertEqual('GFX 未连接（GDI 呈现）');
      expect(rdpWireCodecLabel(facts)).assertEqual('无 GFX 帧（GDI 位图）');
    });

    it('reports the observed RemoteFX wire codec and server-disabled AVC', 0, () => {
      const gfx: RdpGfxEvidenceStats = gfxEvidence();
      gfx.capsConfirmed = true;
      gfx.capsConfirmedVersion = '10.7';
      gfx.capsConfirmedAvc = false;
      gfx.surfaceCommands = 120;
      gfx.surfaceCommandBytes = 640000;
      gfx.wireCodec = 'remotefx';
      gfx.wireCodecMask = 1 << 3;
      gfx.h264Advertised = true;
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gfx-h264', true));
      expect(facts.evidenceLevel).assertEqual('observed_native');
      expect(facts.presentation).assertEqual('gfx_gdi_consumer');
      expect(facts.wireCodec).assertEqual('remotefx');
      expect(facts.wireBytes).assertEqual(640000);
      expect(facts.h264Status).assertEqual('server_disabled');
      expect(rdpH264StatusLabel(facts)).assertEqual('服务端确认不使用');
      expect(diagnosticRdpGraphicsFactsAreValid(facts)).assertTrue();
    });

    it('claims H.264 only after AVC surface commands are observed', 0, () => {
      const gfx: RdpGfxEvidenceStats = gfxEvidence();
      gfx.h264Advertised = true;
      gfx.capsConfirmed = true;
      gfx.capsConfirmedVersion = '10.7';
      gfx.capsConfirmedAvc = true;
      const allowed: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gfx-h264', true));
      expect(allowed.h264Status).assertEqual('allowed_not_used');
      gfx.surfaceCommands = 10;
      gfx.avcSurfaceCommands = 9;
      gfx.wireCodec = 'avc420';
      const used: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gfx-h264', true));
      expect(used.h264Status).assertEqual('in_use');
      expect(rdpWireCodecLabel(used)).assertEqual('H.264 AVC420');
    });

    it('closes unknown native strings and records the scoped fallback reason', 0, () => {
      const gfx: RdpGfxEvidenceStats = gfxEvidence();
      gfx.fallbackConsumed = true;
      gfx.fallbackReason = 'resize-failed';
      gfx.capsAdvertisedMaxVersion = '99.9';
      gfx.surfaceCommands = 3;
      gfx.wireCodec = 'some-new-codec';
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gdi', false));
      expect(facts.fallbackReason).assertEqual('resize-failed');
      expect(facts.capsAdvertisedMaxVersion).assertEqual('unknown');
      expect(facts.wireCodec).assertEqual('unknown');
      expect(rdpGraphicsPresentationLabel(facts)).assertEqual('GFX 未连接（本次回退 GDI）');
      gfx.fallbackReason = 'host=10.0.0.1';
      expect(rdpGraphicsFactsFromRenderStats(stats(gfx, 'gdi', false)).fallbackReason)
        .assertEqual('unknown');
    });

    it('keeps frames with only out-of-catalog codec ids as unknown evidence', 0, () => {
      const gfx: RdpGfxEvidenceStats = gfxEvidence();
      gfx.surfaceCommands = 5;
      gfx.unknownCodecCommands = 5;
      gfx.wireCodec = 'none';
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gfx', true));
      expect(facts.wireCodec).assertEqual('unknown');
      expect(facts.evidenceLevel).assertEqual('observed_native');
      expect(diagnosticRdpGraphicsFactsAreValid(facts)).assertTrue();
    });

    it('round-trips through the strict parser and rejects inconsistent or extra fields', 0, () => {
      const gfx: RdpGfxEvidenceStats = gfxEvidence();
      gfx.capsConfirmed = true;
      gfx.capsConfirmedVersion = '10.7';
      gfx.surfaceCommands = 4;
      gfx.wireCodec = 'planar';
      const facts: DiagnosticRdpGraphicsFacts = rdpGraphicsFactsFromRenderStats(
        stats(gfx, 'gfx', true));
      const parsed: DiagnosticRdpGraphicsFacts | null =
        parseDiagnosticRdpGraphicsFacts(JSON.parse(JSON.stringify(facts)) as Object);
      expect(parsed !== null).assertTrue();
      expect(JSON.stringify(parsed)).assertEqual(JSON.stringify(copyDiagnosticRdpGraphicsFacts(facts)));

      const extra: Record<string, Object> = JSON.parse(JSON.stringify(facts)) as Record<string, Object>;
      extra['host'] = '10.0.0.1';
      expect(parseDiagnosticRdpGraphicsFacts(extra as Object) === null).assertTrue();

      const forged: DiagnosticRdpGraphicsFacts = copyDiagnosticRdpGraphicsFacts(facts);
      forged.h264Status = 'in_use';
      expect(diagnosticRdpGraphicsFactsAreValid(forged)).assertFalse();
      const codecWithoutFrames: DiagnosticRdpGraphicsFacts = copyDiagnosticRdpGraphicsFacts(facts);
      codecWithoutFrames.surfaceCommands = 0;
      codecWithoutFrames.avcSurfaceCommands = 0;
      expect(diagnosticRdpGraphicsFactsAreValid(codecWithoutFrames)).assertFalse();
    });
  });
}
