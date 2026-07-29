import { describe, it, expect } from '@ohos/hypium';
import {
  accountSessionLease,
  accountSessionLeaseEquals,
  accountScopeToken,
  accountStoreIdentity,
  cloudAccountBindingForScope,
  cloneAccountSessionLease,
  deviceLocalScopeToken,
  ownerRecordWriteAllowed,
  ownerScopeIdForUnionId,
  scopeTokenIsCurrent,
  stableAccountIdentifierIsValid,
  verifyAccountScopeCloudBinding
} from '../main/ets/services/AccountScopePolicy';
import { UserAccount } from '../main/ets/model/UserAccount';

export default function accountScopePolicyTest(): void {
  describe('AccountScopePolicy', (): void => {
    it('rejects_empty_stable_account_identifiers', 0, (): void => {
      expect(stableAccountIdentifierIsValid('')).assertFalse();
      expect(stableAccountIdentifierIsValid('   ')).assertFalse();
      expect(ownerScopeIdForUnionId('')).assertEqual('');
      expect(accountScopeToken('', 1) === null).assertTrue();
    });

    it('derives_stable_opaque_account_store_identity', 0, (): void => {
      const first: string = ownerScopeIdForUnionId('union-a');
      const again: string = ownerScopeIdForUnionId(' union-a ');
      const second: string = ownerScopeIdForUnionId('union-b');
      expect(first).assertEqual(again);
      expect(first === second).assertFalse();
      expect(first.indexOf('union-a')).assertEqual(-1);
      expect(accountStoreIdentity(first).indexOf('union-a')).assertEqual(-1);
    });

    it('keeps_device_local_and_account_scopes_physically_separate', 0, (): void => {
      const local = deviceLocalScopeToken(1);
      const account = accountScopeToken('union-a', 2);
      expect(account === null).assertFalse();
      if (account === null) { return; }
      expect(local.storeIdentity === account.storeIdentity).assertFalse();
      expect(local.cloudBindingState).assertEqual('unbound');
      expect(account.cloudBindingState).assertEqual('validating');
      expect(scopeTokenIsCurrent(account, 2)).assertTrue();
      expect(scopeTokenIsCurrent(account, 1)).assertFalse();
      expect(cloudAccountBindingForScope(account).state).assertEqual('validating');
    });

    it('binds_cloud_only_to_the_current_verified_account_identity', 0, (): void => {
      const account = accountScopeToken('union-a', 2);
      expect(account === null).assertFalse();
      if (account === null) { return; }
      const bound = verifyAccountScopeCloudBinding(account, ' union-a ');
      expect(bound.cloudBindingState).assertEqual('bound');
      expect(bound.ownerScopeId).assertEqual(account.ownerScopeId);
      expect(bound.storeIdentity).assertEqual(account.storeIdentity);

      const wrongAccount =
        verifyAccountScopeCloudBinding(account, 'union-b');
      expect(wrongAccount.cloudBindingState).assertEqual('blocked');
      const missingIdentity =
        verifyAccountScopeCloudBinding(account, '');
      expect(missingIdentity.cloudBindingState).assertEqual('blocked');

      const forgedStore = accountScopeToken('union-a', 3);
      expect(forgedStore === null).assertFalse();
      if (forgedStore === null) { return; }
      forgedStore.storeIdentity = 'remotedesktop_owner-forged.db';
      expect(verifyAccountScopeCloudBinding(
        forgedStore, 'union-a').cloudBindingState).assertEqual('blocked');
    });

    it('never_promotes_device_local_data_to_account_cloud', 0, (): void => {
      const local = verifyAccountScopeCloudBinding(
        deviceLocalScopeToken(1), 'union-a');
      expect(local.cloudBindingState).assertEqual('unbound');
      expect(cloudAccountBindingForScope(local).state).assertEqual('unbound');
    });

    it('rejects_empty_login_and_clears_every_identity_field_on_logout', 0, (): void => {
      const account: UserAccount = new UserAccount();
      expect(account.setLoggedIn('', 'stale', 'avatar', 'token')).assertFalse();
      expect(account.isLoggedIn).assertFalse();
      expect(account.unionId).assertEqual('');
      expect(account.setLoggedIn('union-a', 'User A', 'avatar-a', 'token-a')).assertTrue();
      account.setLoggedOut();
      expect(account.isLoggedIn).assertFalse();
      expect(account.unionId).assertEqual('');
      expect(account.displayName).assertEqual('');
      expect(account.avatarUrl).assertEqual('');
      expect(account.authToken).assertEqual('');
      expect(account.loginTime).assertEqual(0);
    });

    it('fences_reopened_stores_with_an_immutable_instance_id', 0, (): void => {
      const scope = accountScopeToken('union-a', 7);
      expect(scope === null).assertFalse();
      if (scope === null) { return; }
      const first = accountSessionLease(scope, 11);
      const same = cloneAccountSessionLease(first);
      const reopened = accountSessionLease(scope, 12);
      expect(accountSessionLeaseEquals(first, same)).assertTrue();
      expect(accountSessionLeaseEquals(first, reopened)).assertFalse();
    });

    it('claims_only_blank_drafts_and_never_rebinds_foreign_records', 0, (): void => {
      expect(ownerRecordWriteAllowed('', '')).assertFalse();
      expect(ownerRecordWriteAllowed('owner-a', '')).assertTrue();
      expect(ownerRecordWriteAllowed('owner-a', ' owner-a ')).assertTrue();
      expect(ownerRecordWriteAllowed('owner-a', 'owner-b')).assertFalse();
    });
  });
}
