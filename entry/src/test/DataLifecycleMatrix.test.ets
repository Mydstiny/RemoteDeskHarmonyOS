import { describe, expect, it } from '@ohos/hypium';
import {
  AccountSessionLease,
  accountScopeToken,
  accountSessionLease,
  cloudAccountBindingForScope,
  deviceLocalScopeToken,
  verifyAccountScopeCloudBinding
} from '../main/ets/services/AccountScopePolicy';
import {
  cloudDistributedRegistrationAllowed,
  cloudTransferAllowed
} from '../main/ets/services/CloudLifecycleSafetyPolicy';
import {
  CLOUD_SYNC_ACCEPT_TIMEOUT_MS,
  CloudSyncWatchdogState,
  classifyCloudSyncFailure,
  cloudSyncWatchdogTimeoutKind,
  shouldBlockAutomaticRetry,
  shouldDeferAutomaticPushDuringBootstrap,
  shouldUseCloudFirstForInitialBootstrap
} from '../main/ets/services/CloudSyncCoordinatorPolicy';
import {
  cloudSelectionAfterLocalCryptoTransition,
  cloudTableRowsAreDownloadCompatible,
  cloudTableRowsAreUploadSafe,
  vncSelectionAfterLocalCryptoTransition
} from '../main/ets/services/CloudSensitiveTransferPolicy';
import {
  CryptoCommittedState,
  CryptoLifecycleDurableState,
  cryptoLifecycleOperationStarted,
  newCryptoLifecycleDurableState,
  recoverCryptoLifecycleDurableState
} from '../main/ets/services/CryptoLifecyclePolicy';
import { CLOUD_SYNC_TABLES } from '../main/ets/services/CloudSyncPolicy';
import {
  LocalBackupDocument,
  adaptLocalBackupDocumentForRestore,
  createLocalBackupDocument,
  createLocalBackupRestorePreview,
  localBackupCanonicalPayload,
  localBackupSha256,
  validateLocalBackupDocument
} from '../main/ets/services/LocalBackupPolicy';
import {
  parseLegacyRelayJson
} from '../main/ets/services/LegacyRelayMigrationPolicy';
import {
  PlatformCloudIdentityProof,
  platformCloudIdentityProofFromApi23
} from '../main/ets/services/PlatformCloudIdentityPolicy';

function emptyTables(): Record<string, Array<Record<string, string>>> {
  const result: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    result[CLOUD_SYNC_TABLES[i]] = [];
  }
  return result;
}

function activeCrypto(): CryptoCommittedState {
  return {
    status: 'active',
    configured: true,
    kdfVersion: 2,
    kdfIterations: 600000,
    keyVersion: 1,
    verifierVersion: 2,
    envelopeVersion: 3
  };
}

function encrypted(value: string): boolean {
  return value.indexOf('3:') === 0;
}

function legacySevenTableDocument(): LocalBackupDocument {
  const current: Record<string, Array<Record<string, string>>> =
    emptyTables();
  const tables: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    if (table !== 'vncrecord') { tables[table] = current[table]; }
  }
  tables['remotehosts'].push({
    id: 'legacy-host',
    userid: 'legacy-owner',
    label: 'Legacy',
    passward: 'legacy-password'
  });
  const inventory: string[] = Object.keys(tables);
  const payload: string = localBackupCanonicalPayload(
    100, '1.0.5', tables, undefined, 1,
    undefined, undefined, inventory);
  return {
    format: 'remotedesktop-local-backup',
    version: 1,
    createdAt: 100,
    appVersion: '1.0.5',
    tables,
    sha256: localBackupSha256(payload)
  };
}

