import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  chooseRemoteKeyboardLayout,
  emptyRemoteKeyboardLayoutSelection,
  remoteKeyboardLayoutForSession,
  resetRemoteKeyboardLayoutSelection,
  remoteKeyboardLayoutChoiceLabel
} from '../main/ets/services/RemoteKeyboardLayoutSelectionPolicy';

export default function remoteKeyboardLayoutSelectionPolicyTest(): void {
  describe('RemoteKeyboardLayoutSelection_owner_session_generation', (): void => {
    it('starts_unknown_and_never_claims_windows_without_evidence', 0, (): void => {
      const empty = emptyRemoteKeyboardLayoutSelection();
      expect(empty.choice).assertEqual('unknown');
      expect(remoteKeyboardLayoutChoiceLabel('unknown')).assertContain('未检测');
    });

    it('user_command_choice_is_scoped_to_the_current_owner_session_generation', 0, (): void => {
      let selection = resetRemoteKeyboardLayoutSelection(emptyRemoteKeyboardLayoutSelection(),
        'account-a/host-a', 101, 7);
      selection = chooseRemoteKeyboardLayout(selection, 'account-a/host-a', 101, 7, 'command');
      expect(remoteKeyboardLayoutForSession(selection, 'account-a/host-a', 101, 7))
        .assertEqual('command');
      expect(remoteKeyboardLayoutForSession(selection, 'account-a/host-a', 102, 8))
        .assertEqual('unknown');
      expect(remoteKeyboardLayoutForSession(selection, 'account-b/host-a', 101, 7))
        .assertEqual('unknown');
    });

    it('normalizes_invalid_choice_to_unknown_not_a_local_layout', 0, (): void => {
      const selection = chooseRemoteKeyboardLayout(
        resetRemoteKeyboardLayoutSelection(emptyRemoteKeyboardLayoutSelection(), 'owner', 1, 1),
        'owner', 1, 1, 'not-a-platform');
      expect(selection.choice).assertEqual('unknown');
    });
  });
}
