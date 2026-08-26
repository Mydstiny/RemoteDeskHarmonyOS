import { describe, it, expect } from '@ohos/hypium';
import {
  vncAuthFailureShouldReplaceSavedCredential,
  vncCredentialPasswordForConnect,
  vncCredentialPreflightMessage,
  vncCredentialPreflightNeedsPrompt
} from '../main/ets/services/VncCredentialPreflightPolicy';

export default function vncCredentialPreflightPolicyTest(): void {
  describe('VncCredentialPreflightPolicy', (): void => {
    it('routes_only_after_a_saved_or_transient_decision', 0, (): void => {
      expect(vncCredentialPreflightNeedsPrompt('available', false, false)).assertFalse();
      expect(vncCredentialPreflightNeedsPrompt('missing', true, false)).assertFalse();
      expect(vncCredentialPreflightNeedsPrompt('missing', false, false)).assertTrue();
      expect(vncCredentialPreflightNeedsPrompt('locked', false, false)).assertTrue();
      expect(vncCredentialPreflightNeedsPrompt('consent_required', false, false)).assertTrue();
      expect(vncCredentialPreflightNeedsPrompt('invalid', false, false)).assertTrue();
    });

    it('forces_a_host_list_prompt_after_native_authentication_failure', 0, (): void => {
      expect(vncCredentialPreflightNeedsPrompt('available', false, true)).assertTrue();
      expect(vncCredentialPreflightNeedsPrompt('available', true, true)).assertTrue();
      expect(vncCredentialPreflightMessage('available', true).indexOf('认证失败') >= 0).assertTrue();
    });

    it('preserves_an_explicit_empty_password_decision', 0, (): void => {
      expect(vncCredentialPasswordForConnect(true, '', (): string =>
        'stale-saved-password')).assertEqual('');
      expect(vncCredentialPasswordForConnect(true, 'one-shot', (): string =>
        'saved')).assertEqual('one-shot');
      expect(vncCredentialPasswordForConnect(false, '', (): string =>
        'saved')).assertEqual('saved');
    });

    it('replaces_only_a_saved_password_that_was_actually_sent', 0, (): void => {
      expect(vncAuthFailureShouldReplaceSavedCredential(false, 'saved')).assertTrue();
      expect(vncAuthFailureShouldReplaceSavedCredential(false, '')).assertFalse();
      expect(vncAuthFailureShouldReplaceSavedCredential(true, 'one-shot')).assertFalse();
      expect(vncAuthFailureShouldReplaceSavedCredential(true, '')).assertFalse();
    });
  });
}