export default function dataLifecycleMatrixTest(): void {
  describe('DataLifecycleMatrix', (): void => {
    it('new_machine_starts_device_local_and_cannot_touch_account_cloud',
      0, (): void => {
        const local = deviceLocalScopeToken(1);
        const binding = cloudAccountBindingForScope(local);
        expect(local.kind).assertEqual('device_local');
        expect(cloudDistributedRegistrationAllowed(binding))
          .assertFalse();
        expect(cloudTransferAllowed(binding)).assertFalse();
      });

    it('new_device_login_requires_exact_identity_then_pulls_before_push',
      0, (): void => {
        const proof: PlatformCloudIdentityProof =
          platformCloudIdentityProofFromApi23(
            'union-a', true);
        const candidate = accountScopeToken(
          'union-a', 2, 'bound', 'validating',
          proof.fingerprint);
        expect(candidate !== null).assertTrue();
        if (candidate === null) { return; }
        expect(cloudTransferAllowed(
          cloudAccountBindingForScope(candidate))).assertFalse();
        const bound = verifyAccountScopeCloudBinding(
          candidate, ' union-a ', proof);
        expect(cloudTransferAllowed(
          cloudAccountBindingForScope(bound))).assertTrue();
        expect(verifyAccountScopeCloudBinding(
          candidate, 'union-b',
          proof).cloudBindingState)
          .assertEqual('blocked');
        expect(shouldUseCloudFirstForInitialBootstrap(false))
          .assertTrue();
        expect(shouldDeferAutomaticPushDuringBootstrap('pending'))
          .assertTrue();
      });

    it('network_or_payload_uncertainty_fails_closed_without_remote_wipe',
      0, (): void => {
        const waiting: CloudSyncWatchdogState = {
          startedAt: 1000,
          lastSignalAt: 1000,
          signalObserved: false,
          settled: false
        };
        expect(cloudSyncWatchdogTimeoutKind(
          waiting, 1000 + CLOUD_SYNC_ACCEPT_TIMEOUT_MS))
          .assertEqual('accept_timeout');
        expect(classifyCloudSyncFailure(
          'UNSAFE_CLOUD_PAYLOAD plaintext remotehosts'))
          .assertEqual('unsafe_payload');
        expect(shouldBlockAutomaticRetry('unsafe_payload'))
          .assertTrue();
        expect(cloudTableRowsAreUploadSafe(
          'remotehosts', [], false, encrypted))
          .assertFalse();
        expect(cloudTableRowsAreDownloadCompatible(
          'remotehosts', [{
            id: 'host-1', passward: 'plaintext'
          }], true, encrypted)).assertFalse();
      });

    it('portable_backup_is_redacted_owned_and_legacy_partial_safe',
      0, (): void => {
        const tables = emptyTables();
        tables['rdpcredentials'].push({
          id: 'credential-1',
          userid: 'owner-a',
          username: 'DOMAIN\\alice',
          password: 'rdp-secret'
        });
        tables['totpentries'].push({
          id: 'totp-1',
          userid: 'owner-a',
          issuer: 'Example',
          secret: 'totp-secret'
        });
        tables['vncrecord'].push({
          id: 'vnc-secret',
          userid: 'owner-a',
          recordtype: 'secret'
        });
        const backup = createLocalBackupDocument(
          tables, 100, '1.0.8', [], {}, 'owner-a');
        expect(backup.tables['rdpcredentials'][0]['username'])
          .assertEqual('DOMAIN\\alice');
        expect(backup.tables['rdpcredentials'][0]['password'] ===
          undefined).assertTrue();
        expect(backup.tables['totpentries'][0]['secret'] ===
          undefined).assertTrue();
        expect(backup.tables['vncrecord'].length).assertEqual(0);
        expect(adaptLocalBackupDocumentForRestore(
          backup, 'owner-b', false)).assertNull();

        const parsed = validateLocalBackupDocument(
          JSON.stringify(legacySevenTableDocument()));
        expect(parsed !== null).assertTrue();
        if (parsed === null) { return; }
        const preview = createLocalBackupRestorePreview(parsed);
        expect(preview.absentTables.indexOf('vncrecord') >= 0)
          .assertTrue();
        const plan = adaptLocalBackupDocumentForRestore(
          parsed, 'owner-a', true);
        expect(plan !== null).assertTrue();
        expect(plan?.presentTables.indexOf('vncrecord') < 0)
          .assertTrue();
        expect(plan?.tables['remotehosts'][0]['passward'] ===
          undefined).assertTrue();
      });

    it('crypto_restart_disable_and_reset_keep_remote_secret_paths_paused',
      0, (): void => {
        const scope = accountScopeToken('union-a', 4);
        expect(scope !== null).assertTrue();
        if (scope === null) { return; }
        const lease: AccountSessionLease =
          accountSessionLease(scope, 7);
        const initial: CryptoLifecycleDurableState =
          newCryptoLifecycleDurableState(
            lease, activeCrypto(), 1);
        const interrupted: CryptoLifecycleDurableState =
          cryptoLifecycleOperationStarted(
            initial, 'migrating', 'tx-migrate', 2);
        const recovered = recoverCryptoLifecycleDurableState(
          interrupted, lease, activeCrypto(), 3);
        expect(recovered.phase).assertEqual('active_locked');

        const ordinary: string[] = [
          'usersettings', 'remotehosts', 'sshkeys', 'vncrecord'
        ];
        expect(cloudSelectionAfterLocalCryptoTransition(
          ordinary, false).join(','))
          .assertEqual('usersettings,vncrecord');
        expect(cloudSelectionAfterLocalCryptoTransition(
          ordinary, true).join(','))
          .assertEqual('usersettings');
        expect(vncSelectionAfterLocalCryptoTransition(
          ['hosts', 'secrets', 'trust'], false).join(','))
          .assertEqual('hosts,trust');
        expect(vncSelectionAfterLocalCryptoTransition(
          ['hosts', 'secrets'], true).length)
          .assertEqual(0);
      });

    it('old_relay_cloud_container_is_all_or_nothing', 0, (): void => {
        expect(parseLegacyRelayJson(JSON.stringify([{
          id: 'relay-1',
          idServer: 'id.example.test',
          relayServer: 'relay.example.test',
          accounts: []
        }]))?.length).assertEqual(1);
        expect(parseLegacyRelayJson(
          '[{"id":"relay-1"},{"id":"relay-1"}]'))
          .assertNull();
      });
  });
}
