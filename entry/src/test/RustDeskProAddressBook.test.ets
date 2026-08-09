import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RUSTDESK_PRO_AB_LEGACY_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE,
  RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE,
  RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE,
  RUSTDESK_PRO_AB_SHARED_PEERS_PAGE_ONE,
  RUSTDESK_PRO_AB_TAG_FAILURE_RESPONSE,
  RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE,
  RUSTDESK_PRO_AB_TAGS_SHARED_RESPONSE,
  RUSTDESK_PRO_UPSTREAM_COMMIT
} from './RustDeskProServerProFixtures';
import { RustDeskProAddressBookProfilePageFixture } from './RustDeskProServerProFixtures';
import {
  RustDeskProAddressBookFilter,
  RustDeskProAddressBookPermission,
  RustDeskProAddressBookSnapshot,
  RustDeskProAddressBookTag,
  RustDeskProAddressBookTagRef,
  RustDeskProPeerMembership,
  filterRustDeskProAddressBookMemberships,
  rustDeskProAddressBookBookKey,
  rustDeskProAddressBookMembershipKey,
  rustDeskProAddressBookTagSelectionKey,
  rustDeskProAddressBookTagKey,
  parseRustDeskProAddressBookPermission
} from '../main/ets/services/RustDeskProAddressBookPolicy';
import {
  parseRustDeskProAddressBookLegacy,
  parseRustDeskProAddressBookPeersPage,
  parseRustDeskProAddressBookPersonalProfile,
  parseRustDeskProAddressBookProfilesPage,
  parseRustDeskProAddressBookTags
} from '../main/ets/services/RustDeskProAddressBookApiPolicy';
import { RustDeskProApiError } from '../main/ets/services/RustDeskProApiPolicy';
import {
  RustDeskProAddressBookCache,
  RustDeskProAddressBookCacheCipher,
  RustDeskProAddressBookCachePersistence
} from '../main/ets/services/RustDeskProAddressBookCache';

interface RejectProfileRow {
  id?: string
  guid?: string
  name?: string
  type?: string
  access?: string
  owner?: string
  share_rule?: string
}

interface RejectProfilePage {
  total: number
  data: RejectProfileRow[]
}

interface RejectPeerRow {
  peer_id?: string
  id?: string
  alias?: string
  hostname?: string
  platform?: string
}

interface RejectPeerPage {
  total: number
  data: RejectPeerRow[]
}

interface RejectTagRow {
  id?: string
  tag?: string
  name?: string
  color?: number
}

interface AddressBookErrorPayload {
  error: string
  code?: string
  detail?: string
}

function profilePage(): RustDeskProAddressBookProfilePageFixture {
  return RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE;
}

function membership(bookGuid: string, peerId: string, membershipId: string,
  alias: string, tags: string[]): RustDeskProPeerMembership {
  const refs: RustDeskProAddressBookTagRef[] = tags.map((name: string): RustDeskProAddressBookTagRef => ({
    tagId: name === 'Ops' ? 'tag-ops-' + bookGuid : 'tag-' + name,
    exactName: name,
    color: 0
  }));
  return {
    accountId: 'account-a', bookGuid, membershipId, peerId, alias, note: '',
    hostname: 'fixture-host', platform: 'Linux', tags: refs,
    lastSeenAt: 0, permission: 'read', readOnly: true
  };
}

class FakeCipher implements RustDeskProAddressBookCacheCipher {
  readonly values: Map<string, string> = new Map<string, string>();

  encrypt(scope: string, plaintext: string): string {
    const ciphertext: string = 'cipher:' + scope + ':' + plaintext.length.toString();
    this.values.set(scope, plaintext);
    return ciphertext;
  }

  decrypt(scope: string, _ciphertext: string): string {
    return this.values.get(scope) ?? '';
  }
}

class FakePersistence implements RustDeskProAddressBookCachePersistence {
  serialized: string = '';
  failWrite: boolean = false;
  failClear: boolean = false;
  failRevoke: boolean = false;
  readonly revoked: Set<string> = new Set<string>();

  read(): string { return this.serialized; }
  write(serialized: string): boolean {
    if (this.failWrite) { return false; }
    this.serialized = serialized;
    return true;
  }
  clear(): boolean {
    if (this.failClear) { return false; }
    this.serialized = '';
    return true;
  }
  revoke(scope: string): boolean {
    if (this.failRevoke) { return false; }
    this.revoked.add(scope);
    return true;
  }
  isRevoked(scope: string): boolean { return this.revoked.has(scope); }
}

