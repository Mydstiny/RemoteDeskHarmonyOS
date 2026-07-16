import { describe, it, expect } from '@ohos/hypium';
import {
  buildRustDeskProLoginRequest,
  normalizeRustDeskProServerUrl,
  parseRustDeskProAddressBookResponse,
  parseRustDeskProLoginResponse,
  RustDeskProApiError
} from '../main/ets/services/RustDeskProApiPolicy';

export default function rustDeskProApiPolicyTest() {
  describe('RustDeskProApiPolicy', () => {
    it('normalizes_server_url_without_changing_scheme', 0, () => {
      expect(normalizeRustDeskProServerUrl('https://pro.example/api/')).assertEqual('https://pro.example');
      expect(normalizeRustDeskProServerUrl('http://10.0.0.2:21114///')).assertEqual('http://10.0.0.2:21114');
    });

    it('builds_client_compatible_login_body', 0, () => {
      const body = buildRustDeskProLoginRequest('alice', 'secret', 'rdh-device', 'uuid', '1.0.7');
      expect(body.type).assertEqual('account');
      expect(body.id).assertEqual('rdh-device');
      expect(body.deviceInfo['os']).assertEqual('HarmonyOS');
    });

    it('parses_login_token_and_user', 0, () => {
      const result = parseRustDeskProLoginResponse({
        access_token: 'token-value',
        user: { id: 'u-1', name: 'alice', display_name: 'Alice' }
      }, 200);
      expect(result.accessToken).assertEqual('token-value');
      expect(result.userId).assertEqual('u-1');
      expect(result.displayName).assertEqual('Alice');
    });

    it('rejects_two_factor_and_missing_token', 0, () => {
      let code = '';
      try { parseRustDeskProLoginResponse({ type: 'email_check' }, 200); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('two_factor_required');

      code = '';
      try { parseRustDeskProLoginResponse({ user: { name: 'alice' } }, 200); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('invalid_response');
    });

    it('parses_legacy_address_book_data_string', 0, () => {
      const result = parseRustDeskProAddressBookResponse({
        updated_at: 42,
        data: JSON.stringify({ peers: [{ id: '123', alias: 'Office', hostname: 'pc-1' }], tags: ['work'] })
      }, 200);
      expect(result.updatedAt).assertEqual(42);
      expect(result.peers.length).assertEqual(1);
      expect(result.peers[0].id).assertEqual('123');
      expect(result.peers[0].alias).assertEqual('Office');
      expect(result.tags[0]).assertEqual('work');
    });

    it('maps_expired_token_to_stable_error_code', 0, () => {
      let code = '';
      try { parseRustDeskProAddressBookResponse({}, 401); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('token_expired');
    });
  });
}
