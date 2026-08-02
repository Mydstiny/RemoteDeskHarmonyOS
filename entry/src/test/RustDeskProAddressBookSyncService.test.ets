import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RustDeskProAccountState,
  RustDeskProAddressBookFilter,
  RustDeskProAddressBookPermission,
  RustDeskProAddressBookProfile,
  RustDeskProAddressBookSnapshot,
  RustDeskProAddressBookTag,
  RustDeskProAddressBookTagRef,
  RustDeskProPeerMembership
} from '../main/ets/model/RustDeskProModels';
import {
  RustDeskProAddressBookLegacyResult,
  RustDeskProAddressBookPeersPage,
  RustDeskProAddressBookProfilesPage,
  RustDeskProAddressBookTagsResult,
  parseRustDeskProAddressBookLegacy
} from '../main/ets/services/RustDeskProAddressBookApiPolicy';
import {
  RustDeskProAddressBookApiClient,
  RustDeskProAddressBookSyncResult,
  RustDeskProAddressBookSyncService
} from '../main/ets/services/RustDeskProAddressBookSyncService';
import { RustDeskProAddressBookCache, RustDeskProAddressBookCacheCipher } from
  '../main/ets/services/RustDeskProAddressBookCache';
import {
  RustDeskProAddressBookFilterIndex,
  rustDeskProAddressBookProfile,
  rustDeskProAddressBookTagSelectionKey,
  rustDeskProAddressBookSafeDiagnostics
} from '../main/ets/services/RustDeskProAddressBookPolicy';
import { RustDeskProApiError } from '../main/ets/services/RustDeskProApiPolicy';
import {
  RUSTDESK_PRO_AB_LEGACY_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE,
  RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE,
  RUSTDESK_PRO_AB_SHARED_PEERS_PAGE_ONE,
  RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE,
  RUSTDESK_PRO_AB_TAGS_SHARED_RESPONSE,
  RustDeskProAddressBookPeerFixture,
  RustDeskProAddressBookTagFixture
} from './RustDeskProServerProFixtures';

function fixtureAccount(tokenGeneration: number = 1): RustDeskProAccountState {
  return {
    id: 'fixture-account', relayId: 'fixture-relay',
    serverUrl: 'https://pro.example.test', username: 'fixture-user@example.test',
    displayName: 'Fixture User', userId: 'fixture-user', accessToken: 'fixture-token',
    accessTokenFingerprint: 'fixture-token-fingerprint', tokenGeneration,
    deviceId: 'fixture-device', deviceUuid: 'fixture-uuid', loginStatus: 'logged_in',
    lastLoginAt: 0, lastSyncAt: 0, lastSyncError: ''
  };
}

class TestCipher implements RustDeskProAddressBookCacheCipher {
  private readonly values: Map<string, string> = new Map<string, string>();

  encrypt(scope: string, plaintext: string): string {
    this.values.set(scope, plaintext);
    return 'opaque-ciphertext-' + scope.length.toString();
  }

  decrypt(scope: string, _ciphertext: string): string {
    return this.values.get(scope) ?? '';
  }
}

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void { this.resolveValue(value); }
}

class FixtureAddressBookApi implements RustDeskProAddressBookApiClient {
  profile: RustDeskProAddressBookProfile = rustDeskProAddressBookProfile(
    'fixture-account', 'fixture-personal-book-guid', 'My address book',
    'personal', 'fixture-owner', 'fullControl');
  shared: RustDeskProAddressBookProfilesPage = {
    supported: true, total: 3, page: 1, pageSize: 100,
    profiles: [
      rustDeskProAddressBookProfile('fixture-account', 'fixture-shared-read-guid',
        'Shared Read', 'shared', 'fixture-owner-a', 'read'),
      rustDeskProAddressBookProfile('fixture-account', 'fixture-shared-write-guid',
        'Shared Write', 'shared', 'fixture-owner-b', 'readWrite'),
      rustDeskProAddressBookProfile('fixture-account', 'fixture-shared-full-guid',
        'Shared Full', 'shared', 'fixture-owner-c', 'fullControl')
    ]
  };
  failAt: string = '';
  pageTwoFailure: boolean = false;
  useLegacy: boolean = false;
  personalPromises: Array<Promise<RustDeskProAddressBookProfile | null>> = [];
  personalCalls: number = 0;
  peerCalls: number = 0;
  tagCalls: number = 0;

