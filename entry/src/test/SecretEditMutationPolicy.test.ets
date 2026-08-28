import { describe, it, expect } from '@ohos/hypium';
import {
  applySecretEditMutation,
  clearSecretEditMutation,
  resolveSecretEditValue,
  secretBindingUnchanged,
  secretEditDraftValue,
  secretEditMutationForDraft,
  secretEditPlaceholder,
  secretSubmissionValue
} from '../main/ets/services/SecretEditMutationPolicy';

export default function secretEditMutationPolicyTest() {
  describe('SecretEditMutationPolicy', (): void => {
    it('keeps_hidden_existing_secrets_out_of_editor_state', 0, (): void => {
      expect(secretEditDraftValue('old-password', true)).assertEqual('');
      expect(secretEditDraftValue('old-password', false)).assertEqual('old-password');
      expect(secretEditPlaceholder(true, true, '输入密码').indexOf('已保存') >= 0).assertTrue();
    });

    it('keeps_hidden_existing_secret_on_an_empty_draft', 0, (): void => {
      const mutation = secretEditMutationForDraft('', true, true, true);
      expect(mutation.kind).assertEqual('keep');
      expect(applySecretEditMutation('old-password', mutation)).assertEqual('old-password');
      expect(resolveSecretEditValue('old-password', '', true, true)).assertEqual('old-password');
    });

    it('replaces_hidden_secret_only_with_a_new_value', 0, (): void => {
      const mutation = secretEditMutationForDraft('new-password', true, true, true);
      expect(mutation.kind).assertEqual('replace');
      expect(applySecretEditMutation('old-password', mutation)).assertEqual('new-password');
    });

    it('does_not_preserve_when_authentication_binding_changed', 0, (): void => {
      expect(resolveSecretEditValue('old-password', '', true, false)).assertEqual('');
      expect(applySecretEditMutation('old-password', clearSecretEditMutation())).assertEqual('');
    });

    it('keeps_visible_mode_compatible_and_requires_a_value_for_new_secrets', 0, (): void => {
      expect(resolveSecretEditValue('old-password', '', false, true)).assertEqual('');
      expect(resolveSecretEditValue('', '', true, true)).assertEqual('');
      expect(resolveSecretEditValue('', 'new-password', true, true)).assertEqual('new-password');
    });

    it('preserves_only_an_identical_authentication_binding', 0, (): void => {
      expect(secretBindingUnchanged(['host', '3389', 'user'], ['host', '3389', 'user']))
        .assertTrue();
      expect(secretBindingUnchanged(['host', '3389', 'user'], ['host', '3389', 'other']))
        .assertFalse();
      expect(secretBindingUnchanged(['peer', 'relay'], ['peer'])).assertFalse();
      const sameRustDeskPasswordMode: boolean = secretBindingUnchanged(
        ['peer', 'relay', 'password-mode-0'], ['peer', 'relay', 'password-mode-1']);
      expect(sameRustDeskPasswordMode).assertFalse();
      expect(resolveSecretEditValue('old-password', '', true, sameRustDeskPasswordMode))
        .assertEqual('');
    });

    it('hands_a_forgotten_unchanged_secret_to_only_the_current_action', 0, (): void => {
      expect(secretSubmissionValue('old-password', 'old-password', false, false, true))
        .assertEqual('old-password');
      expect(secretSubmissionValue('old-password', 'old-password', false, false, false))
        .assertEqual('');
      expect(secretSubmissionValue('old-password', 'replacement', true, false, true))
        .assertEqual('replacement');
      expect(secretSubmissionValue('old-password', 'old-password', false, true, true))
        .assertEqual('');
    });
  });
}
