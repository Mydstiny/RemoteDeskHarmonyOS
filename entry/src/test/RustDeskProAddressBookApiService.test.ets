import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { http } from '@kit.NetworkKit';
import {
  RustDeskProAccountState
} from '../main/ets/model/RustDeskProModels';
import {
  RustDeskProApiError
} from '../main/ets/services/RustDeskProApiPolicy';
import {
  normalizeRustDeskProHttpErrorPayload,
  RustDeskProApiService,
  RustDeskProHttpResponse,
  RustDeskProHttpTransport,
  setRustDeskProHttpTransportFactoryForTest
} from '../main/ets/services/RustDeskProApiService';
import {
  RUSTDESK_PRO_AB_LEGACY_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE,
  RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE,
  RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE,
  RUSTDESK_PRO_UPSTREAM_COMMIT
} from './RustDeskProServerProFixtures';

function fixtureAccount(): RustDeskProAccountState {
  return {
    id: 'fixture-account', relayId: 'fixture-relay',
    serverUrl: 'https://pro.example.test', username: 'fixture-user@example.test',
    displayName: 'Fixture User', userId: 'fixture-user', accessToken: 'actual-token-123',
    accessTokenFingerprint: 'token-fingerprint', tokenGeneration: 7,
    deviceId: 'fixture-device', deviceUuid: 'fixture-uuid', loginStatus: 'logged_in',
    lastLoginAt: 0, lastSyncAt: 0, lastSyncError: ''
  };
}

interface CapturedRequest {
  path: string
  method: http.RequestMethod
  body: Object | null
}

interface NativeResponseFixture {
  status: number
  result: string
}

interface AddressBookErrorPayload {
  error: string
  code?: string
  message?: string
  detail?: string
}

interface DeviceInfoFieldErrors {
  deviceInfo: string
}

interface StructuredAddressBookErrorPayload {
  status: number
  error: string
  code: string
  message: string
  detail: string
  unsupportedFields: string[]
  fieldErrors: DeviceInfoFieldErrors
  retryAfter: number
  rateLimited: boolean
  authorization: string
}

interface AddressBookIdentityContext {
  bookGuid: string
  tag: string
}

class CapturedNativeTransport implements RustDeskProHttpTransport {
  readonly responses: NativeResponseFixture[];
  requestCount: number = 0;

  constructor(responses: NativeResponseFixture[]) {
    this.responses = responses;
  }

  request(_url: string, _options: http.HttpRequestOptions): Promise<http.HttpResponse> {
    const index: number = Math.min(this.requestCount, this.responses.length - 1);
    this.requestCount += 1;
    const response: NativeResponseFixture = this.responses[index];
    return Promise.resolve({
      responseCode: response.status,
      resultType: http.HttpDataType.STRING,
      result: response.result
    } as http.HttpResponse);
  }

  destroy(): void {
    // Deterministic fake has no native resource.
  }
}

