import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  buildRustDeskProChallengeRequest,
  buildRustDeskProLoginRequest,
  buildRustDeskProMinimalLoginRequest,
  classifyRustDeskProChallengeFailure,
  isRustDeskProExtendedLoginCompatibilityError,
  normalizeRustDeskProServerUrl,
  parseRustDeskProAddressBookResponse,
  parseRustDeskProChallengeFailure,
  parseRustDeskProLoginChallengeResponse,
  parseRustDeskProLoginResponse,
  parseRustDeskProAddressBookPage,
  parseRustDeskProPersonalAddressBookResponse,
  parseRustDeskProSharedAddressBookProfiles,
  rustDeskProApiRouteId,
  RustDeskProApiError,
  RustDeskProLoginChallenge,
  RustDeskProLoginOutcome,
  sanitizeRustDeskProServerReason
} from '../main/ets/services/RustDeskProApiPolicy';
import {
  shouldRetryRustDeskProMinimalLogin
} from '../main/ets/services/RustDeskProTwoFactorPolicy';

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

    it('builds_official_minimal_login_fallback_body', 0, () => {
      const body = buildRustDeskProMinimalLoginRequest(' alice ', 'secret');
      expect(body['username']).assertEqual('alice');
      expect(body['password']).assertEqual('secret');
      expect(body['type']).assertEqual(undefined);
      expect(body['deviceInfo']).assertEqual(undefined);
    });

    it('only_explicit_extended_field_rejection_allows_400_fallback', 0, () => {
      let code = '';
      let message = '';
      try { parseRustDeskProLoginResponse({ error: 'invalid credentials' }, 400); }
      catch (err) {
        if (err instanceof RustDeskProApiError) { code = err.code; message = err.message; }
      }
      expect(code).assertEqual('http_error');
      expect(message.indexOf('HTTP 400')).assertGreaterThan(-1);
      expect(message.indexOf('精简登录')).assertEqual(-1);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { error: 'unknown field deviceInfo' }, 400)).assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { unsupportedFields: ['deviceInfo'] }, 400)).assertEqual(true);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { fieldErrors: { deviceInfo: 'unsupported' } }, 400)).assertEqual(true);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { fieldErrors: { deviceInfo: { code: 'unsupported' } } }, 400)).assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { error: 'invalid credentials' }, 400)).assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { error: 'unknown field password' }, 400)).assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { unsupportedFields: ['deviceInfo', 'password'] }, 400)).assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { fieldErrors: { deviceInfo: { message: 'unknown field deviceInfo' } } }, 400))
        .assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { unsupportedFields: ['deviceInfo'], error: 'invalid credentials' }, 400))
        .assertEqual(false);
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { unsupportedFields: ['deviceInfo'], code: 'invalid_credentials' }, 400))
        .assertEqual(false);

      const maliciousRootResponses: Object[] = [
        { unsupportedFields: ['deviceInfo'], unknownRoot: true },
        { unsupportedFields: ['deviceInfo'], rateLimited: true },
        { unsupportedFields: ['deviceInfo'], retryAfter: 30 },
        { unsupportedFields: ['deviceInfo'], auth: 'failed' },
        { unsupportedFields: ['deviceInfo'], credential: 'invalid' },
        { unsupportedFields: ['deviceInfo'], message: 'unknown field deviceInfo' },
        { fieldErrors: { deviceInfo: 'unsupported' }, detail: 'try again' },
        { fieldErrors: { deviceInfo: { message: 'unknown field deviceInfo' } } },
        { fieldErrors: { deviceInfo: 'unsupported', id: 'invalid_credentials' } },
        { unsupportedFields: ['deviceInfo'], errorCode: 'rate_limited' },
        { unsupportedFields: ['deviceInfo'], unsupportedFieldsExtra: [] }
      ];
      for (let index = 0; index < maliciousRootResponses.length; index++) {
        expect(isRustDeskProExtendedLoginCompatibilityError(
          maliciousRootResponses[index], 400)).assertEqual(false);
      }
      expect(isRustDeskProExtendedLoginCompatibilityError(
        { unsupportedFields: ['deviceInfo', 'deviceInfo'] }, 400)).assertEqual(false);
    });

    it('parses_authenticated_login_as_explicit_outcome', 0, () => {
      const outcome: RustDeskProLoginOutcome = parseRustDeskProLoginResponse({
        access_token: 'token-value',
        user: { id: 'u-1', name: 'alice', display_name: 'Alice' }
      }, 200);
      expect(outcome.outcome).assertEqual('authenticated');
      if (outcome.outcome === 'authenticated') {
        expect(outcome.result.accessToken).assertEqual('token-value');
        expect(outcome.result.userId).assertEqual('u-1');
        expect(outcome.result.displayName).assertEqual('Alice');
      }
    });

    it('parses_email_challenge_without_exposing_secret', 0, () => {
      const outcome: RustDeskProLoginOutcome = parseRustDeskProLoginResponse({
        type: 'email_check',
        tfa_type: 'email_check',
        secret: 'challenge-secret',
        user: { id: 'u-1', name: 'alice', display_name: 'Alice', email: 'alice@example.com' }
      }, 200);
      expect(outcome.outcome).assertEqual('challenge');
      if (outcome.outcome === 'challenge') {
        expect(outcome.challenge.kind).assertEqual('email');
        expect(outcome.challenge.tfaType).assertEqual('email_check');
        expect(outcome.challenge.maskedDestination).assertEqual('a***@example.com');
        expect(JSON.stringify(outcome.challenge).indexOf('challenge-secret')).assertEqual(-1);
        expect(JSON.stringify(outcome.challengeForDiagnostics).indexOf('challenge-secret')).assertEqual(-1);
      }
    });

    it('parses_totp_challenge_and_rejects_unknown_challenge_type', 0, () => {
      const outcome: RustDeskProLoginOutcome = parseRustDeskProLoginResponse({
        type: 'email_check',
        tfa_type: 'tfa_check',
        secret: 'totp-secret',
        user: { id: 'u-1', name: 'alice' }
      }, 200);
      expect(outcome.outcome).assertEqual('challenge');
      if (outcome.outcome === 'challenge') {
        expect(outcome.challenge.kind).assertEqual('totp');
      }

      let code = '';
      try {
        parseRustDeskProLoginResponse({
          type: 'email_check', tfa_type: 'sms_check', secret: 'secret',
          user: { name: 'alice' }
        }, 200);
      } catch (err) {
        code = err instanceof RustDeskProApiError ? err.code : '';
      }
      expect(code).assertEqual('pro_challenge_unsupported');
    });

    it('still_rejects_success_without_access_token', 0, () => {
      let code = '';

      try { parseRustDeskProLoginResponse({ user: { name: 'alice' } }, 200); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('invalid_response');
    });

    it('processes_server_error_before_challenge_discriminator', 0, () => {
      let code: string = '';
      try {
        parseRustDeskProLoginResponse({
          type: 'email_check', error: 'verification failed', secret: 'do-not-use',
          user: { name: 'alice@example.com' }
        }, 200);
      } catch (err) {
        code = err instanceof RustDeskProApiError ? err.code : '';
      }
      expect(code).assertEqual('auth_error');
    });

    it('builds_email_and_totp_second_step_requests', 0, () => {
      const email: RustDeskProLoginChallenge = {
        responseType: 'email_check', kind: 'email', tfaType: 'email_check',
        transientSecret: 'email-secret', username: 'alice', userId: 'u-1',
        displayName: 'Alice', maskedDestination: 'a***@example.com', receivedAt: 1
      };
      const emailRequest = buildRustDeskProChallengeRequest(
        email, ' 123456 ', 'device', 'uuid', '1.1.0');
      expect(emailRequest.type).assertEqual('email_code');
      expect(emailRequest.verificationCode).assertEqual('123456');
      expect(emailRequest.tfaCode).assertEqual('');
      expect(emailRequest.secret).assertEqual('email-secret');

      const totp: RustDeskProLoginChallenge = {
        responseType: 'email_check', kind: 'totp', tfaType: 'tfa_check',
        transientSecret: 'totp-secret', username: 'alice', userId: 'u-1',
        displayName: 'Alice', maskedDestination: '', receivedAt: 1
      };
      const totpRequest = buildRustDeskProChallengeRequest(
        totp, '654321', 'device', 'uuid', '1.1.0');
      expect(totpRequest.verificationCode).assertEqual('654321');
      expect(totpRequest.tfaCode).assertEqual('654321');
    });

    it('classifies_challenge_failures_without_echoing_server_body', 0, () => {
      expect(classifyRustDeskProChallengeFailure({ error: 'wrong tfa code' }, 400))
        .assertEqual('pro_totp_wrong_code');
      expect(classifyRustDeskProChallengeFailure({ error: 'challenge expired' }, 410))
        .assertEqual('pro_challenge_expired');
      expect(classifyRustDeskProChallengeFailure({ error: 'too many attempts' }, 429))
        .assertEqual('pro_challenge_rate_limited');
      expect(classifyRustDeskProChallengeFailure({ error: 'unsupported challenge type' }, 400))
        .assertEqual('pro_challenge_unsupported');
      expect(classifyRustDeskProChallengeFailure(
        { error: 'invalid email verification code' }, 400, 'email'))
        .assertEqual('pro_email_wrong_code');
      const error = parseRustDeskProChallengeFailure({ error: 'invalid code secret=private' }, 400);
      expect(error.code).assertEqual('pro_totp_wrong_code');
      expect(error.message.indexOf('private')).assertEqual(-1);
      let expiredCode: string = '';
      try { parseRustDeskProLoginChallengeResponse({ error: 'challenge expired' }, 410, 'email'); }
      catch (err) { expiredCode = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(expiredCode).assertEqual('pro_challenge_expired');
    });

    it('keeps_high_priority_machine_errors_above_lower_priority_rate_text', 0, () => {
      expect(classifyRustDeskProChallengeFailure(
        { error: 'invalid_request', message: 'rate limited; try later' }, 400))
        .assertEqual('pro_challenge_failed');
      expect(classifyRustDeskProChallengeFailure(
        { error: 'invalid email verification code', message: 'rate limited' }, 400, 'email'))
        .assertEqual('pro_email_wrong_code');
      expect(classifyRustDeskProChallengeFailure(
        { error: 'unsupported_field', auth: 'failed', message: 'rate limited' }, 400))
        .assertEqual('pro_challenge_unsupported');
      expect(classifyRustDeskProChallengeFailure(
        { error: 'invalid_credentials', message: 'too many attempts' }, 400))
        .assertEqual('pro_challenge_failed');
      expect(classifyRustDeskProChallengeFailure(
        { auth: 'invalid credentials', message: 'rate limited' }, 400))
        .assertEqual('pro_challenge_failed');
    });

    it('only_primary_400_may_use_minimal_login_fallback', 0, () => {
      const primary = new RustDeskProApiError(
        'http_error', 'rejected', 400, 'extended_login_unsupported');
      const challenge = new RustDeskProApiError('pro_totp_wrong_code', 'wrong', 400);
      expect(shouldRetryRustDeskProMinimalLogin('primary', primary)).assertEqual(true);
      expect(shouldRetryRustDeskProMinimalLogin('primary', challenge)).assertEqual(false);
      expect(shouldRetryRustDeskProMinimalLogin('challenge', primary)).assertEqual(false);
      expect(shouldRetryRustDeskProMinimalLogin('challenge', challenge)).assertEqual(false);
    });

    it('redacts_malicious_server_reason_and_request_fields', 0, () => {
      const reason = sanitizeRustDeskProServerReason(
        'user=alice@example.com username=alice password=pw secret=challenge verificationCode=123456 tfaCode=654321 token=tok authorization=Bearer abc',
        ['alice', 'alice@example.com', 'pw', 'challenge', '123456', '654321', 'tok', 'Bearer abc']);
      expect(reason.indexOf('alice')).assertEqual(-1);
      expect(reason.indexOf('example.com')).assertEqual(-1);
      expect(reason.indexOf('pw')).assertEqual(-1);
      expect(reason.indexOf('challenge')).assertEqual(-1);
      expect(reason.indexOf('123456')).assertEqual(-1);
      expect(reason.indexOf('654321')).assertEqual(-1);
      expect(reason.indexOf('tok')).assertEqual(-1);
      expect(reason.indexOf('Bearer abc')).assertEqual(-1);
      expect(reason.indexOf('abc')).assertEqual(-1);
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

    it('never_exposes_server_error_body_or_address_book_guid', 0, () => {
      let message = '';
      try {
        parseRustDeskProLoginResponse({
          error: 'token=secret-value account=private-user'
        }, 500);
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

    it('allows_only_explicit_404_endpoint_not_found_for_modern_compatibility', 0, () => {
      expect(parseRustDeskProPersonalAddressBookResponse(
        { error: 'endpoint_not_found' }, 404)).assertEqual('');
      expect(parseRustDeskProSharedAddressBookProfiles(
        { code: 'route_not_found' }, 404).length).assertEqual(0);
      let personal400: string = '';
      try { parseRustDeskProPersonalAddressBookResponse(
        { error: 'rate_limited' }, 400); }
      catch (err) { personal400 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(personal400).assertEqual('http_error');
      let personal405: string = '';
      try { parseRustDeskProPersonalAddressBookResponse(
        { code: 'method_not_allowed' }, 405); }
      catch (err) { personal405 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(personal405).assertEqual('http_error');
      let shared400: string = '';
      try { parseRustDeskProSharedAddressBookProfiles(
        { error: 'validation_error' }, 400); }
      catch (err) { shared400 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(shared400).assertEqual('http_error');
      let shared405: string = '';
      try { parseRustDeskProSharedAddressBookProfiles(
        { error: 'method_not_allowed' }, 405); }
      catch (err) { shared405 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(shared405).assertEqual('http_error');
      let unknown404: string = '';
      try { parseRustDeskProSharedAddressBookProfiles(
        { message: 'endpoint is absent' }, 404); }
      catch (err) { unknown404 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(unknown404).assertEqual('http_error');
    });

    it('parses_modern_personal_address_book_page', 0, () => {
      expect(parseRustDeskProPersonalAddressBookResponse({ guid: 'ab-1' }, 200)).assertEqual('ab-1');
      const page = parseRustDeskProAddressBookPage({ total: 1, data: [
        { id: '123', alias: 'Office', hostname: 'pc-1', platform: 'Windows' }
      ] }, 200);
      expect(page.total).assertEqual(1);
      expect(page.addressBook.peers.length).assertEqual(1);
      expect(page.addressBook.peers[0].platform).assertEqual('Windows');
    });

    it('parses_shared_address_book_profiles', 0, () => {
      const profiles = parseRustDeskProSharedAddressBookProfiles({
        total: 1,
        data: [{ guid: 'shared-1', name: 'Team' }]
      }, 200);
      expect(profiles.length).assertEqual(1);
      expect(profiles[0]).assertEqual('shared-1');
    });
  });
}
