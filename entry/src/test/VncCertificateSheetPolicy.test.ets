import { describe, it, expect } from '@ohos/hypium';
import {
  nextVncCertificateSheetGeneration,
  shouldApplyVncCertificateSheetResult,
  shouldClearVncCertificateSensitiveHandoffs,
  shouldKeepVncCertificateSheetOpen,
  shouldRouteVncAfterCertificateSheetDisappear,
  shouldShowVncCertificateSheet,
  vncCertificateDecisionForSheetAction,
  vncCertificateSheetActionAllowed,
  VncCertificateSheetAction,
  VncCertificateSheetAttempt
} from '../main/ets/services/VncCertificateSheetPolicy';
import {
  VncCertificatePreflightDecision,
  VncCertificatePreflightState
} from '../main/ets/services/VncCertificatePreflightPolicy';

function attempt(): VncCertificateSheetAttempt {
  return { sheetGeneration: 2, probeGeneration: 4, connectionAttemptGeneration: 9 };
}

export default function vncCertificateSheetPolicyTest(): void {
  describe('VncCertificateSheetPolicy', (): void => {
    it('allocates_nonzero_sheet_generations_and_rejects_stale_results', 0, (): void => {
      expect(nextVncCertificateSheetGeneration(0)).assertEqual(1);
      expect(nextVncCertificateSheetGeneration(-1)).assertEqual(1);
      expect(nextVncCertificateSheetGeneration(Number.MAX_SAFE_INTEGER)).assertEqual(1);
      const active: VncCertificateSheetAttempt = attempt();
      expect(shouldApplyVncCertificateSheetResult(active, attempt())).assertTrue();
      const staleProbe: VncCertificateSheetAttempt = attempt();
      staleProbe.probeGeneration = 3;
      expect(shouldApplyVncCertificateSheetResult(active, staleProbe)).assertFalse();
      const staleAttempt: VncCertificateSheetAttempt = attempt();
      staleAttempt.connectionAttemptGeneration = 8;
      expect(shouldApplyVncCertificateSheetResult(active, staleAttempt)).assertFalse();
      const staleSheet: VncCertificateSheetAttempt = attempt();
      staleSheet.sheetGeneration = 1;
      expect(shouldApplyVncCertificateSheetResult(active, staleSheet)).assertFalse();
    });

    it('opens_only_for_actionable_preflight_states', 0, (): void => {
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.PROBING, false, false))
        .assertTrue();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.TRUST_FIRST_TIME, false, false))
        .assertTrue();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.CERTIFICATE_CHANGED, false, false))
        .assertTrue();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.ERROR, false, false))
        .assertTrue();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.TRUSTED_MATCH, false, false))
        .assertFalse();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.ERROR, true, false))
        .assertFalse();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.ERROR, false, true))
        .assertFalse();
      expect(shouldShowVncCertificateSheet(VncCertificatePreflightState.CLOSING, false, false))
        .assertFalse();
    });

    it('keeps_probe_sheet_modal_until_a_decision_or_close', 0, (): void => {
      expect(shouldKeepVncCertificateSheetOpen(VncCertificatePreflightState.PROBING, false))
        .assertTrue();
      expect(shouldKeepVncCertificateSheetOpen(VncCertificatePreflightState.TRUST_FIRST_TIME, false))
        .assertTrue();
      expect(shouldKeepVncCertificateSheetOpen(VncCertificatePreflightState.TRUSTED_MATCH, false))
        .assertFalse();
      expect(shouldKeepVncCertificateSheetOpen(VncCertificatePreflightState.CLOSING, true))
        .assertTrue();
    });

    it('allows_only_safe_actions_for_each_state', 0, (): void => {
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.PROBING, VncCertificateSheetAction.CANCEL)).assertTrue();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.PROBING, VncCertificateSheetAction.TRUST)).assertFalse();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.ERROR, VncCertificateSheetAction.RETRY)).assertTrue();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.ERROR, VncCertificateSheetAction.CONTINUE_ONCE)).assertFalse();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.TRUST_FIRST_TIME, VncCertificateSheetAction.CONTINUE_ONCE)).assertTrue();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.TRUST_FIRST_TIME, VncCertificateSheetAction.TRUST)).assertTrue();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.CERTIFICATE_CHANGED, VncCertificateSheetAction.TRUST)).assertFalse();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.CERTIFICATE_CHANGED, VncCertificateSheetAction.UPDATE_TRUST)).assertTrue();
      expect(vncCertificateSheetActionAllowed(
        VncCertificatePreflightState.CLOSING, VncCertificateSheetAction.CANCEL)).assertFalse();
    });

    it('maps_only_confirmed_actions_to_preflight_decisions', 0, (): void => {
      expect(vncCertificateDecisionForSheetAction(
        VncCertificatePreflightState.TRUST_FIRST_TIME,
        VncCertificateSheetAction.CONTINUE_ONCE))
        .assertEqual(VncCertificatePreflightDecision.CONTINUE_ONCE);
      expect(vncCertificateDecisionForSheetAction(
        VncCertificatePreflightState.TRUST_FIRST_TIME,
        VncCertificateSheetAction.TRUST))
        .assertEqual(VncCertificatePreflightDecision.TRUST);
      expect(vncCertificateDecisionForSheetAction(
        VncCertificatePreflightState.CERTIFICATE_CHANGED,
        VncCertificateSheetAction.TRUST)).assertEqual(null);
      expect(vncCertificateDecisionForSheetAction(
        VncCertificatePreflightState.ERROR,
        VncCertificateSheetAction.RETRY)).assertEqual(null);
      expect(vncCertificateDecisionForSheetAction(
        VncCertificatePreflightState.PROBING,
        VncCertificateSheetAction.CANCEL))
        .assertEqual(VncCertificatePreflightDecision.CANCEL);
    });

    it('routes_only_after_on_disappear_and_clears_sensitive_handoffs', 0, (): void => {
      expect(shouldRouteVncAfterCertificateSheetDisappear(true, false, true)).assertFalse();
      expect(shouldRouteVncAfterCertificateSheetDisappear(false, true, true)).assertFalse();
      expect(shouldRouteVncAfterCertificateSheetDisappear(false, false, true)).assertTrue();
      expect(shouldRouteVncAfterCertificateSheetDisappear(false, false, false)).assertFalse();
      expect(shouldClearVncCertificateSensitiveHandoffs(true, false, false)).assertTrue();
      expect(shouldClearVncCertificateSensitiveHandoffs(false, true, false)).assertTrue();
      expect(shouldClearVncCertificateSensitiveHandoffs(false, false, true)).assertTrue();
      expect(shouldClearVncCertificateSensitiveHandoffs(false, false, false)).assertFalse();
    });
  });
}