export default function rustDeskProAddressBookApiServiceTest(): void {
  describe('RustDeskProAddressBookApiService', (): void => {
    it('uses_modern_profile_peer_and_tag_routes_without_flattening_memberships', 0,
      async (): Promise<void> => {
        const requests: CapturedRequest[] = [];
        const service = new RustDeskProApiService(
          async (_account, path, method, body): Promise<RustDeskProHttpResponse> => {
            requests.push({ path, method, body });
            if (path === '/api/ab/personal') {
              return { status: 200, payload: RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE };
            }
            if (path.indexOf('/api/ab/shared/profiles?') === 0) {
              return { status: 200, payload: RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE };
            }
            if (path.indexOf('/api/ab/peers?') === 0) {
              return { status: 200, payload: RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE };
            }
            if (path === '/api/ab/tags/fixture-personal-book-guid') {
              return { status: 200, payload: RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE };
            }
            const unknownRoutePayload: AddressBookErrorPayload = {
              error: 'fixture unknown route'
            };
            return { status: 404, payload: unknownRoutePayload };
          });
        const account: RustDeskProAccountState = fixtureAccount();
        const personal = await service.getAddressBookPersonalProfile(account);
        const shared = await service.getAddressBookSharedProfilesPage(account, 1, 100);
        const peers = await service.getAddressBookPeersPage(
          account, 'fixture-personal-book-guid', 1, 100, 'fullControl');
        const tags = await service.getAddressBookTags(account, 'fixture-personal-book-guid');

        expect(RUSTDESK_PRO_UPSTREAM_COMMIT.length).assertEqual(40);
        expect(personal === null).assertFalse();
        if (personal !== null) { expect(personal.bookGuid).assertEqual('fixture-personal-book-guid'); }
        expect(shared.profiles.length).assertEqual(3);
        expect(shared.profiles[2].permission).assertEqual('fullControl');
        expect(peers.memberships.length).assertEqual(2);
        expect(peers.memberships[0].permission).assertEqual('fullControl');
        expect(tags.tags.length).assertEqual(2);
        expect(requests.length).assertEqual(4);
        expect(requests[0].path).assertEqual('/api/ab/personal');
        expect(requests[1].path).assertEqual(
          '/api/ab/shared/profiles?current=1&pageSize=100');
        expect(requests[2].path).assertEqual(
          '/api/ab/peers?current=1&pageSize=100&ab=fixture-personal-book-guid');
        expect(requests[3].path).assertEqual('/api/ab/tags/fixture-personal-book-guid');
        expect(requests[0].method).assertEqual(http.RequestMethod.POST);
      });

    it('falls_back_to_legacy_only_after_explicit_endpoint_not_found', 0,
      async (): Promise<void> => {
        const requests: CapturedRequest[] = [];
        const service = new RustDeskProApiService(
          async (_account, path, method, body): Promise<RustDeskProHttpResponse> => {
            requests.push({ path, method, body });
            if (path === '/api/ab/get') {
              const missingLegacyPayload: AddressBookErrorPayload = {
                error: 'endpoint_not_found'
              };
              return { status: 404, payload: missingLegacyPayload };
            }
            return { status: 200, payload: RUSTDESK_PRO_AB_LEGACY_RESPONSE };
          });
        const result = await service.getAddressBookLegacy(fixtureAccount());
        expect(result.profile.kind).assertEqual('legacy');
        expect(result.memberships.length).assertEqual(1);
        expect(result.memberships[0].readOnly).assertTrue();
        expect(requests.length).assertEqual(2);
        expect(requests[0].path).assertEqual('/api/ab/get');
        expect(requests[1].path).assertEqual('/api/ab');
        expect(requests[1].method).assertEqual(http.RequestMethod.GET);
      });

    it('keeps_structured_non_2xx_fields_and_never_logs_address_book_identity', 0,
      async (): Promise<void> => {
        const account: RustDeskProAccountState = fixtureAccount();
        const structured: StructuredAddressBookErrorPayload = {
          status: 400,
          error: 'invalid_request',
          code: 'rate_limited',
          message: 'unknown field deviceInfo for secret-alias fixture-peer-one',
          detail: 'authorization=Bearer actual-token-123 tag=Ops note=secret-note',
          unsupportedFields: ['deviceInfo'],
          fieldErrors: { deviceInfo: 'unsupported' },
          retryAfter: 30,
          rateLimited: true,
          authorization: 'Bearer actual-token-123'
        };
        const identityContext: AddressBookIdentityContext = {
          bookGuid: 'secret-book', tag: 'Ops'
        };
        const preserved: Object = normalizeRustDeskProHttpErrorPayload(
          400, structured, JSON.stringify(structured),
          identityContext, account);
        expect(preserved === structured).assertTrue();
        const preservedRoot: StructuredAddressBookErrorPayload = structured;
        expect(preservedRoot.code).assertEqual('rate_limited');
        expect(preservedRoot.unsupportedFields !== undefined).assertEqual(true);
        expect(preservedRoot.fieldErrors !== undefined).assertEqual(true);
        expect(preservedRoot.retryAfter).assertEqual(30);

        const native = new CapturedNativeTransport([{
          status: 400, result: JSON.stringify(structured)
        }]);
        const logs: string[] = [];
        setRustDeskProHttpTransportFactoryForTest((): RustDeskProHttpTransport => native);
        try {
          const service = new RustDeskProApiService(undefined,
            (_level, message): void => { logs.push(message); });
          let errorCode: string = '';
          try { await service.getAddressBookTags(account, 'secret-book'); }
          catch (err) { errorCode = err instanceof RustDeskProApiError ? err.code : ''; }
          expect(errorCode).assertEqual('address_book_rate_limited');
          expect(native.requestCount).assertEqual(1);
          const joined: string = logs.join(' ');
          expect(joined.indexOf('actual-token-123')).assertEqual(-1);
          expect(joined.indexOf('secret-book')).assertEqual(-1);
          expect(joined.indexOf('secret-alias')).assertEqual(-1);
          expect(joined.indexOf('fixture-peer-one')).assertEqual(-1);
          expect(joined.indexOf('secret-note')).assertEqual(-1);
        } finally {
          setRustDeskProHttpTransportFactoryForTest(null);
        }
      });

    it('never_treats_400_or_405_as_modern_endpoint_absence', 0,
      async (): Promise<void> => {
        const requests: CapturedRequest[] = [];
        const service = new RustDeskProApiService(
          async (_account, path, method, body): Promise<RustDeskProHttpResponse> => {
            requests.push({ path, method, body });
            if (path === '/api/ab/personal') {
              const rateLimitedPayload: AddressBookErrorPayload = { error: 'rate_limited' };
              return { status: 400, payload: rateLimitedPayload };
            }
            return { status: 200, payload: RUSTDESK_PRO_AB_LEGACY_RESPONSE };
          });
        let code: string = '';
        try { await service.getAddressBook(fixtureAccount()); }
        catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(code).assertEqual('address_book_aggregate_disabled');
        expect(requests.length).assertEqual(0);

        requests.splice(0, requests.length);
        const sharedService = new RustDeskProApiService(
          async (_account, path, method, body): Promise<RustDeskProHttpResponse> => {
            requests.push({ path, method, body });
            if (path === '/api/ab/personal') {
              return { status: 200, payload: RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE };
            }
            const methodPayload: AddressBookErrorPayload = { error: 'method_not_allowed' };
            return { status: 405, payload: methodPayload };
          });
        let sharedCode: string = '';
        try { await sharedService.getAddressBook(fixtureAccount()); }
        catch (err) { sharedCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(sharedCode).assertEqual('address_book_aggregate_disabled');
        expect(requests.length).assertEqual(0);
      });
  });
}
