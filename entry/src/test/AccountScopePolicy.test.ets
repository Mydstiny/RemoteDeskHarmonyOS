import { describe, it, expect } from '@ohos/hypium';
import {
  accountSessionLease,
  accountSessionLeaseEquals,
  accountCloudStoreIdentity,
  accountScopeRebindSucceeded,
  accountLocalCompatibilityScopeToken,
  accountScopeToken,
  accountStoreIdentity,
  cloudAccountBindingForScope,
  cloneAccountSessionLease,
  cryptoParamCloudRecordId,
  deviceLocalScopeToken,
  legacyScopedCryptoParamRecordId,
  ownerRecordWriteAllowed,
  ownerScopeIdForUnionId,
  scopeTokenIsCurrent,
  stableAccountIdentifierIsValid,
  verifyAccountScopeCloudBinding
} from '../main/ets/services/AccountScopePolicy';
import { UserAccount } from '../main/ets/model/UserAccount';
import { cloudTransferAllowed } from '../main/ets/services/CloudLifecycleSafetyPolicy';
import {
  PlatformCloudIdentityProof,
  platformCloudIdentityProofFromApi23,
  unavailablePlatformCloudIdentityProof
} from '../main/ets/services/PlatformCloudIdentityPolicy';

function platformProof(id: string = 'union-a'):
  PlatformCloudIdentityProof {
  return platformCloudIdentityProofFromApi23(id, true);
}

