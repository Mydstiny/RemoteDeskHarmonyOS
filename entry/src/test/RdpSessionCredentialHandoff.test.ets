import { describe, it, expect } from '@ohos/hypium';
import {
  RDP_SESSION_CREDENTIAL_HANDOFF_ABSOLUTE_TTL_MS,
  RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS,
  RdpSessionCredentialHandoff
} from '../main/ets/services/RdpSessionCredentialHandoff';

export default function rdpSessionCredentialHandoffTest(): void {
  describe('RdpSessionCredentialHandoff', (): void => {
    it('allows_preflight_peek_then_consumes_exactly_once', 0, (): void => {
      const handoff: RdpSessionCredentialHandoff =
        RdpSessionCredentialHandoff.getInstance();
      handoff.clearAll();
      expect(handoff.put('owner-a', 'host-a', 'DOMAIN\\user', 'secret',
        'rdp-route-v2|route-a', 'owner-a', 7, 13)).assertTrue();
      expect(handoff.peekDecision('owner-a', 'host-a', 'rdp-route-v2|route-a',
        'owner-a', 7, 13)?.username).assertEqual('DOMAIN\\user');
      expect(handoff.peekDecision('owner-a', 'host-a', 'rdp-route-v2|route-a',
        'owner-a', 7, 13)?.password).assertEqual('secret');
      expect(handoff.takeDecision('owner-a', 'host-a', 'rdp-route-v2|route-a',
        'owner-a', 7, 13)?.password).assertEqual('secret');
      expect(handoff.takeDecision('owner-a', 'host-a', 'rdp-route-v2|route-a',
        'owner-a', 7, 13)).assertNull();
    });

    it('isolates_hosts_accounts_generations_and_routes', 0, (): void => {
      const handoff: RdpSessionCredentialHandoff =
        RdpSessionCredentialHandoff.getInstance();
      handoff.clearAll();
      expect(handoff.put('owner-a', 'host-a', 'user', 'secret',
        'route-a', 'owner-a', 8, 21)).assertTrue();
      expect(handoff.peekDecision('owner-b', 'host-a', 'route-a',
        'owner-a', 8, 21)).assertNull();
      expect(handoff.peekDecision('owner-a', 'host-b', 'route-a',
        'owner-a', 8, 21)).assertNull();
      expect(handoff.peekDecision('owner-a', 'host-a', 'route-b',
        'owner-a', 8, 21)).assertNull();
      expect(handoff.peekDecision('owner-a', 'host-a', 'route-a',
        'owner-a', 9, 21)).assertNull();
      expect(handoff.peekDecision('owner-a', 'host-a', 'route-a',
        'owner-a', 8, 22)).assertNull();
      expect(handoff.takeDecision('owner-a', 'host-a', 'route-b',
        'owner-a', 8, 21)).assertNull();
      expect(handoff.takeDecision('owner-a', 'host-a', 'route-a',
        'owner-a', 8, 21)).assertNull();
    });

    it('rejects_incomplete_or_unbound_credentials', 0, (): void => {
      const handoff: RdpSessionCredentialHandoff =
        RdpSessionCredentialHandoff.getInstance();
      handoff.clearAll();
      expect(handoff.put('', 'host', 'user', 'secret', 'route', 'owner', 1, 1)).assertFalse();
      expect(handoff.put('owner', '', 'user', 'secret', 'route', 'owner', 1, 1)).assertFalse();
      expect(handoff.put('owner', 'host', '', 'secret', 'route', 'owner', 1, 1)).assertFalse();
      expect(handoff.put('owner', 'host', 'user', '', 'route', 'owner', 1, 1)).assertFalse();
      expect(handoff.put('owner', 'host', 'user', 'secret', '', 'owner', 1, 1)).assertFalse();
      expect(handoff.put('owner', 'host', 'user', 'secret', 'route', '', 1, 1)).assertFalse();
      expect(handoff.put('owner', 'host', 'user', 'secret', 'route', 'owner', 0, 1)).assertFalse();
      expect(handoff.put('owner', 'host', 'user', 'secret', 'route', 'owner', 1, 0)).assertFalse();
    });

    it('renews_bound_preflight_activity_without_moving_the_absolute_deadline', 0, (): void => {
      let now: number = 1000;
      const handoff = new RdpSessionCredentialHandoff((): number => now);
      expect(handoff.put('owner', 'host', 'user', 'secret', 'route', 'owner', 3, 31)).assertTrue();
      now += RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS - 1;
      expect(handoff.renewDecision('owner', 'host', 'route', 'owner', 3, 31)).assertTrue();
      now += RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS - 1;
      expect(handoff.hasDecision('owner', 'host', 'route', 'owner', 3, 31)).assertTrue();

      now = 1000 + RDP_SESSION_CREDENTIAL_HANDOFF_ABSOLUTE_TTL_MS + 1;
      expect(handoff.renewDecision('owner', 'host', 'route', 'owner', 3, 31)).assertFalse();
      expect(handoff.takeDecision('owner', 'host', 'route', 'owner', 3, 31)).assertNull();
    });

    it('does_not_renew_on_a_binding_mismatch', 0, (): void => {
      let now: number = 5000;
      const handoff = new RdpSessionCredentialHandoff((): number => now);
      expect(handoff.put('owner', 'host', 'user', 'secret', 'route', 'owner', 4, 41)).assertTrue();
      now += RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS - 1;
      expect(handoff.renewDecision('owner', 'host', 'other-route', 'owner', 4, 41)).assertFalse();
      now += 2;
      expect(handoff.hasDecision('owner', 'host', 'route', 'owner', 4, 41)).assertFalse();
    });

    it('fails_closed_when_the_wall_clock_moves_backwards', 0, (): void => {
      let now: number = 10000;
      const handoff = new RdpSessionCredentialHandoff((): number => now);
      expect(handoff.put('owner', 'host', 'user', 'secret',
        'route', 'owner', 5, 51)).assertTrue();
      now = 9999;
      expect(handoff.hasDecision('owner', 'host', 'route', 'owner', 5, 51)).assertFalse();
      expect(handoff.takeDecision('owner', 'host', 'route', 'owner', 5, 51)).assertNull();
    });

    it('clears_every_pending_secret_on_background_or_scope_transition', 0, (): void => {
      const handoff = new RdpSessionCredentialHandoff();
      expect(handoff.put('owner-a', 'host-a', 'user-a', 'secret-a',
        'route-a', 'owner-a', 5, 51)).assertTrue();
      expect(handoff.put('owner-b', 'host-b', 'user-b', 'secret-b',
        'route-b', 'owner-b', 6, 61)).assertTrue();

      handoff.clearAll();

      expect(handoff.hasDecision('owner-a', 'host-a', 'route-a',
        'owner-a', 5, 51)).assertFalse();
      expect(handoff.hasDecision('owner-b', 'host-b', 'route-b',
        'owner-b', 6, 61)).assertFalse();
    });

    it('clears_by_captured_owner_when_live_host_disappears_during_sheet_close', 0,
      (): void => {
        const handoff = new RdpSessionCredentialHandoff();
        const capturedOwner: string = 'owner-before-delete';
        const capturedHostId: string = 'host-deleted-during-close';
        expect(handoff.put(capturedOwner, capturedHostId, 'user', 'secret',
          'route', capturedOwner, 11, 111)).assertTrue();
        // The UI no longer has a live RemoteHost here; its captured owner/host
        // binding is sufficient to burn the exact process-memory entry.
        expect(handoff.clearIfMatches(
          capturedOwner, capturedHostId, 111)).assertTrue();
        expect(handoff.hasDecision(capturedOwner, capturedHostId, 'route',
          capturedOwner, 11, 111)).assertFalse();
      });

    it('does_not_let_a_delayed_attempt_consume_or_clear_its_replacement', 0,
      (): void => {
        const handoff = new RdpSessionCredentialHandoff();
        expect(handoff.put('owner', 'host', 'old-user', 'old-secret',
          'route', 'owner', 7, 1)).assertTrue();
        expect(handoff.put('owner', 'host', 'new-user', 'new-secret',
          'route', 'owner', 7, 2)).assertTrue();

        expect(handoff.takeDecision(
          'owner', 'host', 'route', 'owner', 7, 1)).assertNull();
        expect(handoff.clearIfMatches('owner', 'host', 1)).assertFalse();
        expect(handoff.takeDecision(
          'owner', 'host', 'route', 'owner', 7, 2)?.password)
          .assertEqual('new-secret');
      });
  });
}
