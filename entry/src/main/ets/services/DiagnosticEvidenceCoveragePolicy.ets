import { DiagnosticCaptureEvent, FrozenDiagnosticCapture } from './DiagnosticCaptureRuntime';
import { DiagnosticModuleId } from './DiagnosticCapturePolicy';
import { DiagnosticRdpGraphicsFacts } from './RdpGraphicsEvidencePolicy';

/**
 * Evidence coverage of one frozen capture. A capture is "complete" only when
 * every selected module produced events and every question the RDP/RustDesk
 * evidence is meant to answer has an observed answer. Anything else is listed
 * explicitly so neither a reader nor the AI assistant mistakes silence for a
 * negative result. Computed purely from the exported events, so a JSONL
 * validator can recompute and compare it.
 */
export type DiagnosticModuleCoverage = 'observed' | 'no_events';

export type DiagnosticMissingEvidence =
  'capture_events_dropped' |
  'rdp_activity_unobserved' |
  'rdp_graphics_native_missing' |
  'rdp_gfx_caps_unconfirmed' |
  'rdp_wire_codec_unobserved' |
  'rustdesk_activity_unobserved' |
  'rustdesk_quality_unconfirmed' |
  'rustdesk_direct_stage_unresolved';

export interface DiagnosticEvidenceCoverage {
  coverageVersion: number;
  coverageComplete: boolean;
  moduleCoverage: Record<string, DiagnosticModuleCoverage>;
  missingEvidence: DiagnosticMissingEvidence[];
}

export const DIAGNOSTIC_EVIDENCE_COVERAGE_VERSION: number = 1;

/** Catalog order; the exported list always follows it. */
const MISSING_EVIDENCE_ORDER: DiagnosticMissingEvidence[] = [
  'capture_events_dropped', 'rdp_activity_unobserved', 'rdp_graphics_native_missing',
  'rdp_gfx_caps_unconfirmed', 'rdp_wire_codec_unobserved', 'rustdesk_activity_unobserved',
  'rustdesk_quality_unconfirmed', 'rustdesk_direct_stage_unresolved'
];

/** Plain-language meaning of each gap, for readers and the AI assistant. */
export function diagnosticMissingEvidenceDescription(code: DiagnosticMissingEvidence): string {
  switch (code) {
    case 'capture_events_dropped': return '抓取期间有事件因容量上限被丢弃，时间线不完整';
    case 'rdp_activity_unobserved': return '选择了 RDP 模块，但抓取期间没有任何 RDP 事件（可能没有连接）';
    case 'rdp_graphics_native_missing': return 'RDP 有运行快照，但原生层没有上报图形协商证据';
    case 'rdp_gfx_caps_unconfirmed': return '客户端请求了 GFX，但没有服务端能力确认，协商结果未确认';
    case 'rdp_wire_codec_unobserved': return 'GFX 通道已连接，但没有观测到 GFX 帧，线上编码未确认';
    case 'rustdesk_activity_unobserved': return '选择了 RustDesk 模块，但抓取期间没有任何 RustDesk 事件（可能没有发起连接）';
    case 'rustdesk_quality_unconfirmed': return '画质切换已请求，但抓取结束前没有得到远端码率结论';
    case 'rustdesk_direct_stage_unresolved': return 'RustDesk 连接已开始，但抓取结束前没有成功或失败阶段';
    default: return '';
  }
}

export function diagnosticMissingEvidenceIsKnown(code: string): boolean {
  return MISSING_EVIDENCE_ORDER.indexOf(code as DiagnosticMissingEvidence) >= 0;
}

function isCaptureMarker(event: DiagnosticCaptureEvent): boolean {
  return event.moduleId === 'core.app' && event.eventCode.indexOf('capture_') === 0;
}

