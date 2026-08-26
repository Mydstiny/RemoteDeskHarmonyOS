import { describe, expect, it } from '@ohos/hypium';
import {
  RemoteSessionWindowAuthorizationService,
  remoteSessionWindowAuthorizationMatches
} from '../main/ets/services/RemoteSessionWindowAuthorization';
import {
  REMOTE_SESSION_WINDOW_MIN_HEIGHT_VP,
  REMOTE_SESSION_WINDOW_MIN_WIDTH_VP,
  RemoteSessionWindowProtocol,
  RemoteSessionWindowRequest,
  RemoteSessionWindowTarget,
  remoteSessionWindowPlacement,
  remoteSessionWindowRequestIsValid
} from '../main/ets/services/RemoteSessionWindowPolicy';
import { RemoteSessionConnectionIntent } from '../main/ets/services/RemoteSessionConnectionIntent';
import {
  RemoteSessionWindowReadinessBarrier,
  remoteSessionWindowReadySnapshotIsUsable
} from '../main/ets/services/RemoteSessionWindowReadiness';
import { RemoteProtocol } from '../main/ets/services/RemoteSessionState';
import { ActiveRemoteSessionRecord } from
  '../main/ets/services/ActiveRemoteSessionRegistry';
import {
  nativeFacadeStateAfterDisconnectSubmission,
  nativeDisconnectOwnerMatchesFacade,
  nativeDisconnectReceiptCanReleaseRegistry,
  nativeDisconnectStateIsFailed,
  nativeDisconnectStateIsSuccessful,
  nextRemoteSessionHandoffGeneration,
  RemoteSessionExactDisconnectCallbackPort,
  RemoteSessionExactDisconnectIdentity,
  RemoteSessionExactDisconnectSubmission,
  RemoteSessionLocalHandoffIdentity,
  remoteSessionHandoffFailureOwnsSession,
  remoteSessionLocalHandoffFailureOwnsSession,
  RemoteSessionNativeFacadeState,
  RemoteSessionNativeDisconnectOwner,
  submitRemoteSessionExactDisconnectWithRetry
} from '../main/ets/services/RemoteSessionTerminationPolicy';

function validRdpRequest(token: string): RemoteSessionWindowRequest {
  return {
    target: 'remote_desktop',
    protocol: 'rdp',
    hostId: 'rdp-host-1',
    title: 'RDP',
    authorizationToken: token,
    routeParams: {}
  };
}

function validWindowRequest(target: RemoteSessionWindowTarget,
  protocol: RemoteSessionWindowProtocol, hostId: string,
  token: string): RemoteSessionWindowRequest {
  return {
    target,
    protocol,
    hostId,
    title: protocol.toUpperCase(),
    authorizationToken: token,
    routeParams: {}
  };
}

