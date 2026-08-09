import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import { http } from '@kit.NetworkKit';
import {
  RustDeskProAccountState,
  RustDeskProLoginChallenge,
  RustDeskProLoginResult
} from '../main/ets/model/RustDeskProModels';
import {
  RustDeskProApiError,
  RustDeskProLoginOutcome
} from '../main/ets/services/RustDeskProApiPolicy';
import {
  normalizeRustDeskProHttpErrorPayload,
  RustDeskProApiService,
  RustDeskProHttpResponse,
  RustDeskProHttpTransport,
  setRustDeskProHttpTransportFactoryForTest
} from '../main/ets/services/RustDeskProApiService';
import {
  RUSTDESK_PRO_EMAIL_CHALLENGE_RESPONSE,
  RUSTDESK_PRO_EXTENDED_FIELD_REJECTION_RESPONSE,
  RUSTDESK_PRO_SUCCESS_RESPONSE,
  RUSTDESK_PRO_TOTP_CHALLENGE_RESPONSE,
  RUSTDESK_PRO_UPSTREAM_COMMIT,
  RUSTDESK_PRO_WRONG_EMAIL_RESPONSE,
  RUSTDESK_PRO_WRONG_TOTP_RESPONSE
} from './RustDeskProServerProFixtures';

function fixtureAccount(): RustDeskProAccountState {
  return {
    id: 'fixture-account', relayId: 'fixture-relay',
    serverUrl: 'https://pro.example.test', username: 'fixture-user@example.test',
    displayName: 'Fixture User', userId: '', accessToken: '',
    accessTokenFingerprint: '', tokenGeneration: 1,
    deviceId: 'fixture-device', deviceUuid: 'fixture-uuid', loginStatus: 'none',
    lastLoginAt: 0, lastSyncAt: 0, lastSyncError: ''
  };
}

function captureBody(value: Object | null): Object {
  return value === null ? {} : JSON.parse(JSON.stringify(value)) as Object;
}

interface FakeNativeResponse {
  status: number
  result: Object
}

class FakeNativeHttpTransport implements RustDeskProHttpTransport {
  readonly responses: FakeNativeResponse[];
  requestCount: number = 0;
  lastOptions: http.HttpRequestOptions | null = null;

  constructor(responses: FakeNativeResponse[]) {
    this.responses = responses;
  }

  request(_url: string, options: http.HttpRequestOptions): Promise<http.HttpResponse> {
    this.lastOptions = options;
    const index: number = Math.min(this.requestCount, this.responses.length - 1);
    this.requestCount++;
    const response: FakeNativeResponse = this.responses[index];
    return Promise.resolve({
      responseCode: response.status,
      resultType: http.HttpDataType.STRING,
      result: response.result
    } as http.HttpResponse);
  }

  destroy(): void {
    // No native resource in the deterministic fake.
  }
}