export default function accountScopePolicyTest(): void {
  describe('AccountScopePolicy', (): void => {
    it('falls_back_to_same_owner_local_store_without_rolling_back_login', 0,
      (): void => {
        const requested = accountScopeToken(
          'union-a', 9, 'switching', 'validating',
          platformProof('union-a'))!;
        const fallback =
          accountLocalCompatibilityScopeToken(requested);
        expect(fallback !== null).assertTrue();
        expect(fallback!.ownerScopeId)
          .assertEqual(requested.ownerScopeId);
        expect(fallback!.generation)
          .assertEqual(requested.generation);
        expect(fallback!.storeIdentity)
          .assertEqual(accountStoreIdentity(
            requested.ownerScopeId));
        expect(fallback!.cloudBindingState)
          .assertEqual('validating');
        expect(fallback!.platformIdentityFingerprint)
          .assertEqual(requested.platformIdentityFingerprint);
        expect(accountLocalCompatibilityScopeToken(
          deviceLocalScopeToken(9)) === null).assertTrue();
      });
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

    it('derives_bounded_cloud_safe_crypto_parameter_record_ids', 0, (): void => {
      const ownerA: string = ownerScopeIdForUnionId('union-a');
      const ownerB: string = ownerScopeIdForUnionId('union-b');
      const first: string = cryptoParamCloudRecordId(
        ownerA, 'crypto_status');
      const again: string = cryptoParamCloudRecordId(
        ' ' + ownerA + ' ', ' crypto_status ');
      const otherOwner: string = cryptoParamCloudRecordId(
        ownerB, 'crypto_status');
      expect(first).assertEqual(again);
      expect(first.length).assertEqual(32);
      expect(/^[0-9a-f]{32}$/.test(first)).assertTrue();
      expect(first === otherOwner).assertFalse();
      expect(legacyScopedCryptoParamRecordId(
        ownerA, 'crypto_status')).assertEqual(
        'crypto-param|' + ownerA + '|crypto_status');
    });

    it('keeps_device_local_and_account_scopes_physically_separate', 0, (): void => {
      const local = deviceLocalScopeToken(1);
      const proof: PlatformCloudIdentityProof =
        platformProof();
      const account = accountScopeToken(
        'union-a', 2, 'bound', 'validating',
        proof);
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
      const proof: PlatformCloudIdentityProof =
        platformProof();
      const account = accountScopeToken(
        'union-a', 2, 'bound', 'validating',
        proof);
      expect(account === null).assertFalse();
      if (account === null) { return; }
      const bound = verifyAccountScopeCloudBinding(
        account, ' union-a ', proof);
      expect(bound.cloudBindingState).assertEqual('bound');
      expect(bound.ownerScopeId).assertEqual(account.ownerScopeId);
      expect(bound.storeIdentity).assertEqual(account.storeIdentity);

      const wrongAccount =
        verifyAccountScopeCloudBinding(
          account, 'union-b', proof);
      expect(wrongAccount.cloudBindingState).assertEqual('blocked');
      const missingIdentity =
        verifyAccountScopeCloudBinding(
          account, '', proof);
      expect(missingIdentity.cloudBindingState).assertEqual('blocked');

      const forgedStore = accountScopeToken(
        'union-a', 3, 'bound', 'validating',
        proof);
      expect(forgedStore === null).assertFalse();
      if (forgedStore === null) { return; }
      forgedStore.storeIdentity = 'remotedesktop_owner-forged.db';
      expect(verifyAccountScopeCloudBinding(
        forgedStore, 'union-a',
        proof).cloudBindingState).assertEqual('blocked');

      // A canonical store opened without a valid platform proof (or with a
      // proof from another account) stays locally usable; only cloud transfer
      // remains fail-closed.
      expect(verifyAccountScopeCloudBinding(
        account, 'union-a',
        unavailablePlatformCloudIdentityProof())
        .cloudBindingState).assertEqual('validating');
      expect(verifyAccountScopeCloudBinding(
        account, 'union-a',
        platformProof('union-b'))
        .cloudBindingState).assertEqual('validating');
    });

    it('verified_account_targets_the_canonical_cloud_store', 0, (): void => {
      const proof: PlatformCloudIdentityProof =
        platformProof();
      const account = accountScopeToken(
        'union-a', 5, 'bound', 'validating', proof);
      expect(account === null).assertFalse();
      if (account === null) { return; }
      // AGC cloud binding requires storeId == database.name (`remotedesktop`),
      // so a verified account must open exactly the canonical cloud store.
      expect(account.storeIdentity).assertEqual('remotedesktop.db');
      expect(accountCloudStoreIdentity()).assertEqual('remotedesktop.db');
      expect(account.storeIdentity ===
        accountStoreIdentity(account.ownerScopeId)).assertFalse();
      const bound = verifyAccountScopeCloudBinding(
        account, 'union-a', proof);
      expect(bound.cloudBindingState).assertEqual('bound');
      expect(bound.storeIdentity).assertEqual('remotedesktop.db');
      expect(cloudAccountBindingForScope(bound).storeIdentity)
        .assertEqual('remotedesktop.db');
    });

    it('unverified_account_keeps_local_only_hashed_store', 0, (): void => {
      const account = accountScopeToken(
        'union-a', 6, 'bound', 'validating',
        unavailablePlatformCloudIdentityProof());
      expect(account === null).assertFalse();
      if (account === null) { return; }
      const hashed: string =
        accountStoreIdentity(account.ownerScopeId);
      expect(account.storeIdentity).assertEqual(hashed);
      expect(account.storeIdentity === 'remotedesktop.db').assertFalse();
      const local = verifyAccountScopeCloudBinding(
        account, 'union-a',
        unavailablePlatformCloudIdentityProof());
      expect(local.cloudBindingState).assertEqual('validating');
      expect(cloudTransferAllowed(
        cloudAccountBindingForScope(local))).assertFalse();
    });

    it('hashed_local_only_scope_can_never_promote_to_cloud', 0, (): void => {
      const account = accountScopeToken(
        'union-a', 8, 'bound', 'validating',
        unavailablePlatformCloudIdentityProof());
      expect(account === null).assertFalse();
      if (account === null) { return; }
      // Even a later valid proof cannot turn a hashed local-only store into a
      // cloud-bound store; the physical store id must equal the AGC schema.
      const bound = verifyAccountScopeCloudBinding(
        account, 'union-a', platformProof());
      expect(bound.cloudBindingState).assertEqual('validating');
      expect(cloudTransferAllowed(
        cloudAccountBindingForScope(bound))).assertFalse();
    });

    it('accepts_only_the_same_owner_canonical_to_hashed_local_rebind_fallback', 0,
      (): void => {
        const proof: PlatformCloudIdentityProof = platformProof();
        const requested = accountScopeToken(
          'union-a', 9, 'bound', 'validating', proof);
        expect(requested === null).assertFalse();
        if (requested === null) { return; }
        const active = verifyAccountScopeCloudBinding({
          kind: requested.kind,
          ownerScopeId: requested.ownerScopeId,
          generation: requested.generation,
          sessionState: requested.sessionState,
          cloudBindingState: 'validating',
          storeIdentity: accountStoreIdentity(requested.ownerScopeId),
          schemaRevision: 5,
          selectionRevision: requested.selectionRevision,
          platformIdentityFingerprint: requested.platformIdentityFingerprint
        }, 'union-a', proof);
        expect(active.cloudBindingState).assertEqual('validating');
        expect(accountScopeRebindSucceeded(requested, active)).assertTrue();

        const otherOwner = accountScopeToken(
          'union-b', 9, 'bound', 'validating', proof);
        expect(otherOwner === null).assertFalse();
        if (otherOwner === null) { return; }
        expect(accountScopeRebindSucceeded(requested, otherOwner)).assertFalse();

        const wrongGeneration = {
          kind: active.kind,
          ownerScopeId: active.ownerScopeId,
          generation: active.generation + 1,
          sessionState: active.sessionState,
          cloudBindingState: active.cloudBindingState,
          storeIdentity: active.storeIdentity,
          schemaRevision: active.schemaRevision,
          selectionRevision: active.selectionRevision,
          platformIdentityFingerprint: active.platformIdentityFingerprint
        };
        expect(accountScopeRebindSucceeded(requested, wrongGeneration)).assertFalse();

        active.platformIdentityFingerprint = 'foreign-platform-proof';
        expect(accountScopeRebindSucceeded(requested, active)).assertFalse();
        active.platformIdentityFingerprint =
          requested.platformIdentityFingerprint;
        active.cloudBindingState = 'blocked';
        expect(accountScopeRebindSucceeded(requested, active)).assertFalse();
      });

    it('never_promotes_device_local_data_to_account_cloud', 0, (): void => {
      const local = verifyAccountScopeCloudBinding(
        deviceLocalScopeToken(1), 'union-a',
        unavailablePlatformCloudIdentityProof());
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
      const proof: PlatformCloudIdentityProof =
        platformProof();
      const scope = accountScopeToken(
        'union-a', 7, 'bound', 'validating',
        proof);
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
