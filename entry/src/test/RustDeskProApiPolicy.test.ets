import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  buildRustDeskProLoginRequest,
  buildRustDeskProMinimalLoginRequest,
  normalizeRustDeskProServerUrl,
  parseRustDeskProAddressBookResponse,
  parseRustDeskProLoginResponse,
  parseRustDeskProAddressBookPage,
  parseRustDeskProPersonalAddressBookResponse,
  parseRustDeskProSharedAddressBookProfiles,
  rustDeskProApiRouteId,
  RustDeskProApiError
} from '../main/ets/services/RustDeskProApiPolicy';
import { jsonRecord } from './helpers/RecordTestUtils';

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
      expect(body.deviceInfo.os).assertEqual('HarmonyOS');
    });

    it('builds_official_minimal_login_fallback_body', 0, () => {
      const body = buildRustDeskProMinimalLoginRequest(' alice ', 'secret');
      expect(body.username).assertEqual('alice');
      expect(body.password).assertEqual('secret');
      expect(jsonRecord(body)['type']).assertEqual(undefined);
      expect(jsonRecord(body)['deviceInfo']).assertEqual(undefined);
    });
    it('still_rejects_success_without_access_token', 0, () => {
      let code = '';

      try { parseRustDeskProLoginResponse({ 'user': { 'name': 'alice' } as Record<string, Object> } as Record<string, Object>, 200); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('invalid_response');
    });
    it('parses_successful_login_with_name_fallbacks', 0, () => {
      const full = parseRustDeskProLoginResponse({
        'access_token': 'token-value',
        'user': { 'id': 'u-1', 'name': 'alice', 'display_name': 'Alice' } as Record<string, Object>
      } as Record<string, Object>, 200);
      expect(full.accessToken).assertEqual('token-value');
      expect(full.userId).assertEqual('u-1');
      expect(full.username).assertEqual('alice');
      expect(full.displayName).assertEqual('Alice');
      expect(full.requiresTwoFactor).assertFalse();
      const minimal = parseRustDeskProLoginResponse({
        'access_token': 'token-value',
        'user': { 'name': 'bob' } as Record<string, Object>
      } as Record<string, Object>, 200);
      expect(minimal.userId).assertEqual('bob');
      expect(minimal.displayName).assertEqual('bob');
    });

    it('classifies_login_rejections', 0, () => {
      let rejected: RustDeskProApiError | null = null;
      try { parseRustDeskProLoginResponse({ 'error': 'remote_rejected' } as Record<string, Object>, 400); }
      catch (err) { rejected = err instanceof RustDeskProApiError ? err : null; }
      expect(rejected !== null && rejected.code === 'http_error').assertTrue();
      expect(rejected !== null && rejected.message.indexOf('HTTP 400') >= 0).assertTrue();
      let challenge: string = '';
      try { parseRustDeskProLoginResponse({ 'type': 'email_check' } as Record<string, Object>, 200); }
      catch (err) { challenge = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(challenge).assertEqual('two_factor_required');
      let denied: string = '';
      try { parseRustDeskProLoginResponse({ 'error': 'wrong password' } as Record<string, Object>, 200); }
      catch (err) { denied = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(denied).assertEqual('auth_error');
    });

    it('parses_legacy_address_book_data_string', 0, () => {
      const result = parseRustDeskProAddressBookResponse({
        'updated_at': 42,
        'data': JSON.stringify({ peers: [{ 'id': '123', 'alias': 'Office', 'hostname': 'pc-1' } as Record<string, Object>], tags: ['work'] })
      } as Record<string, Object>, 200);
      expect(result.updatedAt).assertEqual(42);
      expect(result.peers.length).assertEqual(1);
      expect(result.peers[0].id).assertEqual('123');
      expect(result.peers[0].alias).assertEqual('Office');
      expect(result.tags[0]).assertEqual('work');
    });

    it('maps_expired_token_to_stable_error_code', 0, () => {
      let code = '';
      try { parseRustDeskProAddressBookResponse({} as Record<string, Object>, 401); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('token_expired');
    });

    it('never_exposes_server_error_body_or_address_book_guid', 0, () => {
      let message = '';
      try {
        parseRustDeskProLoginResponse({
          'error': 'token=secret-value account=private-user'
        } as Record<string, Object>, 500);
      } catch (err) {
        message = err instanceof Error ? err.message : '';
      }
      expect(message.indexOf('secret-value')).assertEqual(-1);
      expect(message.indexOf('private-user')).assertEqual(-1);
      const routeId: string = rustDeskProApiRouteId(
        '/api/ab/peers?current=1&pageSize=100&ab=private-guid');
      expect(routeId).assertEqual('address_book_peers');
      expect(routeId.indexOf('private-guid')).assertEqual(-1);
    });

    it('falls_back_on_404_400_405_and_rejects_other_http_errors', 0, () => {
      // Older compatible servers lack the modern endpoints (8acb5b64a): 404,
      // 400 and 405 fall back to the legacy address book instead of failing.
      const statuses: number[] = [404, 400, 405];
      for (let i = 0; i < statuses.length; i++) {
        expect(parseRustDeskProPersonalAddressBookResponse(
          { 'error': 'endpoint_not_found' } as Record<string, Object>, statuses[i])).assertEqual('');
        expect(parseRustDeskProSharedAddressBookProfiles(
          { 'code': 'route_not_found' } as Record<string, Object>, statuses[i]).length).assertEqual(0);
      }
      let personal500: string = '';
      try { parseRustDeskProPersonalAddressBookResponse(
        { 'error': 'internal' } as Record<string, Object>, 500); }
      catch (err) { personal500 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(personal500).assertEqual('http_error');
      let shared502: string = '';
      try { parseRustDeskProSharedAddressBookProfiles(
        { 'message': 'bad gateway' } as Record<string, Object>, 502); }
      catch (err) { shared502 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(shared502).assertEqual('http_error');
      let expired: string = '';
      try { parseRustDeskProSharedAddressBookProfiles({} as Record<string, Object>, 401); }
      catch (err) { expired = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(expired).assertEqual('token_expired');
    });

    it('parses_modern_personal_address_book_page', 0, () => {
      expect(parseRustDeskProPersonalAddressBookResponse({ 'guid': 'ab-1' } as Record<string, Object>, 200)).assertEqual('ab-1');
      const page = parseRustDeskProAddressBookPage({ 'total': 1, 'data': [
        { 'id': '123', 'alias': 'Office', 'hostname': 'pc-1', 'platform': 'Windows' } as Record<string, Object>
      ] } as Record<string, Object>, 200);
      expect(page.total).assertEqual(1);
      expect(page.addressBook.peers.length).assertEqual(1);
      expect(page.addressBook.peers[0].platform).assertEqual('Windows');
    });

    it('parses_shared_address_book_profiles', 0, () => {
      const profiles = parseRustDeskProSharedAddressBookProfiles({
        'total': 1,
        'data': [{ 'guid': 'shared-1', 'name': 'Team' } as Record<string, Object>]
      } as Record<string, Object>, 200);
      expect(profiles.length).assertEqual(1);
      expect(profiles[0]).assertEqual('shared-1');
    });
  });
}