export function diagnosticEvidenceCoverage(capture: FrozenDiagnosticCapture): DiagnosticEvidenceCoverage {
  const moduleCoverage: Record<string, DiagnosticModuleCoverage> = {};
  const missing: DiagnosticMissingEvidence[] = [];
  for (let index: number = 0; index < capture.selectedModules.length; index++) {
    moduleCoverage[capture.selectedModules[index]] = 'no_events';
  }
  let rdpEvents: number = 0;
  let rdpRuntimeEvents: number = 0;
  let rdpNativeGraphics: boolean = false;
  let rdpGfxRequested: boolean = false;
  let rdpCapsConfirmed: boolean = false;
  let rdpChannelConnected: boolean = false;
  let rdpWireCodecObserved: boolean = false;
  let rustDeskEvents: number = 0;
  let qualityOpen: number = 0;
  let directOpen: number = 0;
  for (let index: number = 0; index < capture.events.length; index++) {
    const event: DiagnosticCaptureEvent = capture.events[index];
    if (!isCaptureMarker(event) && moduleCoverage[event.moduleId] !== undefined) {
      moduleCoverage[event.moduleId] = 'observed';
    }
    if (event.moduleId === 'connection.rdp') {
      rdpEvents++;
      if (event.eventCode === 'rdp_runtime_snapshot' || event.eventCode === 'rdp_graphics_negotiation') {
        rdpRuntimeEvents++;
        const graphics: DiagnosticRdpGraphicsFacts | undefined = event.runtime.rdpGraphics;
        if (graphics !== undefined && graphics.evidenceLevel !== 'missing') {
          rdpNativeGraphics = true;
          rdpGfxRequested = rdpGfxRequested || graphics.requestedMode === 'gfx' ||
            graphics.requestedMode === 'gfx-h264';
          rdpCapsConfirmed = rdpCapsConfirmed || graphics.capsConfirmed;
          rdpChannelConnected = rdpChannelConnected || graphics.gfxChannelConnected;
          rdpWireCodecObserved = rdpWireCodecObserved || graphics.wireCodec !== 'none';
        }
      }
    } else if (event.moduleId === 'connection.rustdesk') {
      rustDeskEvents++;
      if (event.eventCode === 'rustdesk_quality_request' && event.outcome === 'started') {
        qualityOpen++;
      } else if (event.eventCode === 'rustdesk_quality_result' && qualityOpen > 0) {
        qualityOpen--;
      } else if (event.eventCode === 'rustdesk_direct_stage') {
        if (event.outcome === 'started') {
          directOpen++;
        } else if ((event.outcome === 'succeeded' || event.outcome === 'failed' ||
          event.outcome === 'cancelled') && event.code !== 1 && directOpen > 0) {
          // code 1 is a local validation failure that never opened an attempt.
          directOpen--;
        }
      }
    }
  }
  const selected = (moduleId: DiagnosticModuleId): boolean =>
    capture.selectedModules.indexOf(moduleId) >= 0;
  if (capture.droppedEventCount > 0) { missing.push('capture_events_dropped'); }
  if (selected('connection.rdp') && rdpEvents === 0) { missing.push('rdp_activity_unobserved'); }
  if (rdpRuntimeEvents > 0 && !rdpNativeGraphics) { missing.push('rdp_graphics_native_missing'); }
  if (rdpGfxRequested && !rdpCapsConfirmed) { missing.push('rdp_gfx_caps_unconfirmed'); }
  if (rdpChannelConnected && !rdpWireCodecObserved) { missing.push('rdp_wire_codec_unobserved'); }
  if (selected('connection.rustdesk') && rustDeskEvents === 0) {
    missing.push('rustdesk_activity_unobserved');
  }
  if (qualityOpen > 0) { missing.push('rustdesk_quality_unconfirmed'); }
  if (directOpen > 0) { missing.push('rustdesk_direct_stage_unresolved'); }
  const ordered: DiagnosticMissingEvidence[] = MISSING_EVIDENCE_ORDER.filter(
    (code: DiagnosticMissingEvidence): boolean => missing.indexOf(code) >= 0);
  let allObserved: boolean = true;
  const keys: string[] = Object.keys(moduleCoverage);
  for (let index: number = 0; index < keys.length; index++) {
    // core.app always records its own start/stop markers; it never makes a
    // capture incomplete on its own.
    if (keys[index] !== 'core.app' && moduleCoverage[keys[index]] !== 'observed') {
      allObserved = false;
    }
  }
  return {
    coverageVersion: DIAGNOSTIC_EVIDENCE_COVERAGE_VERSION,
    coverageComplete: allObserved && ordered.length === 0,
    moduleCoverage: moduleCoverage,
    missingEvidence: ordered
  };
}
