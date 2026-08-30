import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightSessionEvent,
  MoonlightSessionStateSnapshot,
  applyMoonlightSessionEvent,
  createMoonlightSessionState,
  moonlightSessionErrorFromNative,
  moonlightSessionTransitionIsAllowed,
  rebaseMoonlightSessionForReconnect
} from '../main/ets/services/MoonlightSessionState';

function initial(): MoonlightSessionStateSnapshot {
  return createMoonlightSessionState('session-1', 'owner-1', 'host-1', 'app-1', 7) as
    MoonlightSessionStateSnapshot;
}

function event(type: MoonlightSessionEvent['type'], sequence: number,
  generation: number = 7, nativeError: string = '', detailCode: string = ''): MoonlightSessionEvent {
  return {
    type: type, generation: generation, sequence: sequence,
    nativeError: nativeError, detailCode: detailCode
  };
}

function apply(state: MoonlightSessionStateSnapshot, type: MoonlightSessionEvent['type'],
  sequence: number): MoonlightSessionStateSnapshot {
  return applyMoonlightSessionEvent(state, event(type, sequence)).state;
}

function negotiating(): MoonlightSessionStateSnapshot {
  let state = initial();
  state = apply(state, 'beginVerification', 1);
  state = apply(state, 'catalogReady', 2);
  state = apply(state, 'launchRequested', 3);
  return apply(state, 'launchAccepted', 4);
}