export default function rustDeskProAddressBookTest(): void {
  describe('RustDeskProAddressBookPolicy', (): void => {
    it('parses_pinned_modern_profile_tag_membership_contract', 0, (): void => {
      expect(RUSTDESK_PRO_UPSTREAM_COMMIT.length).assertEqual(40);
      const personal = parseRustDeskProAddressBookProfilesPage(
        RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE, 200, 'account-a', 1, 'personal');
      const shared = parseRustDeskProAddressBookProfilesPage(
        profilePage(), 200, 'account-a', 1, 'shared');
      const tags = parseRustDeskProAddressBookTags(
        RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE, 200, 'account-a', 'fixture-personal-book-guid');
      const peers = parseRustDeskProAddressBookPeersPage(
        RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE, 200, 'account-a',
        'fixture-personal-book-guid', 1);
      expect(personal.profiles.length).assertEqual(1);
      expect(personal.profiles[0].permission).assertEqual('fullControl');
      expect(shared.profiles.length).assertEqual(3);
      expect(shared.profiles[0].permission).assertEqual('read');
      expect(shared.profiles[1].permission).assertEqual('readWrite');
      expect(shared.profiles[2].permission).assertEqual('fullControl');
      expect(tags.tags.length).assertEqual(2);
      expect(tags.tags[0].tagId).assertEqual('Ops');
      expect(tags.tags[1].exactName).assertEqual('研发/夜班');
      const sharedTags = parseRustDeskProAddressBookTags(
        RUSTDESK_PRO_AB_TAGS_SHARED_RESPONSE, 200, 'account-a', 'fixture-shared-read-guid');
      expect(sharedTags.tags[0].tagId).assertEqual('Ops');
      expect(rustDeskProAddressBookTagKey(tags.tags[0]) !==
        rustDeskProAddressBookTagKey(sharedTags.tags[0])).assertEqual(true);
      expect(peers.memberships.length).assertEqual(2);
      expect(peers.memberships[0].tags.length).assertEqual(1);

      let rejectedProfile: string = '';
      try {
        const rejectedProfilePage: RejectProfilePage = {
          total: 1,
          data: [{ id: 'generic-id', name: 'not-a-fixed-guid', access: 'fullControl' }]
        };
        parseRustDeskProAddressBookProfilesPage(
          rejectedProfilePage, 200, 'account-a', 1, 'shared');
      } catch (err) {
        rejectedProfile = err instanceof RustDeskProApiError ? err.code : '';
      }
      expect(rejectedProfile).assertEqual('address_book_invalid_profile');
      const explicitPermissionPage: RejectProfilePage = {
        total: 1,
        data: [{ guid: 'fixed-guid', name: 'Fixed', type: 'personal', access: 'fullControl' }]
      };
      const explicitPermission = parseRustDeskProAddressBookProfilesPage(
        explicitPermissionPage, 200, 'account-a', 1, 'shared');
      expect(explicitPermission.profiles[0].kind).assertEqual('shared');
      expect(explicitPermission.profiles[0].permission).assertEqual('read');
      let rejectedPeer: string = '';
      try {
        const rejectedPeerPage: RejectPeerPage = {
          total: 1, data: [{ peer_id: 'wide-alias-peer', alias: 'Alias' }]
        };
        parseRustDeskProAddressBookPeersPage(
          rejectedPeerPage, 200, 'account-a', 'fixed-guid', 1);
      } catch (err) {
        rejectedPeer = err instanceof RustDeskProApiError ? err.code : '';
      }
      expect(rejectedPeer).assertEqual('address_book_invalid_peer');
      const rejectedTagRows: RejectTagRow[] = [
        { id: 'wide-alias-tag', tag: 'Ops', color: 1 }
      ];
      expect(parseRustDeskProAddressBookTags(
        rejectedTagRows, 200, 'account-a', 'fixed-guid').tags.length).assertEqual(0);
    });

    it('classifies_tag_http_errors_without_fallback_or_identity_text', 0, (): void => {
      let notSupported: string = '';
      try {
        parseRustDeskProAddressBookTags(RUSTDESK_PRO_AB_TAG_FAILURE_RESPONSE, 404,
          'account-a', 'fixture-book');
      } catch (err) {
        notSupported = err instanceof RustDeskProApiError ? err.code : '';
      }
      expect(notSupported).assertEqual('address_book_http_error');
      let tag400: string = '';
      const tag400Payload: AddressBookErrorPayload = { error: 'rate_limited' };
      try { parseRustDeskProAddressBookTags(tag400Payload, 400,
        'account-a', 'fixture-book'); }
      catch (err) { tag400 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(tag400).assertEqual('address_book_rate_limited');
      let tag405: string = '';
      const tag405Payload: AddressBookErrorPayload = { error: 'method_not_allowed' };
      try { parseRustDeskProAddressBookTags(tag405Payload, 405,
        'account-a', 'fixture-book'); }
      catch (err) { tag405 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(tag405).assertEqual('address_book_http_error');
      const personal404Payload: AddressBookErrorPayload = { error: 'endpoint_not_found' };
      expect(parseRustDeskProAddressBookPersonalProfile(
        personal404Payload, 404, 'account-a')).assertEqual(null);
      const shared404Payload: AddressBookErrorPayload = { error: 'endpoint_not_found' };
      const shared404 = parseRustDeskProAddressBookProfilesPage(
        shared404Payload, 404, 'account-a', 1, 'shared');
      expect(shared404.supported).assertFalse();
      let unknown404: string = '';
      const unknown404Payload: AddressBookErrorPayload = {
        error: 'human text says route is absent'
      };
      try { parseRustDeskProAddressBookProfilesPage(
        unknown404Payload, 404, 'account-a', 1, 'shared'); }
      catch (err) { unknown404 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(unknown404).assertEqual('address_book_http_error');
      let personal400: string = '';
      const personal400Payload: AddressBookErrorPayload = { error: 'auth_required' };
      try { parseRustDeskProAddressBookPersonalProfile(
        personal400Payload, 400, 'account-a'); }
      catch (err) { personal400 = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(personal400).assertEqual('token_expired');
      let expired: string = '';
      const expiredPayload: AddressBookErrorPayload = { error: 'token secret-peer' };
      try {
        parseRustDeskProAddressBookTags(expiredPayload, 401,
          'account-a', 'fixture-book');
      } catch (err) {
        expired = err instanceof RustDeskProApiError ? err.code : '';
        const message: string = err instanceof Error ? err.message : '';
        expect(message.indexOf('secret-peer')).assertEqual(-1);
      }
      expect(expired).assertEqual('token_expired');
    });

    it('keeps_cross_book_same_text_and_same_peer_memberships_distinct', 0, (): void => {
      const personalTag: RustDeskProAddressBookTag = {
        accountId: 'account-a', bookGuid: 'book-personal', tagId: 'tag-1',
        exactName: 'Ops', color: 1, serverOrder: 1
      };
      const sharedTag: RustDeskProAddressBookTag = {
        accountId: 'account-a', bookGuid: 'book-shared', tagId: 'tag-2',
        exactName: 'Ops', color: 2, serverOrder: 1
      };
      expect(rustDeskProAddressBookTagKey(personalTag) !==
        rustDeskProAddressBookTagKey(sharedTag)).assertEqual(true);
      expect(rustDeskProAddressBookBookKey('account-a', 'book-personal') !==
        rustDeskProAddressBookBookKey('account-a', 'book-shared')).assertEqual(true);
      const first = membership('book-personal', 'peer-1', 'membership-personal', 'Personal', ['Ops']);
      const second = membership('book-shared', 'peer-1', 'membership-shared', 'Shared', ['Ops']);
      expect(rustDeskProAddressBookMembershipKey(first) !==
        rustDeskProAddressBookMembershipKey(second)).assertEqual(true);
      expect(first.alias !== second.alias).assertEqual(true);
    });

    it('maps_permission_without_granting_write_to_read_only_books', 0, (): void => {
      const values: string[] = ['read', 'readWrite', 'fullControl', 'unknown'];
      const permissions: RustDeskProAddressBookPermission[] = values.map(
        (value: string): RustDeskProAddressBookPermission => parseRustDeskProAddressBookPermission(value));
      expect(permissions[0]).assertEqual('read');
      expect(permissions[1]).assertEqual('readWrite');
      expect(permissions[2]).assertEqual('fullControl');
      expect(permissions[3]).assertEqual('read');
      expect(parseRustDeskProAddressBookPermission(2)).assertEqual('readWrite');
      expect(parseRustDeskProAddressBookPermission(3)).assertEqual('fullControl');
      expect(parseRustDeskProAddressBookPermission(0)).assertEqual('read');
    });

    it('supports_untagged_single_or_and_clear_and_search_scope', 0, (): void => {
      const otherAccountMembership: RustDeskProPeerMembership =
        membership('book-a', 'peer-a', 'm-other-account', 'Other account', ['Ops']);
      otherAccountMembership.accountId = 'account-b';
      const peers: RustDeskProPeerMembership[] = [
        membership('book-a', 'peer-a', 'm-a', 'Alpha alias', ['Ops', 'Night']),
        membership('book-a', 'peer-b', 'm-b', 'Beta alias', ['Ops']),
        membership('book-a', 'peer-c', 'm-c', 'Gamma alias', []),
        otherAccountMembership
      ];
      const base: RustDeskProAddressBookFilter = {
        accountId: 'account-a', bookGuid: 'book-a', selectedTagIds: [],
        includeUntagged: false, mode: 'or', text: ''
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], base).length).assertEqual(3);
      const missingTagFilter: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid, selectedTagIds: ['tag-Ops'],
        includeUntagged: base.includeUntagged, mode: 'or', text: base.text
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], missingTagFilter).length)
        .assertEqual(0);
      const opsIds: string[] = [peers[0].tags[0].tagId, peers[0].tags[1].tagId];
      const oneTag: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid, selectedTagIds: [opsIds[0]],
        includeUntagged: base.includeUntagged, mode: 'or', text: base.text
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], oneTag).length).assertEqual(2);
      const andFilter: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid, selectedTagIds: opsIds,
        includeUntagged: base.includeUntagged, mode: 'and', text: base.text
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], andFilter).length).assertEqual(1);
      const untaggedFilter: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid, selectedTagIds: base.selectedTagIds,
        includeUntagged: true, mode: base.mode, text: base.text
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], untaggedFilter).length)
        .assertEqual(1);
      const textFilter: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid, selectedTagIds: base.selectedTagIds,
        includeUntagged: base.includeUntagged, mode: base.mode, text: 'alpha'
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], textFilter).length)
        .assertEqual(1);
      // Partial-token search keeps the legacy substring contract; the
      // production index must fall back instead of losing this match.
      const partialTextFilter: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: base.bookGuid,
        selectedTagIds: base.selectedTagIds, includeUntagged: base.includeUntagged,
        mode: base.mode, text: 'lph'
      };
      expect(filterRustDeskProAddressBookMemberships(peers, [], partialTextFilter).length)
        .assertEqual(1);

      const sameTagOtherBook: RustDeskProPeerMembership =
        membership('book-b', 'peer-d', 'm-d', 'Other book', ['Ops']);
      sameTagOtherBook.tags = [{
        tagId: peers[0].tags[0].tagId, exactName: 'Ops', color: 0
      }];
      const allBooksTag: RustDeskProAddressBookTag = {
        accountId: 'account-a', bookGuid: 'book-a', tagId: peers[0].tags[0].tagId,
        exactName: 'Ops', color: 0, serverOrder: 0
      };
      const allBooks: RustDeskProAddressBookFilter = {
        accountId: base.accountId, bookGuid: '', text: '',
        selectedTagIds: [rustDeskProAddressBookTagSelectionKey(allBooksTag)],
        includeUntagged: base.includeUntagged, mode: base.mode
      };
      expect(filterRustDeskProAddressBookMemberships(
        peers.concat([sameTagOtherBook]), [], allBooks).length).assertEqual(2);
    });

    it('parses_legacy_without_merging_it_into_modern_identity', 0, (): void => {
      const legacy = parseRustDeskProAddressBookLegacy(
        RUSTDESK_PRO_AB_LEGACY_RESPONSE, 200, 'account-a');
      expect(legacy.profile.kind).assertEqual('legacy');
      expect(legacy.memberships.length).assertEqual(1);
      expect(legacy.memberships[0].bookGuid).assertEqual('legacy');
      expect(legacy.tags.length).assertEqual(1);
    });

    it('stores_only_owner_scoped_ciphertext_and_clears_account', 0, (): void => {
      const cipher = new FakeCipher();
      const persistence = new FakePersistence();
      const cache = new RustDeskProAddressBookCache(cipher, persistence);
      const snapshot: RustDeskProAddressBookSnapshot = {
        accountId: 'account-a', origin: 'https://pro-a.example', tokenGeneration: 3,
        generation: 7, revision: 'r1', profiles: [], tags: [], memberships: [],
        state: 'fresh', stale: false, errorCode: '', syncedAt: 1
      };
      expect(cache.put(snapshot)).assertTrue();
      expect(cache.ciphertextForTest(snapshot)).assertTrue();
      expect(persistence.serialized.indexOf('r1')).assertEqual(-1);
      expect(cache.get('account-a', 'https://pro-a.example', 3) !== null).assertTrue();
      const reloaded = new RustDeskProAddressBookCache(cipher, persistence);
      expect(reloaded.get('account-a', 'https://pro-a.example', 3) !== null).assertTrue();
      expect(cache.get('account-b', 'https://pro-a.example', 3) === null).assertTrue();
      expect(cache.clearAccount('account-a')).assertTrue();
      expect(cache.get('account-a', 'https://pro-a.example', 3) === null).assertTrue();
      const clearedReloaded = new RustDeskProAddressBookCache(cipher, persistence);
      expect(clearedReloaded.get('account-a', 'https://pro-a.example', 3) === null).assertTrue();

      const failedPersistence = new FakePersistence();
      failedPersistence.failWrite = true;
      const failedCache = new RustDeskProAddressBookCache(new FakeCipher(), failedPersistence);
      expect(failedCache.put(snapshot)).assertFalse();
      expect(failedCache.ciphertextForTest(snapshot)).assertFalse();
      expect(failedCache.get('account-a', 'https://pro-a.example', 3) === null).assertTrue();

      const deleteFailure = new FakePersistence();
      const deleteCipher = new FakeCipher();
      const deleteCache = new RustDeskProAddressBookCache(deleteCipher, deleteFailure);
      expect(deleteCache.put(snapshot)).assertTrue();
      deleteFailure.failClear = true;
      deleteFailure.failWrite = true;
      expect(deleteCache.clearAll()).assertTrue();
      const reloadedAfterDeleteFailure =
        new RustDeskProAddressBookCache(deleteCipher, deleteFailure);
      expect(reloadedAfterDeleteFailure.get(
        'account-a', 'https://pro-a.example', 3) === null).assertTrue();

      const irrecoverable = new FakePersistence();
      const irrecoverableCache = new RustDeskProAddressBookCache(
        new FakeCipher(), irrecoverable);
      expect(irrecoverableCache.put(snapshot)).assertTrue();
      irrecoverable.failClear = true;
      irrecoverable.failWrite = true;
      irrecoverable.failRevoke = true;
      expect(irrecoverableCache.clearAll()).assertFalse();
      expect(irrecoverableCache.get(
        'account-a', 'https://pro-a.example', 3) !== null).assertTrue();
    });

    it('tombstone_blocks_lkg_after_primary_clear_failure_on_reload', 0, (): void => {
      const persistence = new FakePersistence();
      const cipher = new FakeCipher();
      const cache = new RustDeskProAddressBookCache(cipher, persistence);
      const accountA: RustDeskProAddressBookSnapshot = {
        accountId: 'account-a', origin: 'https://pro-a.example', tokenGeneration: 1,
        generation: 1, revision: 'a1', profiles: [], tags: [], memberships: [],
        state: 'fresh', stale: false, errorCode: '', syncedAt: 1
      };
      const accountB: RustDeskProAddressBookSnapshot = {
        accountId: 'account-b', origin: 'https://pro-b.example', tokenGeneration: 1,
        generation: 1, revision: 'b1', profiles: [], tags: [], memberships: [],
        state: 'fresh', stale: false, errorCode: '', syncedAt: 1
      };
      expect(cache.put(accountA)).assertTrue();
      expect(cache.put(accountB)).assertTrue();
      persistence.failClear = true;
      persistence.failWrite = true;
      // The primary delete cannot commit, so the cache must persist an
      // opaque owner-scope tombstone before claiming privacy completion.
      expect(cache.clearAccount('account-a')).assertTrue();
      const reloaded = new RustDeskProAddressBookCache(cipher, persistence);
      expect(reloaded.get('account-a', 'https://pro-a.example', 1) === null).assertTrue();
      expect(reloaded.get('account-b', 'https://pro-b.example', 1) !== null).assertTrue();
    });
  });
}
