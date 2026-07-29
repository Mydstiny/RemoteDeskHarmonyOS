import { describe, expect, it } from '@ohos/hypium';
import {
  ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES,
  accountCredentialMetadata,
  accountCredentialSecretFitsAssetStore,
  parseAccountCredentialRecord,
  serializeAccountCredentialMetadata
} from '../main/ets/services/AccountCredentialStoragePolicy';

export default function accountCredentialStoragePolicyTest(): void {
  describe('AccountCredentialStoragePolicy', (): void => {
    it('serializes_only_non_secret_account_metadata', 0, (): void => {
      const metadata = accountCredentialMetadata(
        'union-a', 'open-a', 123, 'User A', 100, true, true);
      expect(metadata === null).assertFalse();
      if (metadata === null) { return; }
      const raw: string = serializeAccountCredentialMetadata(metadata);
      expect(raw.indexOf('authorizationCode')).assertEqual(-1);
      expect(raw.indexOf('idToken')).assertEqual(-1);
      expect(raw.indexOf('accessToken":')).assertEqual(-1);
      expect(raw.indexOf('refreshToken":')).assertEqual(-1);
      const parsed = parseAccountCredentialRecord(raw);
      expect(parsed.requiresRewrite).assertFalse();
      expect(parsed.plaintextSecretsFound).assertFalse();
      expect(parsed.metadata?.accessTokenStored ?? false).assertTrue();
    });

    it('detects_legacy_plaintext_and_discards_ephemeral_tokens', 0, (): void => {
      const parsed = parseAccountCredentialRecord(JSON.stringify({
        unionID: 'union-a',
        openID: 'open-a',
        authorizationCode: 'one-time-code',
        idToken: 'large-jwt',
        accessToken: 'access-a',
        refreshToken: 'refresh-a',
        tokenExpiresAt: 123,
        displayName: 'User A',
        loginTime: 100
      }));
      expect(parsed.requiresRewrite).assertTrue();
      expect(parsed.plaintextSecretsFound).assertTrue();
      expect(parsed.legacySecrets.accessToken).assertEqual('access-a');
      expect(parsed.legacySecrets.refreshToken).assertEqual('refresh-a');
      expect(parsed.metadata?.accessTokenStored ?? true).assertFalse();
      expect(parsed.metadata?.refreshTokenStored ?? true).assertFalse();
    });

    it('enforces_the_official_one_kib_asset_limit', 0, (): void => {
      expect(accountCredentialSecretFitsAssetStore('')).assertTrue();
      expect(accountCredentialSecretFitsAssetStore(
        'a'.repeat(ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES))).assertTrue();
      expect(accountCredentialSecretFitsAssetStore(
        'a'.repeat(ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES + 1))).assertFalse();
      expect(accountCredentialSecretFitsAssetStore(
        '汉'.repeat(ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES))).assertFalse();
    });

    it('fails_closed_on_malformed_or_identity_free_records', 0, (): void => {
      expect(parseAccountCredentialRecord('{').metadata === null).assertTrue();
      expect(parseAccountCredentialRecord(
        JSON.stringify({ unionID: '  ' })).metadata === null).assertTrue();
    });
  });
}
