import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RustDeskProAddressBookProfile,
  RustDeskProPeerMembership
} from '../main/ets/model/RustDeskProModels';
import {
  rustDeskProAddressBookCardPermissionLabel,
  rustDeskProAddressBookCardTagSummary,
  rustDeskProAddressBookMutationVisible,
  rustDeskProAddressBookProfileAccessibilityLabel,
  rustDeskProAddressBookVisibleCounts
} from '../main/ets/services/RustDeskProAddressBookUiPolicy';
import { RemoteHost } from '../main/ets/model/RemoteHost';

interface UiTagRefFixture {
  tagId: string
  exactName: string
  color: number
}

function membership(bookGuid: string, readOnly: boolean,
  tags: UiTagRefFixture[]): RustDeskProPeerMembership {
  return {
    accountId: 'account-a', bookGuid, membershipId: bookGuid + '-membership',
    peerId: 'peer-1', alias: '', note: '', hostname: 'host-1', platform: 'Linux',
    tags, lastSeenAt: 0, permission: readOnly ? 'read' : 'readWrite', readOnly
  };
}

function profile(kind: 'personal' | 'shared' | 'legacy', canWrite: boolean): RustDeskProAddressBookProfile {
  return {
    accountId: 'account-a', bookGuid: kind + '-book', name: kind + ' book', kind,
    ownerDisplay: '', permission: canWrite ? 'readWrite' : 'read', canWrite,
    fullControl: false, revision: '', updatedAt: 0, syncState: 'fresh'
  };
}

export default function rustDeskProAddressBookUiPolicyTest(): void {
  describe('RustDeskProAddressBookUiPolicy', (): void => {
    it('aggregates_multi_book_tags_without_showing_more_than_three', 0, (): void => {
      const personalTags: UiTagRefFixture[] = [
        { tagId: 'ops', exactName: 'Ops', color: 1 },
        { tagId: 'night', exactName: '夜班', color: 2 }
      ];
      const sharedTags: UiTagRefFixture[] = [
        { tagId: 'ops-shared', exactName: 'Ops', color: 3 },
        { tagId: 'prod', exactName: '生产', color: 4 }
      ];
      const memberships: RustDeskProPeerMembership[] = [
        membership('personal', false, personalTags),
        membership('shared', true, sharedTags)
      ];
      const summary = rustDeskProAddressBookCardTagSummary(memberships);
      expect(summary.visible.length).assertEqual(3);
      expect(summary.additionalCount).assertEqual(1);
      expect(summary.accessibilityLabel.indexOf('夜班') >= 0).assertTrue();
      expect(summary.accessibilityLabel.indexOf('生产') >= 0).assertTrue();
    });

    it('exposes_mixed_permission_and_preserves_read_only_gate', 0, (): void => {
      const memberships: RustDeskProPeerMembership[] = [
        membership('personal', false, []), membership('shared', true, [])
      ];
      expect(rustDeskProAddressBookCardPermissionLabel(memberships)).assertEqual('权限不同');
      expect(rustDeskProAddressBookMutationVisible(profile('shared', false))).assertFalse();
      expect(rustDeskProAddressBookMutationVisible(profile('shared', true))).assertTrue();
      expect(rustDeskProAddressBookMutationVisible(profile('legacy', true))).assertFalse();
    });

    it('labels_book_permission_for_screen_reader', 0, (): void => {
      const readOnly = profile('shared', false);
      expect(rustDeskProAddressBookProfileAccessibilityLabel(readOnly))
        .assertEqual('地址簿 shared book，只读权限');
      const first = new RemoteHost();
      first.id = 'host-one';
      const second = new RemoteHost();
      second.id = 'host-two';
      const sharedDuplicate: RustDeskProPeerMembership = membership('shared', true, []);
      sharedDuplicate.membershipId = 'shared-duplicate';
      const sharedSecondDuplicate: RustDeskProPeerMembership = membership('shared', true, []);
      sharedSecondDuplicate.membershipId = 'shared-second-duplicate';
      const memberships: RustDeskProPeerMembership[] = [
        membership('personal', false, []),
        sharedDuplicate,
        sharedSecondDuplicate
      ];
      const counts = rustDeskProAddressBookVisibleCounts(memberships, [first, second]);
      expect(counts.membershipCount).assertEqual(3);
      expect(counts.hostCount).assertEqual(2);
      expect(counts.membershipCount !== counts.hostCount).assertEqual(true);
    });
  });
}
