import { describe, it, expect } from '@ohos/hypium';
import {
  buildUnifiedHostCardRefs,
  mergeVisibleHostOrder,
  moonlightHostCardKey,
  moonlightHostIdFromCardKey,
  moveUnifiedHostCard,
  remoteHostCardKey,
  remoteHostIdFromCardKey
} from '../main/ets/services/UnifiedHostCardPolicy';

export default function unifiedHostCardPolicyTest(): void {
  describe('UnifiedHostCardPolicy', (): void => {
    it('mixes_remote_and_moonlight_cards_in_one_manual_order', 0, (): void => {
      const refs = buildUnifiedHostCardRefs(
        ['rdp-a', 'ssh-b'], ['moon-a'],
        [remoteHostCardKey('ssh-b'), moonlightHostCardKey('moon-a'), remoteHostCardKey('rdp-a')]
      );
      expect(refs.length).assertEqual(3);
      expect(refs[0].key).assertEqual(remoteHostCardKey('ssh-b'));
      expect(refs[1].key).assertEqual(moonlightHostCardKey('moon-a'));
      expect(refs[2].key).assertEqual(remoteHostCardKey('rdp-a'));
    });

    it('keeps_legacy_bare_remote_order_and_appends_new_moonlight_cards', 0, (): void => {
      const refs = buildUnifiedHostCardRefs(['rdp-a', 'ssh-b'], ['moon-a'], ['ssh-b', 'rdp-a']);
      expect(refs[0].hostId).assertEqual('ssh-b');
      expect(refs[1].hostId).assertEqual('rdp-a');
      expect(refs[2].hostId).assertEqual('moon-a');
    });

    it('moves_cards_across_protocols_without_losing_hidden_order_entries', 0, (): void => {
      const remote: string = remoteHostCardKey('rdp-a');
      const moonlight: string = moonlightHostCardKey('moon-a');
      const moved: string[] = moveUnifiedHostCard([remote, moonlight], moonlight, remote);
      const merged: string[] = mergeVisibleHostOrder(
        [remoteHostCardKey('hidden'), remote, moonlight], [remote, moonlight], moved);
      expect(merged[0]).assertEqual(remoteHostCardKey('hidden'));
      expect(merged[1]).assertEqual(moonlight);
      expect(merged[2]).assertEqual(remote);
    });

    it('keeps_filtered_out_cards_in_their_existing_slots', 0, (): void => {
      const first: string = remoteHostCardKey('rdp-a');
      const hidden: string = remoteHostCardKey('hidden');
      const last: string = moonlightHostCardKey('moon-a');
      const merged: string[] = mergeVisibleHostOrder(
        [first, hidden, last], [first, last], [last, first]);
      expect(merged[0]).assertEqual(last);
      expect(merged[1]).assertEqual(hidden);
      expect(merged[2]).assertEqual(first);
    });

    it('uses_namespaced_keys_so_protocol_owners_never_collide', 0, (): void => {
      const remote: string = remoteHostCardKey('same-id');
      const moonlight: string = moonlightHostCardKey('same-id');
      expect(remote === moonlight).assertFalse();
      expect(remoteHostIdFromCardKey(remote)).assertEqual('same-id');
      expect(moonlightHostIdFromCardKey(moonlight)).assertEqual('same-id');
      expect(remoteHostIdFromCardKey(moonlight)).assertEqual('');
      expect(moonlightHostIdFromCardKey(remote)).assertEqual('');
    });
  });
}