export default function remoteSessionWindowPolicyTest(): void {
  describe('RemoteSessionWindowPolicy', (): void => {
    it('allows_windows_only_after_native_authentication_not_certificate_preflight', 0, (): void => {
      expect(remoteSessionWindowAuthorizationMatches('rdp', 'rdp_authenticated')).assertTrue();
      expect(remoteSessionWindowAuthorizationMatches('rustdesk', 'rustdesk_authenticated')).assertTrue();
      expect(remoteSessionWindowAuthorizationMatches('vnc', 'vnc_authenticated')).assertTrue();
      expect(remoteSessionWindowAuthorizationMatches('ssh', 'ssh_authenticated')).assertTrue();
      expect(remoteSessionWindowAuthorizationMatches(
        'moonlight', 'moonlight_preflight_complete')).assertTrue();
      expect(remoteSessionWindowAuthorizationMatches('rdp', 'rdp_preflight_complete')).assertFalse();
      expect(remoteSessionWindowAuthorizationMatches('vnc', 'vnc_preflight_complete')).assertFalse();
      expect(remoteSessionWindowAuthorizationMatches('ssh', 'ssh_preflight_complete')).assertFalse();
      expect(remoteSessionWindowAuthorizationMatches('ssh', 'ssh_broker_handoff')).assertFalse();
      expect(remoteSessionWindowAuthorizationMatches('rdp', 'rustdesk_authenticated')).assertFalse();
      expect(remoteSessionWindowAuthorizationMatches('vnc', 'rdp_authenticated')).assertFalse();
    });

    it('requires_a_one_shot_protocol_and_host_bound_authorization', 0, (): void => {
      const service: RemoteSessionWindowAuthorizationService =
        RemoteSessionWindowAuthorizationService.getInstance();
      service.resetForTest();
      const token: string = service.issue('rdp', 'rdp-host-1', 'rdp_authenticated', 100);
      expect(token.length > 0).assertTrue();
      expect(service.consume(token, 'rdp', 'wrong-host', 101)).assertNull();
      expect(service.consume(token, 'rdp', 'rdp-host-1', 102)).assertNull();

      const validToken: string = service.issue(
        'rdp', 'rdp-host-1', 'rdp_authenticated', 200);
      expect(service.consume(validToken, 'rdp', 'rdp-host-1', 201) !== null).assertTrue();
      expect(service.consume(validToken, 'rdp', 'rdp-host-1', 202)).assertNull();

      const expired: string = service.issue(
        'rdp', 'rdp-host-1', 'rdp_authenticated', 300);
      expect(service.consume(expired, 'rdp', 'rdp-host-1', 70000)).assertNull();
      service.resetForTest();
    });

    it('rejects_window_requests_without_proof_or_with_target_protocol_mismatch', 0, (): void => {
      expect(remoteSessionWindowRequestIsValid(validRdpRequest('ticket'))).assertTrue();
      expect(remoteSessionWindowRequestIsValid(validRdpRequest(''))).assertFalse();
      const mismatch: RemoteSessionWindowRequest = validRdpRequest('ticket');
      mismatch.target = 'ssh_terminal';
      expect(remoteSessionWindowRequestIsValid(mismatch)).assertFalse();
    });

    it('accepts_every_supported_protocol_window_target_and_rejects_cross_protocol_routes',
      0, (): void => {
        const supported: Array<RemoteSessionWindowRequest> = [
          validWindowRequest('remote_desktop', 'rdp', 'rdp-host', 'rdp-ticket'),
          validWindowRequest('remote_desktop', 'rustdesk', 'rustdesk-host', 'rustdesk-ticket'),
          validWindowRequest('remote_desktop', 'vnc', 'vnc-host', 'vnc-ticket'),
          validWindowRequest('ssh_terminal', 'ssh', 'ssh-host', 'ssh-ticket'),
          validWindowRequest('moonlight_stream', 'moonlight', 'moonlight-host', 'moonlight-ticket')
        ];
        for (let index: number = 0; index < supported.length; index++) {
          expect(remoteSessionWindowRequestIsValid(supported[index])).assertTrue();
        }
        expect(remoteSessionWindowRequestIsValid(
          validWindowRequest('ssh_terminal', 'rdp', 'ssh-host', 'wrong-target'))).assertFalse();
        expect(remoteSessionWindowRequestIsValid(
          validWindowRequest('moonlight_stream', 'ssh', 'moonlight-host', 'wrong-target'))).assertFalse();
        expect(remoteSessionWindowRequestIsValid(
          validWindowRequest('remote_desktop', 'moonlight', 'rdp-host', 'wrong-target'))).assertFalse();
      });

    it('keeps_settings_connection_intents_credential_free_one_shot_and_expiring', 0, (): void => {
      const intents: RemoteSessionConnectionIntent = RemoteSessionConnectionIntent.getInstance();
      intents.resetForTest();
      expect(intents.put('vnc', 'vnc-host-1', 100)).assertTrue();
      expect(intents.take(101)?.hostId).assertEqual('vnc-host-1');
      expect(intents.take(102)).assertNull();
      expect(intents.put('vnc', 'vnc-host-2', 200)).assertTrue();
      const connectIntent = intents.take(201);
      expect(connectIntent?.reason).assertEqual('connect');
      expect(connectIntent?.replaceSavedCredential).assertFalse();
      expect(intents.put(
        'vnc', 'vnc-host-3', 300, 'authentication_retry', true)).assertTrue();
      const retryIntent = intents.take(301);
      expect(retryIntent?.reason).assertEqual('authentication_retry');
      expect(retryIntent?.replaceSavedCredential).assertTrue();
      expect(intents.put('vnc', 'vnc-host-2', 200)).assertTrue();
      expect(intents.take(20000)).assertNull();
      expect(intents.put('vnc', '  ', 300)).assertFalse();
      intents.resetForTest();
    });

    it('cascades_multiple_windows_without_reusing_one_fixed_position', 0, (): void => {
      const first = remoteSessionWindowPlacement(0);
      const second = remoteSessionWindowPlacement(1);
      expect(first.left === second.left).assertFalse();
      expect(first.top === second.top).assertFalse();
      expect(first.width >= 360).assertTrue();
      expect(first.height >= 480).assertTrue();
    });

    it('converts_vp_window_geometry_to_start_options_pixels_without_minimum_clamping', 0, (): void => {
      const density: number = 2;
      const first = remoteSessionWindowPlacement(0, density);
      const second = remoteSessionWindowPlacement(1, density);
      expect(first.width >= REMOTE_SESSION_WINDOW_MIN_WIDTH_VP * density).assertTrue();
      expect(first.height >= REMOTE_SESSION_WINDOW_MIN_HEIGHT_VP * density).assertTrue();
      expect(first.height).assertEqual(1040);
      expect(second.left > first.left).assertTrue();
      expect(second.top > first.top).assertTrue();
    });

    it('requires_transport_visual_viewport_and_input_before_handoff_commit', 0, (): void => {
      expect(remoteSessionWindowReadySnapshotIsUsable({
        protocolConnected: true,
        visualOwnerAttached: true,
        viewportWidth: 1280,
        viewportHeight: 720,
        inputReady: true
      })).assertTrue();
      expect(remoteSessionWindowReadySnapshotIsUsable({
        protocolConnected: true,
        visualOwnerAttached: false,
        viewportWidth: 1280,
        viewportHeight: 720,
        inputReady: true
      })).assertFalse();
      expect(remoteSessionWindowReadySnapshotIsUsable({
        protocolConnected: true,
        visualOwnerAttached: true,
        viewportWidth: 0,
        viewportHeight: 720,
        inputReady: true
      })).assertFalse();
      expect(remoteSessionWindowReadySnapshotIsUsable({
        protocolConnected: true,
        visualOwnerAttached: true,
        viewportWidth: 1280,
        viewportHeight: 720,
        inputReady: false
      })).assertFalse();
    });

    it('settles_every_source_waiter_only_after_target_ready_or_failure', 0,
      async (): Promise<void> => {
        const readyBarrier: RemoteSessionWindowReadinessBarrier =
          new RemoteSessionWindowReadinessBarrier();
        const firstWaiter: Promise<boolean> = readyBarrier.wait(1000);
        const secondWaiter: Promise<boolean> = readyBarrier.wait(1000);
        expect(readyBarrier.currentState()).assertEqual('waiting');
        expect(readyBarrier.markReady()).assertTrue();
        expect(await firstWaiter).assertTrue();
        expect(await secondWaiter).assertTrue();
        expect(await readyBarrier.wait(1000)).assertTrue();

        const failedBarrier: RemoteSessionWindowReadinessBarrier =
          new RemoteSessionWindowReadinessBarrier();
        const failedWaiter: Promise<boolean> = failedBarrier.wait(1000);
        expect(failedBarrier.fail()).assertTrue();
        expect(await failedWaiter).assertFalse();
        expect(await failedBarrier.wait(1000)).assertFalse();
      });

    it('accepts_only_explicit_native_complete_as_success', 0, (): void => {
      expect(nativeDisconnectStateIsSuccessful(3)).assertTrue();
      expect(nativeDisconnectStateIsSuccessful(0)).assertFalse();
      expect(nativeDisconnectStateIsSuccessful(-1)).assertFalse();
      expect(nativeDisconnectStateIsSuccessful(4)).assertFalse();
      expect(nativeDisconnectStateIsFailed(4)).assertTrue();
      expect(nativeDisconnectStateIsFailed(0)).assertFalse();
      expect(nativeDisconnectReceiptCanReleaseRegistry(true, 3)).assertTrue();
      expect(nativeDisconnectReceiptCanReleaseRegistry(true, 4)).assertFalse();
      expect(nativeDisconnectReceiptCanReleaseRegistry(true, 0)).assertFalse();
      expect(nativeDisconnectReceiptCanReleaseRegistry(false, 3)).assertFalse();
    });

    it('rejects_disconnect_retry_after_facade_or_native_owner_replacement', 0, (): void => {
      const expected: RemoteSessionNativeDisconnectOwner = {
        sessionId: 41, generation: 7, ownerToken: 9, facadeGeneration: 11
      };
      expect(nativeDisconnectOwnerMatchesFacade(expected, expected)).assertTrue();
      expect(nativeDisconnectOwnerMatchesFacade(expected, {
        sessionId: 42, generation: 7, ownerToken: 9, facadeGeneration: 11
      })).assertFalse();
      expect(nativeDisconnectOwnerMatchesFacade(expected, {
        sessionId: 41, generation: 8, ownerToken: 9, facadeGeneration: 11
      })).assertFalse();
      expect(nativeDisconnectOwnerMatchesFacade(expected, {
        sessionId: 41, generation: 7, ownerToken: 10, facadeGeneration: 11
      })).assertFalse();
      expect(nativeDisconnectOwnerMatchesFacade(expected, {
        sessionId: 41, generation: 7, ownerToken: 9, facadeGeneration: 12
      })).assertFalse();
    });

    it('preserves_the_exact_facade_when_native_disconnect_throws_or_rejects', 0, (): void => {
      const active: RemoteSessionNativeFacadeState = {
        sessionId: 41,
        facadeGeneration: 11,
        rendererHandle: 101,
        decoderHandle: 102,
        audioPlayerHandle: 103
      };
      const rejected: RemoteSessionNativeFacadeState =
        nativeFacadeStateAfterDisconnectSubmission(active, false);
      expect(rejected.sessionId).assertEqual(41);
      expect(rejected.facadeGeneration).assertEqual(11);
      expect(rejected.rendererHandle).assertEqual(101);
      expect(rejected.decoderHandle).assertEqual(102);
      expect(rejected.audioPlayerHandle).assertEqual(103);

      const accepted: RemoteSessionNativeFacadeState =
        nativeFacadeStateAfterDisconnectSubmission(active, true);
      expect(accepted.sessionId).assertEqual(-1);
      expect(accepted.facadeGeneration).assertEqual(0);
      expect(accepted.rendererHandle).assertEqual(-1);
      expect(accepted.decoderHandle).assertEqual(-1);
      expect(accepted.audioPlayerHandle).assertEqual(-1);
    });

    it('retries_a_late_2fa_disconnect_with_the_original_identity_after_a_throw', 0,
      (): void => {
        const sessionA: RemoteSessionExactDisconnectIdentity = {
          sessionId: 41,
          generation: 7,
          ownerToken: 9,
          facadeGeneration: 11,
          rendererHandle: 101,
          decoderHandle: 102,
          audioPlayerHandle: 103
        };
        const submittedSessionIds: number[] = [];
        const observedAccepted: boolean[] = [];
        let submitCount: number = 0;
        let scheduledTask: (() => void) | null = null;
        const port: RemoteSessionExactDisconnectCallbackPort =
          new RemoteSessionExactDisconnectCallbackPort(
          (identity: RemoteSessionExactDisconnectIdentity):
            RemoteSessionExactDisconnectSubmission => {
            submittedSessionIds.push(identity.sessionId);
            submitCount += 1;
            if (submitCount === 1) {
              throw new Error('simulated NAPI boundary throw');
            }
            return {
              accepted: true,
              requestId: 17,
              terminal: false,
              successful: false,
              retryable: false
            };
          },
          (_identity: RemoteSessionExactDisconnectIdentity,
            submission: RemoteSessionExactDisconnectSubmission): void => {
            observedAccepted.push(submission.accepted);
          },
          (task: () => void, _delayMs: number): void => {
            scheduledTask = task;
          });

        submitRemoteSessionExactDisconnectWithRetry(sessionA, port, 1, 0);
        // Simulate the process facade moving to session B before the delayed
        // retry. Mutating the caller-owned object must not retarget the retry.
        sessionA.sessionId = 42;
        const retryTask: (() => void) | null = scheduledTask;
        expect(retryTask !== null).assertTrue();
        if (retryTask !== null) { retryTask(); }

        expect(submittedSessionIds.length).assertEqual(2);
        expect(submittedSessionIds[0]).assertEqual(41);
        expect(submittedSessionIds[1]).assertEqual(41);
        expect(observedAccepted.length).assertEqual(2);
        expect(observedAccepted[0]).assertFalse();
        expect(observedAccepted[1]).assertTrue();
      });

    it('rejects_late_failed_handoffs_after_session_or_operation_changes', 0, (): void => {
      const expected: ActiveRemoteSessionRecord = {
        ownerScopeId: 'owner-a', accountGeneration: 7, sessionId: 42,
        hostId: 'host-a', protocol: RemoteProtocol.rustdesk,
        hostAddress: '192.0.2.10', protocolConnected: true,
        renderAttached: false, restoreNeeded: true, latestSurfaceId: '',
        createdAtMs: 100, updatedAtMs: 100
      };
      const newerSession: ActiveRemoteSessionRecord = {
        ownerScopeId: 'owner-a', accountGeneration: 7, sessionId: 43,
        hostId: 'host-a', protocol: RemoteProtocol.rustdesk,
        hostAddress: '192.0.2.10', protocolConnected: true,
        renderAttached: false, restoreNeeded: true, latestSurfaceId: '',
        createdAtMs: 200, updatedAtMs: 200
      };
      const newerAccount: ActiveRemoteSessionRecord = {
        ownerScopeId: 'owner-a', accountGeneration: 8, sessionId: 42,
        hostId: 'host-a', protocol: RemoteProtocol.rustdesk,
        hostAddress: '192.0.2.10', protocolConnected: true,
        renderAttached: false, restoreNeeded: true, latestSurfaceId: '',
        createdAtMs: 200, updatedAtMs: 200
      };
      const operation: number = nextRemoteSessionHandoffGeneration(8);
      expect(remoteSessionHandoffFailureOwnsSession(
        expected, expected, 42, operation, operation)).assertTrue();
      expect(remoteSessionHandoffFailureOwnsSession(
        expected, expected, 42, operation, operation + 1)).assertFalse();
      expect(remoteSessionHandoffFailureOwnsSession(
        expected, newerSession, 43,
        operation, operation)).assertFalse();
      expect(remoteSessionHandoffFailureOwnsSession(
        expected, newerAccount, 42,
        operation, operation)).assertFalse();
      expect(remoteSessionHandoffFailureOwnsSession(
        expected, expected, 43, operation, operation)).assertFalse();
      expect(nextRemoteSessionHandoffGeneration(Number.MAX_SAFE_INTEGER)).assertEqual(1);
    });

    it('rejects_stale_page_binding_and_native_identity_before_ssh_teardown', 0, (): void => {
      const expected: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 3,
        bindingGeneration: 5,
        sessionId: 71,
        sessionGeneration: 9,
        hostId: 'ssh-host-a',
        operationGeneration: 11
      };
      const changedPage: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 4, bindingGeneration: 5, sessionId: 71,
        sessionGeneration: 9, hostId: 'ssh-host-a', operationGeneration: 11
      };
      const changedBinding: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 3, bindingGeneration: 6, sessionId: 71,
        sessionGeneration: 9, hostId: 'ssh-host-a', operationGeneration: 11
      };
      const recycledSession: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 3, bindingGeneration: 5, sessionId: 71,
        sessionGeneration: 10, hostId: 'ssh-host-a', operationGeneration: 11
      };
      const changedHost: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 3, bindingGeneration: 5, sessionId: 71,
        sessionGeneration: 9, hostId: 'ssh-host-b', operationGeneration: 11
      };
      const changedOperation: RemoteSessionLocalHandoffIdentity = {
        pageGeneration: 3, bindingGeneration: 5, sessionId: 71,
        sessionGeneration: 9, hostId: 'ssh-host-a', operationGeneration: 12
      };
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, expected, 71)).assertTrue();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, changedPage, 71)).assertFalse();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, changedBinding, 71)).assertFalse();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, recycledSession, 71)).assertFalse();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, changedHost, 71)).assertFalse();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, changedOperation, 71)).assertFalse();
      expect(remoteSessionLocalHandoffFailureOwnsSession(
        expected, expected, 72)).assertFalse();
    });
  });
}
