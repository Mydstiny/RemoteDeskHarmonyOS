import { describe, expect, it } from '@ohos/hypium';
import {
  RUSTDESK_QUALITY_CONFIRM_WINDOW_MS,
  RUSTDESK_QUALITY_SEND_TIMEOUT_MS,
  RustDeskQualityConfirmation,
  RustDeskQualityEvaluation,
  RustDeskQualitySample,
  beginRustDeskQualityConfirmation,
  evaluateRustDeskQualityConfirmation,
  rustDeskQualityVerdictIsFinal,
  rustDeskQualityVerdictMessage
} from '../main/ets/services/RustDeskQualityConfirmationPolicy';
import {
  RUSTDESK_QUALITY_RESULT_NOT_REPORTED,
  RUSTDESK_QUALITY_RESULT_RAISED,
  rustDeskQualityResultCode
} from '../main/ets/services/RustDeskDiagnosticEvents';

function sample(bitrate: number, testDelays: number, sentQuality: number,
  requested: number, applied: number, status: number): RustDeskQualitySample {
  return {
    sessionActive: true, targetBitrateKbps: bitrate, testDelayCount: testDelays,
    sentImageQuality: sentQuality, qualityRequestedGeneration: requested,
    qualityAppliedGeneration: applied, qualityUpdateStatus: status
  };
}

export default function rustDeskQualityConfirmationPolicyTest(): void {
  describe('RustDeskQualityConfirmationPolicy', () => {
    it('waits for the native send and then for a TestDelay report after it', 0, () => {
      const state: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 1000, sample(4000, 10, 1, 3, 3, 2));
      expect(state.requestGeneration).assertEqual(4);
      let result: RustDeskQualityEvaluation =
        evaluateRustDeskQualityConfirmation(state, sample(4000, 10, 1, 4, 3, 1), 1500);
      expect(result.verdict).assertEqual('pending');
      // Sent, but the bitrate sample predates the change: not yet evidence.
      result = evaluateRustDeskQualityConfirmation(state, sample(6000, 10, 2, 4, 4, 2), 2000);
      expect(result.verdict).assertEqual('pending');
      result = evaluateRustDeskQualityConfirmation(state, sample(6000, 11, 2, 4, 4, 2), 4000);
      expect(result.verdict).assertEqual('bitrate_raised');
      expect(rustDeskQualityVerdictMessage(2, result)).assertEqual('画质优先：远端码率 4 Mbps → 6 Mbps');
      expect(rustDeskQualityResultCode(result.verdict)).assertEqual(RUSTDESK_QUALITY_RESULT_RAISED);
    });

    it('reports unchanged only after two post-send reports and ignores small jitter', 0, () => {
      const state: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(0, 0, sample(5000, 20, 1, 7, 7, 2));
      let result: RustDeskQualityEvaluation =
        evaluateRustDeskQualityConfirmation(state, sample(5000, 20, 0, 8, 8, 2), 1000);
      result = evaluateRustDeskQualityConfirmation(state, sample(5100, 21, 0, 8, 8, 2), 3000);
      expect(result.verdict).assertEqual('pending');
      result = evaluateRustDeskQualityConfirmation(state, sample(5100, 22, 0, 8, 8, 2), 5000);
      expect(result.verdict).assertEqual('bitrate_unchanged');
      expect(rustDeskQualityVerdictIsFinal(result.verdict)).assertTrue();
    });

    it('never claims success when the peer does not report a bitrate', 0, () => {
      const state: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 0, sample(0, 0, 1, 0, 0, 0));
      let result: RustDeskQualityEvaluation =
        evaluateRustDeskQualityConfirmation(state, sample(0, 0, 2, 1, 1, 2), 1000);
      expect(result.verdict).assertEqual('pending');
      result = evaluateRustDeskQualityConfirmation(state, sample(0, 0, 2, 1, 1, 2),
        RUSTDESK_QUALITY_CONFIRM_WINDOW_MS);
      expect(result.verdict).assertEqual('not_reported');
      expect(rustDeskQualityResultCode(result.verdict)).assertEqual(RUSTDESK_QUALITY_RESULT_NOT_REPORTED);
      expect(rustDeskQualityVerdictMessage(2, result))
        .assertEqual('画质优先已发送，远端未报告码率，无法确认是否生效');
    });

    it('fails a send that the native lane rejected or never completed', 0, () => {
      const rejected: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 0, sample(4000, 3, 1, 1, 1, 2));
      expect(evaluateRustDeskQualityConfirmation(rejected, sample(4000, 3, 1, 2, 1, 3), 500).verdict)
        .assertEqual('send_failed');
      const stuck: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 0, sample(4000, 3, 1, 1, 1, 2));
      expect(evaluateRustDeskQualityConfirmation(stuck, sample(4000, 3, 1, 2, 1, 1),
        RUSTDESK_QUALITY_SEND_TIMEOUT_MS).verdict).assertEqual('send_failed');
      const live: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 0, sample(4000, 3, 1, 1, 1, 2));
      const ended: RustDeskQualitySample = sample(4000, 3, 1, 2, 1, 1);
      ended.sessionActive = false;
      // One failed diagnostics read is a blip, not a failed send.
      expect(evaluateRustDeskQualityConfirmation(live, ended, 100).verdict).assertEqual('pending');
      expect(evaluateRustDeskQualityConfirmation(live, sample(4000, 3, 1, 2, 1, 1), 200).verdict)
        .assertEqual('pending');
      expect(evaluateRustDeskQualityConfirmation(live, ended, 300).verdict).assertEqual('pending');
      expect(evaluateRustDeskQualityConfirmation(live, ended, 400).verdict).assertEqual('send_failed');
    });

    it('does not attribute a newer request result to a superseded one', 0, () => {
      const state: RustDeskQualityConfirmation =
        beginRustDeskQualityConfirmation(2, 0, sample(4000, 3, 1, 1, 1, 2));
      // A newer request (generation 3, quality 0) was sent; this state wanted quality 2.
      const result: RustDeskQualityEvaluation =
        evaluateRustDeskQualityConfirmation(state, sample(2000, 6, 0, 3, 3, 2), 1000);
      expect(result.verdict).assertEqual('pending');
    });
  });
}