export default function moonlightSessionStateTest(): void {
  describe('MoonlightSessionState', (): void => {
    it('starts_disconnected_with_no_runtime_material', 0, (): void => {
      const state = initial();
      expect(state.phase).assertEqual('disconnected');
      expect(state.firstFrameSeen).assertFalse();
      expect(state.errorCode).assertEqual('none');
      expect(createMoonlightSessionState('', 'owner', 'host', 'app', 1) === null).assertTrue();
    });

    it('accepts_the_control_plane_sequence_and_rejects_phase_skips', 0, (): void => {
      const state = initial();
      expect(applyMoonlightSessionEvent(state, event('launchRequested', 1)).reason)
        .assertEqual('invalid_transition');
      expect(moonlightSessionTransitionIsAllowed('verifying', 'catalog')).assertTrue();
      expect(moonlightSessionTransitionIsAllowed('negotiating', 'reconnecting')).assertTrue();
      expect(moonlightSessionTransitionIsAllowed('launching', 'reconnecting')).assertTrue();
      expect(negotiating().phase).assertEqual('negotiating');
    });

    it('rebases_reconnect_into_a_fresh_callback_generation', 0, (): void => {
      const source = createMoonlightSessionState('session-1', 'owner-1', 'host-1', 'app-1', 4);
      const discovering = applyMoonlightSessionEvent(source as MoonlightSessionStateSnapshot,
        event('beginDiscovery', 1, 4));
      const verifying = applyMoonlightSessionEvent(discovering.state,
        event('beginVerification', 2, 4));
      const catalog = applyMoonlightSessionEvent(verifying.state,
        event('catalogReady', 3, 4));
      const launching = applyMoonlightSessionEvent(catalog.state,
        event('launchRequested', 4, 4));
      const negotiating = applyMoonlightSessionEvent(launching.state,
        event('launchAccepted', 5, 4));
      const lost = applyMoonlightSessionEvent(negotiating.state,
        event('transportLost', 6, 4));
      const rebound = rebaseMoonlightSessionForReconnect(lost.state, 'session-2', 5);
      expect(rebound !== null).assertTrue();
      expect((rebound as MoonlightSessionStateSnapshot).generation).assertEqual(5);
      expect((rebound as MoonlightSessionStateSnapshot).lastEventSequence).assertEqual(0);
      expect((rebound as MoonlightSessionStateSnapshot).phase).assertEqual('reconnecting');
      expect((rebound as MoonlightSessionStateSnapshot).firstFrameSeen).assertFalse();
      expect(rebaseMoonlightSessionForReconnect(lost.state, 'session-2', 4) === null)
        .assertTrue();
    });

    it('requires_video_before_first_frame_and_all_gates_before_streaming', 0, (): void => {
      let state = negotiating();
      expect(applyMoonlightSessionEvent(state, event('firstFrameRendered', 5)).reason)
        .assertEqual('video_not_ready');
      state = apply(state, 'videoReady', 5);
      state = apply(state, 'firstFrameRendered', 6);
      expect(applyMoonlightSessionEvent(state, event('streamStable', 7)).reason)
        .assertEqual('media_not_ready');
      state = apply(state, 'audioReady', 7);
      state = apply(state, 'inputReady', 8);
      const streaming = applyMoonlightSessionEvent(state, event('streamStable', 9));
      expect(streaming.applied).assertTrue();
      expect(streaming.state.phase).assertEqual('streaming');
    });

    it('drops_late_generation_and_duplicate_sequence_without_mutation', 0, (): void => {
      const state = initial();
      const staleGeneration = applyMoonlightSessionEvent(state, event('beginDiscovery', 1, 6));
      expect(staleGeneration.reason).assertEqual('stale_generation');
      const started = applyMoonlightSessionEvent(state, event('beginDiscovery', 1));
      const duplicate = applyMoonlightSessionEvent(started.state, event('beginVerification', 1));
      expect(duplicate.reason).assertEqual('stale_sequence');
      expect(duplicate.state.phase).assertEqual('discovering');
    });

    it('resets_media_gates_on_reconnect_and_demands_a_new_first_frame', 0, (): void => {
      let state = negotiating();
      state = apply(state, 'videoReady', 5);
      state = apply(state, 'audioReady', 6);
      state = apply(state, 'inputReady', 7);
      state = apply(state, 'firstFrameRendered', 8);
      state = apply(state, 'streamStable', 9);
      state = apply(state, 'transportLost', 10);
      expect(state.phase).assertEqual('reconnecting');
      expect(state.reconnectAttempt).assertEqual(1);
      expect(state.firstFrameSeen).assertFalse();
      expect(applyMoonlightSessionEvent(state, event('streamStable', 11)).reason)
        .assertEqual('media_not_ready');
    });

    it('makes_cancel_and_stop_terminal_and_idempotent_at_the_boundary', 0, (): void => {
      let state = apply(initial(), 'beginDiscovery', 1);
      state = applyMoonlightSessionEvent(state, event('cancelled', 2)).state;
      expect(state.phase).assertEqual('stopping');
      expect(state.errorCode).assertEqual('cancelled');
      state = applyMoonlightSessionEvent(state, event('stopped', 3)).state;
      expect(state.phase).assertEqual('disconnected');
      expect(applyMoonlightSessionEvent(state, event('stopped', 4)).reason)
        .assertEqual('already_terminal');
    });

    it('maps_native_errors_to_stable_user_facing_codes', 0, (): void => {
      expect(moonlightSessionErrorFromNative('TRUST_CONFLICT')).assertEqual('certificate_changed');
      expect(moonlightSessionErrorFromNative('FIRST_FRAME_TIMEOUT')).assertEqual('stream_timeout');
      expect(moonlightSessionErrorFromNative('unexpected-code')).assertEqual('internal');
    });

    it('records_each_degradation_once_without_changing_phase', 0, (): void => {
      let state = apply(initial(), 'beginVerification', 1);
      state = applyMoonlightSessionEvent(state,
        event('capabilityDegraded', 2, 7, '', 'audio_stereo_fallback')).state;
      state = applyMoonlightSessionEvent(state,
        event('capabilityDegraded', 3, 7, '', 'audio_stereo_fallback')).state;
      expect(state.phase).assertEqual('verifying');
      expect(state.degradationReasons.length).assertEqual(1);
    });
  });
}