  async getAddressBookPersonalProfile(_account: RustDeskProAccountState):
    Promise<RustDeskProAddressBookProfile | null> {
    this.personalCalls += 1;
    if (this.useLegacy) { return null; }
    if (this.personalPromises.length > 0) {
      const deferred: Promise<RustDeskProAddressBookProfile | null> | undefined =
        this.personalPromises.shift();
      if (deferred !== undefined) { return await deferred; }
    }
    if (this.failAt === 'personal') {
      throw new RustDeskProApiError('token_expired', 'fixture token expired', 401);
    }
    if (this.failAt === 'offline') {
      throw new RustDeskProApiError('network_error', 'fixture network unavailable');
    }
    return this.profile;
  }

  async getAddressBookSharedProfilesPage(_account: RustDeskProAccountState, page: number,
    _pageSize: number): Promise<RustDeskProAddressBookProfilesPage> {
    if (this.failAt === 'profiles') {
      throw new RustDeskProApiError('address_book_http_error', 'fixture profiles failed', 503);
    }
    if (page > 1) {
      return { supported: true, total: this.shared.total, page, pageSize: 100, profiles: [] };
    }
    return this.shared;
  }

  async getAddressBookPeersPage(account: RustDeskProAccountState, bookGuid: string,
    page: number, pageSize: number, permission: RustDeskProAddressBookPermission):
    Promise<RustDeskProAddressBookPeersPage> {
    this.peerCalls += 1;
    if (this.failAt === 'peer' || (this.pageTwoFailure && page > 1)) {
      throw new RustDeskProApiError('address_book_http_error', 'fixture peer page failed', 502);
    }
    if (bookGuid === 'fixture-personal-book-guid') {
      const parsed: RustDeskProAddressBookPeersPage = {
        total: this.pageTwoFailure ? 101 : 2, page, pageSize, memberships: []
      };
      if (page === 1) {
        const values: RustDeskProAddressBookPeerFixture[] =
          RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE.data;
        for (let i = 0; i < values.length; i++) {
          const row: RustDeskProAddressBookPeerFixture = values[i];
          const refs: RustDeskProAddressBookTagRef[] = row.tags.map(
            (tag: RustDeskProAddressBookTagFixture): RustDeskProAddressBookTagRef => {
              const exactName: string = tag.name;
              return { tagId: exactName, exactName, color: tag.color };
            });
          const note: string = row.note === undefined ? '' : row.note;
          parsed.memberships.push({
            accountId: account.id, bookGuid, membershipId: row.id,
            peerId: row.id, alias: row.alias, note,
            hostname: row.hostname, platform: row.platform,
            tags: refs, lastSeenAt: 0, permission, readOnly: permission === 'read'
          });
        }
      }
      return parsed;
    }
    if (bookGuid === 'fixture-shared-read-guid') {
      const sharedMembership: RustDeskProPeerMembership = {
        accountId: account.id, bookGuid, membershipId: 'fixture-membership-shared',
        peerId: 'fixture-peer-duplicate', alias: 'Shared alias', note: 'shared note',
        hostname: 'shared-host', platform: 'Linux', tags: [
          { tagId: 'Ops', exactName: 'Ops', color: 4294901760 }
        ], lastSeenAt: 0, permission, readOnly: true
      };
      const sharedPage: RustDeskProAddressBookPeersPage = {
        total: 1, page, pageSize,
        memberships: page === 1 ? [sharedMembership] : []
      };
      return sharedPage;
    }
    return { total: 0, page, pageSize, memberships: [] };
  }