export default function rustDeskProApiServiceTest(): void {
  describe('RustDeskProApiService', (): void => {
    it('uses_pinned_fixture_and_two_requests_for_email_challenge', 0,
      async (): Promise<void> => {
        expect(RUSTDESK_PRO_UPSTREAM_COMMIT.length).assertEqual(40);
        const requests: Object[] = [];
        const service = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            requests.push(captureBody(body));
            return requests.length === 1
              ? { status: 200, payload: RUSTDESK_PRO_EMAIL_CHALLENGE_RESPONSE }
              : { status: 200, payload: RUSTDESK_PRO_SUCCESS_RESPONSE };
          });
        const account: RustDeskProAccountState = fixtureAccount();
        const primary: RustDeskProLoginOutcome =
          await service.loginOutcome(account, account.username, 'fixture-password');
        expect(primary.outcome).assertEqual('challenge');
        if (primary.outcome !== 'challenge') { return; }
        const completed: RustDeskProLoginOutcome =
          await service.submitLoginChallenge(account, primary.challenge, '123456');
        expect(completed.outcome).assertEqual('authenticated');
        expect(requests.length).assertEqual(2);
        const first: Record<string, Object> = requests[0] as Record<string, Object>;
        const second: Record<string, Object> = requests[1] as Record<string, Object>;
        expect(first['password']).assertEqual('fixture-password');
        expect(second['type']).assertEqual('email_code');
        expect(second['verificationCode']).assertEqual('123456');
        expect(second['tfaCode']).assertEqual('');
        expect(second['password']).assertEqual(undefined);
      });

    it('sends_totp_code_only_in_tfaCode_and_preserves_email_error_kind', 0,
      async (): Promise<void> => {
        const requests: Object[] = [];
        const service = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            requests.push(captureBody(body));
            return requests.length === 1
              ? { status: 200, payload: RUSTDESK_PRO_TOTP_CHALLENGE_RESPONSE }
              : { status: 400, payload: RUSTDESK_PRO_WRONG_TOTP_RESPONSE };
          });
        const account: RustDeskProAccountState = fixtureAccount();
        const primary: RustDeskProLoginOutcome =
          await service.loginOutcome(account, account.username, 'fixture-password');
        if (primary.outcome !== 'challenge') { return; }
        let code: string = '';
        try { await service.submitLoginChallenge(account, primary.challenge, '654321'); }
        catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(code).assertEqual('pro_totp_wrong_code');
        const second: Record<string, Object> = requests[1] as Record<string, Object>;
        expect(second['tfaCode']).assertEqual('654321');
        expect(second['verificationCode']).assertEqual('654321');

        const emailService = new RustDeskProApiService(
          async (_account, _path, _method, _body): Promise<RustDeskProHttpResponse> =>
            ({ status: 400, payload: RUSTDESK_PRO_WRONG_EMAIL_RESPONSE }));
        const emailChallenge: RustDeskProLoginChallenge = {
          responseType: 'email_check', kind: 'email', tfaType: 'email_check',
          transientSecret: '<fixture-email-challenge-secret>', username: 'fixture-user',
          userId: 'fixture-user', displayName: 'Fixture User', maskedDestination: '', receivedAt: 1
        };
        let emailCode: string = '';
        try { await emailService.submitLoginChallenge(account, emailChallenge, '123456'); }
        catch (err) { emailCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(emailCode).assertEqual('pro_email_wrong_code');
      });

    it('does_not_replay_invalid_credentials_but_retries_explicit_field_mismatch', 0,
      async (): Promise<void> => {
        const rejectedRequests: Object[] = [];
        const rejectedService = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            rejectedRequests.push(captureBody(body));
            return { status: 400, payload: { error: 'invalid credentials' } };
          });
        let rejectedCode: string = '';
        try { await rejectedService.loginOutcome(fixtureAccount(), 'fixture-user', 'fixture-password'); }
        catch (err) { rejectedCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(rejectedCode).assertEqual('http_error');
        expect(rejectedRequests.length).assertEqual(1);

        const compatibilityRequests: Object[] = [];
        const compatibilityService = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            compatibilityRequests.push(captureBody(body));
            return compatibilityRequests.length === 1
              ? { status: 400, payload: RUSTDESK_PRO_EXTENDED_FIELD_REJECTION_RESPONSE }
              : { status: 200, payload: RUSTDESK_PRO_SUCCESS_RESPONSE };
          });
        const result: RustDeskProLoginOutcome = await compatibilityService.loginOutcome(
          fixtureAccount(), 'fixture-user', 'fixture-password');
        expect(result.outcome).assertEqual('authenticated');
        expect(compatibilityRequests.length).assertEqual(2);
        const minimal: Record<string, Object> = compatibilityRequests[1] as Record<string, Object>;
        expect(minimal['password']).assertEqual('fixture-password');
        expect(minimal['deviceInfo']).assertEqual(undefined);

        const textOnlyRequests: Object[] = [];
        const textOnlyService = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            textOnlyRequests.push(captureBody(body));
            return { status: 400, payload: { message: 'unknown field deviceInfo' } };
          });
        let textOnlyMessage: string = '';
        try {
          await textOnlyService.loginOutcome(
            fixtureAccount(), 'fixture-user', 'fixture-password');
        } catch (err) {
          textOnlyMessage = err instanceof Error ? err.message : '';
        }
        expect(textOnlyRequests.length).assertEqual(1);
        expect(textOnlyMessage.indexOf('版本兼容性')).assertGreaterThan(-1);
      });

    it('scrubs_request_body_and_production_wrapper_logs_all_sensitive_values', 0,
      async (): Promise<void> => {
        const account: RustDeskProAccountState = fixtureAccount();
        account.accessToken = 'actual-token-123';
        const challenge: RustDeskProLoginChallenge = {
          responseType: 'email_check', kind: 'email', tfaType: 'email_check',
          transientSecret: 'actual-secret-123', username: 'actual-user',
          userId: 'actual-user-id', displayName: 'Actual User',
          maskedDestination: 'a***@example.test', receivedAt: 1
        };
        let requestBody: Object | null = null;
        const logs: string[] = [];
        const service = new RustDeskProApiService(
          async (_account, _path, _method, body): Promise<RustDeskProHttpResponse> => {
            requestBody = body;
            return {
              status: 400,
              payload: {
                error: 'invalid email verification code Bearer actual-token-123 actual-token-123 actual-user ' +
                  'fixture-user@example.test verificationCode=654321 ' +
                  'tfaCode=654321 secret=actual-secret-123'
              }
            };
          },
          (_level, message): void => { logs.push(message); });
        let errorCode: string = '';
        try { await service.submitLoginChallenge(account, challenge, '654321'); }
        catch (err) { errorCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(errorCode).assertEqual('pro_email_wrong_code');
        expect(requestBody === null).assertFalse();
        if (requestBody !== null) {
          const body: Record<string, Object> = requestBody as Record<string, Object>;
          expect(body['verificationCode']).assertEqual('');
          expect(body['secret']).assertEqual('');
          expect(body['username']).assertEqual('');
        }
        const joined: string = logs.join(' ');
        expect(joined.indexOf('actual-token-123')).assertEqual(-1);
        expect(joined.indexOf('actual-user')).assertEqual(-1);
        expect(joined.indexOf('fixture-user@example.test')).assertEqual(-1);
        expect(joined.indexOf('654321')).assertEqual(-1);
        expect(joined.indexOf('actual-secret-123')).assertEqual(-1);
      });

    it('preserves_structured_non_2xx_envelopes_and_synthesizes_safe_non_json_envelopes', 0,
      (): void => {
        const account: RustDeskProAccountState = fixtureAccount();
        account.accessToken = 'actual-token-123';
        const requestBody: Object = {
          username: 'actual-user', verificationCode: '654321',
          secret: 'actual-secret-123', authorization: 'Bearer actual-token-123'
        };
        const structured: Object = {
          error: 'invalid_request', code: 'invalid_request',
          message: 'rate limited for actual-user',
          detail: 'email verificationCode=654321 rejected',
          unsupportedFields: ['deviceInfo'],
          fieldErrors: { deviceInfo: 'unsupported' },
          retryAfter: 30, rateLimited: true,
          authorization: 'Bearer actual-token-123', unknownField: 'keep-me'
        };
        const preserved: Object = normalizeRustDeskProHttpErrorPayload(
          400, structured, JSON.stringify(structured), requestBody, account);
        expect(preserved === structured).assertTrue();
        const preservedText: string = JSON.stringify(preserved);
        expect(preservedText.indexOf('unsupportedFields')).assertGreaterThan(-1);
        expect(preservedText.indexOf('fieldErrors')).assertGreaterThan(-1);
        expect(preservedText.indexOf('retryAfter')).assertGreaterThan(-1);
        expect(preservedText.indexOf('rateLimited')).assertGreaterThan(-1);
        expect(preservedText.indexOf('unknownField')).assertGreaterThan(-1);

        const plain: Object = normalizeRustDeskProHttpErrorPayload(
          502,
          'Bearer actual-token-123 actual-user verificationCode=654321 actual-secret-123' as Object,
          'Bearer actual-token-123 actual-user verificationCode=654321 actual-secret-123',
          requestBody, account);
        const plainRoot: Record<string, Object> = plain as Record<string, Object>;
        expect(plainRoot['status']).assertEqual(502);
        expect(plainRoot['error']).assertEqual('remote_rejected');
        const plainText: string = JSON.stringify(plain);
        expect(plainText.indexOf('actual-token-123')).assertEqual(-1);
        expect(plainText.indexOf('actual-user')).assertEqual(-1);
        expect(plainText.indexOf('654321')).assertEqual(-1);
        expect(plainText.indexOf('actual-secret-123')).assertEqual(-1);
      });

    it('captures_native_wrapper_fallback_and_preserves_mixed_challenge_errors', 0,
      async (): Promise<void> => {
        const fallbackTransport = new FakeNativeHttpTransport([
          {
            status: 400,
            result: JSON.stringify({ unsupportedFields: ['deviceInfo'] }) as Object
          },
          { status: 200, result: JSON.stringify(RUSTDESK_PRO_SUCCESS_RESPONSE) as Object }
        ]);
        const logs: string[] = [];
        const account: RustDeskProAccountState = fixtureAccount();
        account.accessToken = 'actual-token-123';
        setRustDeskProHttpTransportFactoryForTest((): RustDeskProHttpTransport =>
          fallbackTransport);
        try {
          const service = new RustDeskProApiService(undefined,
            (_level, message): void => { logs.push(message); });
          const result: RustDeskProLoginOutcome = await service.loginOutcome(
            account, 'actual-user', 'actual-password');
          expect(result.outcome).assertEqual('authenticated');
          expect(fallbackTransport.requestCount).assertEqual(2);
          expect(logs.join(' ').indexOf('actual-token-123')).assertEqual(-1);
          expect(logs.join(' ').indexOf('actual-user')).assertEqual(-1);
        } finally {
          setRustDeskProHttpTransportFactoryForTest(null);
        }

        const challengeTransport = new FakeNativeHttpTransport([
          { status: 200, result: JSON.stringify(RUSTDESK_PRO_EMAIL_CHALLENGE_RESPONSE) as Object },
          {
            status: 400,
            result: JSON.stringify({
              error: 'invalid email verification code',
              message: 'rate limited; retry after 30 seconds',
              detail: 'authorization=Bearer actual-token-123 verificationCode=654321',
              auth: 'failed', rateLimited: true, retryAfter: 30
            }) as Object
          }
        ]);
        const challengeLogs: string[] = [];
        setRustDeskProHttpTransportFactoryForTest((): RustDeskProHttpTransport =>
          challengeTransport);
        try {
          const service = new RustDeskProApiService(undefined,
            (_level, message): void => { challengeLogs.push(message); });
          const primary: RustDeskProLoginOutcome = await service.loginOutcome(
            account, 'actual-user', 'actual-password');
          expect(primary.outcome).assertEqual('challenge');
          if (primary.outcome === 'challenge') {
            let code: string = '';
            try { await service.submitLoginChallenge(account, primary.challenge, '654321'); }
            catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
            expect(code).assertEqual('pro_email_wrong_code');
          }
          const joined: string = challengeLogs.join(' ');
          expect(joined.indexOf('actual-token-123')).assertEqual(-1);
          expect(joined.indexOf('actual-user')).assertEqual(-1);
          expect(joined.indexOf('654321')).assertEqual(-1);
        } finally {
          setRustDeskProHttpTransportFactoryForTest(null);
        }

        const nonJsonTransport = new FakeNativeHttpTransport([
          {
            status: 502,
            result: 'Bearer actual-token-123 actual-user verificationCode=654321 actual-secret-123' as Object
          }
        ]);
        const nonJsonLogs: string[] = [];
        setRustDeskProHttpTransportFactoryForTest((): RustDeskProHttpTransport =>
          nonJsonTransport);
        try {
          const service = new RustDeskProApiService(undefined,
            (_level, message): void => { nonJsonLogs.push(message); });
          let httpStatus: number = 0;
          try { await service.loginOutcome(account, 'actual-user', 'actual-password'); }
          catch (err) { httpStatus = err instanceof RustDeskProApiError ? err.status : 0; }
          expect(httpStatus).assertEqual(502);
          expect(nonJsonTransport.requestCount).assertEqual(1);
          const joined: string = nonJsonLogs.join(' ');
          expect(joined.indexOf('actual-token-123')).assertEqual(-1);
          expect(joined.indexOf('actual-user')).assertEqual(-1);
          expect(joined.indexOf('654321')).assertEqual(-1);
        } finally {
          setRustDeskProHttpTransportFactoryForTest(null);
        }
      });

    it('keeps_the_legacy_authenticated_login_boundary', 0,
      async (): Promise<void> => {
        const service = new RustDeskProApiService(
          async (_account, _path, _method, _body): Promise<RustDeskProHttpResponse> =>
            ({ status: 200, payload: RUSTDESK_PRO_SUCCESS_RESPONSE }));
        const result: RustDeskProLoginResult = await service.login(
          fixtureAccount(), 'fixture-user', 'fixture-password');
        expect(result.accessToken).assertEqual('<fixture-access-token>');

        const challengeService = new RustDeskProApiService(
          async (_account, _path, _method, _body): Promise<RustDeskProHttpResponse> =>
            ({ status: 200, payload: RUSTDESK_PRO_EMAIL_CHALLENGE_RESPONSE }));
        let challengeCode: string = '';
        try { await challengeService.login(fixtureAccount(), 'fixture-user', 'fixture-password'); }
        catch (err) { challengeCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(challengeCode).assertEqual('two_factor_required');
      });
  });
}
