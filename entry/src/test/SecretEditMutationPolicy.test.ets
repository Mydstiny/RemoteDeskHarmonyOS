import { describe, it, expect } from '@ohos/hypium';
import {
  applySecretEditMutation,
  clearSecretEditMutation,
  resolveSecretEditValue,
  secretEditDraftValue,
  secretEditMutationForDraft,
  secretEditPlaceholder
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
  });
}