  async getAddressBookTags(account: RustDeskProAccountState,
    bookGuid: string): Promise<RustDeskProAddressBookTagsResult> {
    this.tagCalls += 1;
    if (this.failAt === 'tags') {
      throw new RustDeskProApiError('address_book_http_error', 'fixture tags failed', 404);
    }
    const source: RustDeskProAddressBookTagFixture[] = bookGuid === 'fixture-personal-book-guid'
      ? RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE : RUSTDESK_PRO_AB_TAGS_SHARED_RESPONSE;
    return {
      tags: source.map((row: RustDeskProAddressBookTagFixture, index: number): RustDeskProAddressBookTag => {
        const exactName: string = row.name;
        return { accountId: account.id, bookGuid, tagId: exactName,
          exactName, color: row.color, serverOrder: index };
      })
    };
  }

  async getAddressBookLegacy(account: RustDeskProAccountState): Promise<RustDeskProAddressBookLegacyResult> {
    return parseRustDeskProAddressBookLegacy(RUSTDESK_PRO_AB_LEGACY_RESPONSE, 200, account.id);
  }
}

export default function rustDeskProAddressBookSyncServiceTest(): void {
  describe('RustDeskProAddressBookSyncService', (): void => {
    it('publishes_all_books_and_tags_atomically_with_read_only_permissions', 0,
      async (): Promise<void> => {
        const api = new FixtureAddressBookApi();
        const service = new RustDeskProAddressBookSyncService(api, new RustDeskProAddressBookCache(new TestCipher()));
        const result = await service.refresh(fixtureAccount());
        expect(result.published).assertTrue();
        expect(result.snapshot.state).assertEqual('fresh');
        expect(result.snapshot.profiles.length).assertEqual(4);
        // The same official name is present in personal and all shared books;
        // book scope keeps every tag record distinct.
        expect(result.snapshot.tags.length).assertEqual(5);
        expect(result.snapshot.tags.filter(
          (tag: RustDeskProAddressBookTag): boolean => tag.exactName === 'Ops').length).assertEqual(4);
        expect(result.snapshot.memberships.length).assertEqual(3);
        const shared: RustDeskProPeerMembership | undefined = result.snapshot.memberships.find(
          (item: RustDeskProPeerMembership): boolean =>
            item.membershipId === 'fixture-membership-shared');
        expect(shared !== undefined).assertTrue();
        if (shared !== undefined) { expect(shared.readOnly).assertTrue(); }
        const full = result.snapshot.profiles.find(
          (profile: RustDeskProAddressBookProfile): boolean =>
            profile.bookGuid === 'fixture-shared-full-guid');
        expect(full !== undefined).assertTrue();
        if (full !== undefined) {
          expect(full.permission).assertEqual('fullControl');
          expect(full.canWrite).assertTrue();
        }
      });

    it('retains_last_known_good_when_peer_or_tag_page_fails', 0,
      async (): Promise<void> => {
        const api = new FixtureAddressBookApi();
        const service = new RustDeskProAddressBookSyncService(api, new RustDeskProAddressBookCache(new TestCipher()));
        const first = await service.refresh(fixtureAccount());
        api.failAt = 'tags';
        const second = await service.refresh(fixtureAccount());
        expect(first.snapshot.memberships.length).assertEqual(3);
        expect(second.published).assertFalse();
        expect(second.snapshot.state).assertEqual('stale');
        expect(second.snapshot.memberships.length).assertEqual(3);
        expect(second.snapshot.errorCode).assertEqual('address_book_http_error');
        api.failAt = 'personal';
        const expired = await service.refresh(fixtureAccount());
        expect(expired.snapshot.state).assertEqual('stale');
        expect(expired.snapshot.errorCode).assertEqual('token_expired');
        api.failAt = 'offline';
        const offline = await service.refresh(fixtureAccount());
        expect(offline.snapshot.state).assertEqual('offline');
        expect(offline.snapshot.stale).assertTrue();
      });

    it('does_not_publish_partial_pagination', 0, async (): Promise<void> => {
      const api = new FixtureAddressBookApi();
      api.pageTwoFailure = true;
      const service = new RustDeskProAddressBookSyncService(api, new RustDeskProAddressBookCache(new TestCipher()));
      const result = await service.refresh(fixtureAccount());
      expect(result.published).assertFalse();
      expect(result.snapshot.state).assertEqual('error');
      expect(result.snapshot.memberships.length).assertEqual(0);
      expect(api.peerCalls > 1).assertTrue();
    });

    it('old_generation_completion_cannot_overwrite_new_snapshot', 0,
      async (): Promise<void> => {
        const api = new FixtureAddressBookApi();
        const firstPersonal = new DeferredValue<RustDeskProAddressBookProfile | null>();
        const secondPersonal = new DeferredValue<RustDeskProAddressBookProfile | null>();
        api.personalPromises.push(firstPersonal.promise, secondPersonal.promise);
        const service = new RustDeskProAddressBookSyncService(api, new RustDeskProAddressBookCache(new TestCipher()));
        const oldRequest: Promise<RustDeskProAddressBookSyncResult> =
          service.refresh(fixtureAccount());
        const newRequest: Promise<RustDeskProAddressBookSyncResult> =
          service.refresh(fixtureAccount());
        secondPersonal.resolve(api.profile);
        const newest = await newRequest;
        firstPersonal.resolve(api.profile);
        const older = await oldRequest;
        expect(newest.published).assertTrue();
        expect(older.superseded).assertTrue();
        expect(service.getSnapshot('fixture-account', 'https://pro.example.test', 1) !== null).assertTrue();
      });

    it('legacy_is_read_only_and_token_generation_is_owner_scoped', 0,
      async (): Promise<void> => {
        const api = new FixtureAddressBookApi();
        const service = new RustDeskProAddressBookSyncService(api, new RustDeskProAddressBookCache(new TestCipher()));
        api.useLegacy = true;
        const legacy = await service.refresh(fixtureAccount());
        expect(legacy.snapshot.profiles[0].kind).assertEqual('legacy');
        expect(legacy.snapshot.memberships.length).assertEqual(1);
        expect(legacy.snapshot.memberships[0].readOnly).assertTrue();
        // A changed token generation cannot read the old owner snapshot.
        expect(service.getSnapshot('fixture-account', 'https://pro.example.test', 2) === null).assertTrue();
        const newer = await service.refresh(fixtureAccount(2));
        expect(newer.published).assertTrue();
        expect(service.getSnapshot('fixture-account', 'https://pro.example.test', 1) === null).assertTrue();
        service.invalidateAccount('fixture-account');
        expect(service.getSnapshot('fixture-account', 'https://pro.example.test', 2) === null).assertTrue();
      });

    it('scale_filter_p95_is_bounded_without_frame_recomputation', 0, (): void => {
      const profiles: RustDeskProAddressBookProfile[] = [];
      const memberships: RustDeskProPeerMembership[] = [];
      const tags: RustDeskProAddressBookTag[] = [];
      for (let book = 0; book < 10; book++) {
        const bookGuid: string = 'book-' + book.toString();
        profiles.push(rustDeskProAddressBookProfile('scale-account', bookGuid,
          'Book ' + book.toString(), 'shared', '', 'read'));
        for (let tag = 0; tag < 100; tag++) {
          tags.push({
            accountId: 'scale-account', bookGuid, tagId: 'tag-' + book.toString() + '-' + tag.toString(),
            exactName: 'Tag ' + tag.toString(), color: tag + 1, serverOrder: tag
          });
        }
        for (let peer = 0; peer < 1000; peer++) {
          const tagId: string = 'tag-' + book.toString() + '-' + (peer % 100).toString();
          memberships.push({
            accountId: 'scale-account', bookGuid,
            membershipId: 'membership-' + book.toString() + '-' + peer.toString(),
            peerId: 'peer-' + (peer % 1000).toString(), alias: 'Alias ' + peer.toString(),
            note: '', hostname: 'host-' + peer.toString(), platform: 'Linux',
            tags: [{ tagId, exactName: 'Tag ' + (peer % 100).toString(), color: 1 }],
            lastSeenAt: 0, permission: 'read', readOnly: true
          });
        }
        // The same peer can have more than one membership in one book. The
        // filter must retain both rows rather than de-duplicating by display
        // text or peer id.
        memberships.push({
          accountId: 'scale-account', bookGuid,
          membershipId: 'membership-' + book.toString() + '-duplicate', peerId: 'peer-0',
          alias: 'Duplicate Alias ' + book.toString(), note: '',
          hostname: 'duplicate-host-' + book.toString(), platform: 'Linux',
          tags: [{ tagId: 'tag-' + book.toString() + '-1', exactName: 'Tag 1', color: 2 }],
          lastSeenAt: 0, permission: 'read', readOnly: true
        });
      }
      expect(profiles.length).assertEqual(10);
      expect(tags.length).assertEqual(1000);
      expect(memberships.length).assertEqual(10010);
      const filter: RustDeskProAddressBookFilter = {
        accountId: 'scale-account', bookGuid: '', selectedTagIds: [
          rustDeskProAddressBookTagSelectionKey({
            accountId: 'scale-account', bookGuid: 'book-5', tagId: 'tag-5-1',
            exactName: 'Tag 1', color: 1, serverOrder: 1
          })
        ],
        includeUntagged: false, mode: 'or' as 'or', text: 'book'
      };
      const index = new RustDeskProAddressBookFilterIndex();
      index.setSnapshot('scale-v1', memberships, profiles);
      const warmed: RustDeskProPeerMembership[] = index.filter(filter);
      expect(warmed.length > 0).assertTrue();
      expect(index.buildCount()).assertEqual(1);
      expect(index.filter(filter) === warmed).assertTrue();
      const samples: number[] = [];
      for (let run = 0; run < 25; run++) {
        const start: number = Date.now();
        const measured: RustDeskProAddressBookFilter = {
          accountId: filter.accountId, bookGuid: filter.bookGuid,
          selectedTagIds: filter.selectedTagIds, includeUntagged: filter.includeUntagged,
          // peer-N is an exact indexed token, so this measures the production
          // candidate index instead of repeatedly scanning all 10010 rows.
          mode: filter.mode, text: 'peer-' + (run % 10).toString()
        };
        index.filter(measured);
        samples.push(Date.now() - start);
      }
      samples.sort((a: number, b: number): number => a - b);
      const p95: number = samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.95))];
      expect(p95 <= 50).assertTrue();
      expect(index.buildCount()).assertEqual(1);
    });

    it('safe_diagnostics_contain_no_server_identity_text', 0, (): void => {
      const snapshot: RustDeskProAddressBookSnapshot = {
        accountId: 'fixture-account', origin: 'https://pro.example.test', tokenGeneration: 1,
        generation: 1, revision: '', profiles: [], tags: [], memberships: [{
          accountId: 'fixture-account', bookGuid: 'secret-book', membershipId: 'secret-membership',
          peerId: 'secret-peer', alias: 'secret-alias', note: 'secret-note', hostname: 'secret-host',
          platform: 'Linux', tags: [{ tagId: 'secret-tag', exactName: 'secret-tag-name', color: 0 }],
          lastSeenAt: 0, permission: 'read', readOnly: true
        }], state: 'stale', stale: true, errorCode: 'offline', syncedAt: 0
      };
      const text: string = JSON.stringify(rustDeskProAddressBookSafeDiagnostics(snapshot));
      expect(text.indexOf('secret-')).assertEqual(-1);
    });
  });
}
