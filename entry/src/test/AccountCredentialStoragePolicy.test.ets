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

    it('accepts_the_exact_1_0_7_and_initial_1_0_8_credential_shape', 0, (): void => {
      const fixtures: string[] = [
        JSON.stringify({
          unionID: 'legacy-union-107', openID: 'legacy-open-107',
          authorizationCode: 'expired-one-time-code', idToken: '',
          accessToken: '', refreshToken: '', tokenExpiresAt: 0,
          displayName: '1.0.7 User', loginTime: 1700000000000
        }),
        JSON.stringify({
          unionID: 'legacy-union-108', openID: 'legacy-open-108',
          authorizationCode: '', idToken: '', accessToken: 'legacy-access',
          refreshToken: 'legacy-refresh', tokenExpiresAt: 1700003600000,
          displayName: '1.0.8 User', loginTime: 1700000000000
        })
      ];
      for (let i = 0; i < fixtures.length; i++) {
        const parsed = parseAccountCredentialRecord(fixtures[i]);
        expect(parsed.metadata === null).assertFalse();
        expect(parsed.requiresRewrite).assertTrue();
        expect(parsed.metadata?.unionID ?? '').assertEqual(
          i === 0 ? 'legacy-union-107' : 'legacy-union-108');
        expect(parsed.metadata?.openID ?? '').assertEqual(
          i === 0 ? 'legacy-open-107' : 'legacy-open-108');
        expect(parsed.metadata?.displayName ?? '').assertEqual(
          i === 0 ? '1.0.7 User' : '1.0.8 User');
      }
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
