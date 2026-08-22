import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskHostAddDraft,
  RustDeskHostAddHandoff
} from '../main/ets/services/RustDeskHostAddHandoff';

function populatedDraft(): RustDeskHostAddDraft {
  const draft = new RustDeskHostAddDraft();
  draft.step = 2;
  draft.label = 'workstation';
  draft.controlId = 'peer-id';
  draft.relayId = 'relay-old';
  draft.password = 'plaintext-only-in-memory';
  draft.passwordMode = 1;
  draft.useLan = true;
  draft.selectedLanPeerId = 'peer-id';
  draft.lanAddressMode = 'dynamic';
  draft.targetDevice = 'phone';
  draft.adaptiveOrientation = true;
  return draft;
}

export default function rustDeskHostAddHandoffTest(): void {
  describe('RustDeskHostAddHandoff', (): void => {
    it('restores_the_complete_draft_once_and_selects_the_new_relay', 0, (): void => {
      const handoff: RustDeskHostAddHandoff =
        RustDeskHostAddHandoff.getInstance();
      handoff.clearAll();
      const draft: RustDeskHostAddDraft =
        populatedDraft();
      expect(handoff.put(
        'owner-a', 'store-a', 4, draft)).assertTrue();
      draft.password = 'caller-mutated';
      expect(handoff.selectRelay(
        'owner-a', 'store-a', 4,
        'relay-new')).assertTrue();

      const restored: RustDeskHostAddDraft | null =
        handoff.take('owner-a', 'store-a', 4);
      expect(restored !== null).assertTrue();
      expect((restored as RustDeskHostAddDraft).step)
        .assertEqual(2);
      expect((restored as RustDeskHostAddDraft).label)
        .assertEqual('workstation');
      expect((restored as RustDeskHostAddDraft).relayId)
        .assertEqual('relay-new');
      expect((restored as RustDeskHostAddDraft).password)
        .assertEqual('plaintext-only-in-memory');
      expect((restored as RustDeskHostAddDraft).lanAddressMode)
        .assertEqual('');
      expect((restored as RustDeskHostAddDraft)
        .adaptiveOrientation).assertTrue();
      expect(handoff.take(
        'owner-a', 'store-a', 4) === null).assertTrue();
    });

    it('destroys_plaintext_on_owner_store_or_generation_mismatch', 0, (): void => {
      const handoff: RustDeskHostAddHandoff =
        RustDeskHostAddHandoff.getInstance();
      handoff.clearAll();
      handoff.put('owner-a', 'store-a', 4,
        populatedDraft());
      expect(handoff.take(
        'owner-b', 'store-a', 4) === null).assertTrue();
      expect(handoff.take(
        'owner-a', 'store-a', 4) === null).assertTrue();

      handoff.put('owner-a', 'store-a', 4,
        populatedDraft());
      expect(handoff.selectRelay(
        'owner-a', 'store-a', 5,
        'relay-new')).assertFalse();
      expect(handoff.take(
        'owner-a', 'store-a', 4) === null).assertTrue();
    });

    it('rejects_an_unbound_scope_without_retaining_the_draft', 0, (): void => {
      const handoff: RustDeskHostAddHandoff =
        RustDeskHostAddHandoff.getInstance();
      handoff.clearAll();
      expect(handoff.put(
        '', 'store-a', 1,
        populatedDraft())).assertFalse();
      expect(handoff.has(
        '', 'store-a', 1)).assertFalse();
    });
  });
}
