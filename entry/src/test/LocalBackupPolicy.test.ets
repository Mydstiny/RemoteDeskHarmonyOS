import { describe, it, expect } from '@ohos/hypium';
import { CLOUD_SYNC_TABLES } from '../main/ets/services/CloudSyncPolicy';
import {
  adaptLocalBackupDocumentForRestore,
  LocalBackupDocument,
  createLocalBackupDocument,
  createLocalBackupRestorePreview,
  localBackupExtensionOwnerTable,
  localBackupLocalTableNames,
  localBackupCanonicalPayload,
  localBackupSha256,
  LOCAL_BACKUP_PORTABLE_TABLES,
  portableBackupScopeLeaseAllowed,
  validateCloudDownloadRollbackSnapshot,
  validateLocalBackupDocument,
  validateLocalBackupSnapshot
} from '../main/ets/services/LocalBackupPolicy';
import {
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_TABLE
} from '../main/ets/model/MoonlightRecord';
import {
  vncPayloadHashSha256
} from '../main/ets/services/VncRecordPolicy';
import {
  MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME
} from '../main/ets/services/MoonlightSessionRecoveryStore';
import {
  accountScopeToken,
  accountSessionLease,
  deviceLocalScopeToken
} from '../main/ets/services/AccountScopePolicy';

function emptyTables(): Record<string, Array<Record<string, string>>> {
  const tables: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) { tables[CLOUD_SYNC_TABLES[i]] = []; }
  return tables;
}

function signedText(document: LocalBackupDocument): string {
  document.sha256 = localBackupSha256(localBackupCanonicalPayload(
    document.createdAt, document.appVersion, document.tables,
    document.extensions, document.version, document.localTables,
    document.manifest));
  return JSON.stringify(document);
}

function legacySevenTables(): Record<string, Array<Record<string, string>>> {
  const current: Record<string, Array<Record<string, string>>> =
    emptyTables();
  const legacy: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    if (CLOUD_SYNC_TABLES[i] !== 'vncrecordv2') {
      legacy[CLOUD_SYNC_TABLES[i]] = current[CLOUD_SYNC_TABLES[i]];
    }
  }
  return legacy;
}

function legacyDocument(
  version: number,
  tables: Record<string, Array<Record<string, string>>>,
  extensions?: Array<Record<string, string>>
): LocalBackupDocument {
  const inventory: string[] = Object.keys(tables);
  const payload: string = localBackupCanonicalPayload(
    100, '1.0.5', tables, extensions, version,
    undefined, undefined, inventory);
  return {
    format: 'remotedesktop-local-backup',
    version,
    createdAt: 100,
    appVersion: '1.0.5',
    tables,
    extensions,
    sha256: localBackupSha256(payload)
  };
}

function portableVncHostRow(
  owner: string, id: string
): Record<string, string> {
  const payload: string =
    '{"clipboardEnabled":false,"displayOverrideEnabled":false,' +
    '"gatewayId":"","host":"192.0.2.10","label":"Test host",' +
    '"locked":false,"lockType":0,"port":5900,' +
    '"rememberPassword":false,"repeaterMode":"mode12",' +
    '"scalingMode":"fit","securityPolicy":"secure_only",' +
    '"tls":true,"transport":"direct_tcp","username":"",' +
    '"viewOnly":true}';
  return {
    id, userid: owner, recordtype: 'host',
    ownerid: owner, ownertype: 'account', secretkind: '',
    payload, ciphertext: '', envelopeversion: '0',
    cryptoversion: '0', keyversion: '0', aadversion: '0',
    payloadhashsha256: vncPayloadHashSha256(payload),
    syncversion: '1', schemaversion: '1', resetepoch: '1',
    createdat: '1', updatedat: '2', deletedat: '0'
  };
}

export default function localBackupPolicyTest(): void {
  describe('LocalBackupPolicy', (): void => {
    it('hashes_empty_text_with_the_standard_digest_on_compatibility_platforms',
      0, (): void => {
        expect(localBackupSha256('')).assertEqual(
          'e3b0c44298fc1c149afbf4c8996fb924' +
          '27ae41e4649b934ca495991b7852b855');
      });

    it('allows_backup_for_active_local_stores_without_requiring_cloud_binding',
      0, (): void => {
        const local = deviceLocalScopeToken(1);
        expect(portableBackupScopeLeaseAllowed(
          local, accountSessionLease(local, 1))).assertTrue();

        const account = accountScopeToken(
          'union-a', 2, 'ready', 'validating');
        expect(account === null).assertFalse();
        if (account === null) { return; }
        expect(portableBackupScopeLeaseAllowed(
          account, accountSessionLease(account, 2))).assertTrue();

        const switching = deviceLocalScopeToken(3);
        switching.sessionState = 'switching';
        expect(portableBackupScopeLeaseAllowed(
          switching, accountSessionLease(switching, 3))).assertFalse();
        expect(portableBackupScopeLeaseAllowed(local, null)).assertFalse();
        expect(portableBackupScopeLeaseAllowed(
          local, accountSessionLease(deviceLocalScopeToken(4), 4)))
          .assertFalse();
        const wrongStoreLease = accountSessionLease(local, 5);
        wrongStoreLease.storeIdentity = 'other.db';
        expect(portableBackupScopeLeaseAllowed(
          local, wrongStoreLease)).assertFalse();
      });

    it('never_exports_the_device_local_moonlight_recovery_marker', 0,
      (): void => {
        expect(LOCAL_BACKUP_PORTABLE_TABLES.indexOf(
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME)).assertEqual(-1);
        expect(localBackupLocalTableNames().indexOf(
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME)).assertEqual(-1);
        const document: LocalBackupDocument = createLocalBackupDocument(
          emptyTables(), 100, '1.0.10', [], {}, 'owner-test');
        expect(JSON.stringify(document).indexOf(
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME)).assertEqual(-1);
      });

    it('maps_restricted_admin_extensions_to_remote_host_owners', 0, (): void => {
      expect(localBackupExtensionOwnerTable('rdprestrictedadminsecrets'))
        .assertEqual('remotehosts');
      expect(localBackupExtensionOwnerTable('rdpcredentials'))
        .assertEqual('rdpcredentials');
    });

    it('accepts_an_empty_v3_redacted_backup', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      expect(validateLocalBackupDocument(JSON.stringify(document)) !== null).assertTrue();
      expect(document.tables['cryptoparams'] === undefined).assertTrue();
    });

    it('rejects_unknown_columns_inside_a_row', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['sshkeys'].push({ id: 'key-1', unexpected: 'no' });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('rejects_device_local_relay_control_plane_authorization', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['rustdeskrelays'].push({
        id: 'relay-1', controlplaneprofile: 'official_server_pro_token'
      });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('rejects_non_integer_text_for_integer_columns', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['remotehosts'].push({ id: 'host-1', port: 'invalid' });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('accepts_rows_missing_columns_added_by_later_versions', 0, (): void => {
      const tables = emptyTables();
      tables['rdpcredentials'].push({
        id: 'credential-1', userid: 'owner-test'
      });
      const document = createLocalBackupDocument(
        tables, 100, '1.0.5', [], {}, 'owner-test');
      expect(validateLocalBackupDocument(
        JSON.stringify(document)) !== null).assertTrue();
    });

    it('full_mode_keeps_secrets_private_keys_totp_and_device_trust', 0,
      (): void => {
        const tables = emptyTables();
        tables['cryptoparams'].push({
          id: 'salt', key: 'crypto_salt', value: 'secret'
        });
        tables['remotehosts'].push({
          id: 'host-1', userid: 'owner-test', label: 'host',
          passward: 'password',
          sshhostkeyfingerprintsha256: 'fingerprint',
          displayconfig: '{"width":1920,"_remoteDeskExtensionV1":{' +
            '"sshhostkeyfingerprintsha256":"nested-fingerprint",' +
            '"password":"nested-password","rustdeskdirectport":"21117",' +
            '"rustdeskTotpEntryId":"device-entry",' +
            '"rustdeskTotpAutoSubmit":"1","rustdeskTotpDeviceId":"device-a"}}'
        });
        tables['sshkeys'].push({
          id: 'key-1', userid: 'owner-test',
          privatekey: 'private', publickey: 'public'
        });
        tables['totpentries'].push({
          id: 'totp-1', userid: 'owner-test',
          secret: 'totp-secret'
        });
        tables['vncrecordv2'].push({
          id: 'vnc-trust-1', userid: 'owner-test', recordtype: 'trust', deletedat: '0'
        });
        const document = createLocalBackupDocument(
          tables, 100, '1.0.10', [{
            id: 'remotehosts:host-1', tablename: 'remotehosts',
            recordid: 'host-1',
            payload: '{"sshkeypassphrase":"passphrase",' +
              '"sshproxypassword":"proxy-password",' +
              '"sshproxykeypassphrase":"proxy-passphrase",' +
              '"sshhostkeyfingerprintsha256":"trust",' +
              '"sshjumphostkeyalgorithm":"ssh-ed25519",' +
              '"rustdeskdirectport":"21117",' +
              '"rustdesktotpentryid":"device-entry",' +
              '"rustdesktotpautosubmit":"1"}',
            updatedat: '100'
          }], {}, 'owner-test', 3, true, 'full');
        expect(document.manifest?.crypto.mode).assertEqual('full');
        expect(document.manifest?.crypto.verifierIncluded).assertTrue();
        expect(document.manifest?.trust.deviceTrustIncluded).assertTrue();
        expect(document.manifest?.trust.vncTrustCandidatesIncluded).assertTrue();
        expect(document.manifest?.trust.vncLocalConfirmationMarkerIncluded).assertFalse();
        const preview = createLocalBackupRestorePreview(document);
        expect(preview.vncTrustCandidatesIncluded).assertTrue();
        expect(preview.vncLocalConfirmationMarkerIncluded).assertFalse();
        const restorePlan = adaptLocalBackupDocumentForRestore(
          document, 'owner-test', false);
        expect(restorePlan !== null).assertTrue();
        expect((restorePlan?.tables['vncrecordv2'] || []).length).assertEqual(1);
        expect((restorePlan?.localTables['vnclocalrecords'] || []).length).assertEqual(0);
        expect(document.manifest?.trust.plaintextConsentIncluded)
          .assertFalse();
        expect(document.tables['cryptoparams'] !== undefined)
          .assertTrue();
        expect(document.tables['remotehosts'][0]['passward'])
          .assertEqual('password');
        expect(document.tables['remotehosts'][0]
          ['sshhostkeyfingerprintsha256']).assertEqual('fingerprint');
        expect(document.tables['sshkeys'][0]['privatekey'])
          .assertEqual('private');
        expect(document.tables['totpentries'][0]['secret'])
          .assertEqual('totp-secret');
        expect(JSON.stringify(document).indexOf('device-entry')).assertEqual(-1);
        expect(JSON.stringify(document).indexOf('rustdesktotpautosubmit')).assertEqual(-1);
        expect(JSON.stringify(document).indexOf('rustdeskTotpDeviceId')).assertEqual(-1);
        expect(document.extensions?.[0]['payload'])
          .assertEqual('{"sshkeypassphrase":"passphrase",' +
            '"sshproxypassword":"proxy-password",' +
            '"sshproxykeypassphrase":"proxy-passphrase",' +
            '"sshhostkeyfingerprintsha256":"trust",' +
            '"sshjumphostkeyalgorithm":"ssh-ed25519",' +
            '"rustdeskdirectport":"21117"}');
        expect(validateLocalBackupDocument(
          JSON.stringify(document)) !== null).assertTrue();
        // An unencrypted source explicitly consents to plaintext secrets.
        const plain = createLocalBackupDocument(
          tables, 100, '1.0.10', [], {}, 'owner-test', 3, false, 'full');
        expect(plain.manifest?.crypto.verifierIncluded).assertFalse();
        expect(plain.manifest?.trust.plaintextConsentIncluded).assertTrue();
        expect(validateLocalBackupDocument(
          JSON.stringify(plain)) !== null).assertTrue();
      });

    it('accepts_legacy_distributed_delete_flag_but_strips_it_before_restore', 0, (): void => {
      const tables = legacySevenTables();
      tables['remotehosts'].push({
        id: 'host-1', port: '3389', '#_deleted_flag': '0'
      });
      const document = legacyDocument(1, tables);
      const parsed = validateLocalBackupDocument(
        JSON.stringify(document));
      expect(parsed !== null).assertTrue();
      expect(parsed?.tables['remotehosts'][0]['#_deleted_flag'] === undefined).assertTrue();
    });

    it('round_trips_safe_local_extension_rows_in_v3', 0, (): void => {
      const tables = emptyTables();
      tables['remotehosts'].push({
        id: 'h1', userid: 'owner-test'
      });
      const document = createLocalBackupDocument(tables, 100, '1.0.7', [{
        id: 'remotehosts:h1', tablename: 'remotehosts', recordid: 'h1',
        payload: '{"rustdeskdirectport":"21117","rustdesktargetdevice":"phone",' +
          '"rustdeskadaptiveorientation":"1","rdpendpointmode":"microsoft_rd_gateway",' +
          '"rdpgatewaytransport":"no-websockets",' +
          '"rdpgatewayservername":"gateway.example.test",' +
          '"rdpclienthostname":"HARMONY-CLIENT",' +
          '"sshproxytype":"ssh_jump","sshproxyauthmethod":"publickey",' +
          '"sshproxykeyid":"jump-key",' +
          '"sshjumphostkeyalgorithm":"ssh-ed25519",' +
          '"sshjumphostkeyfingerprintsha256":"SHA256:jump",' +
          '"sshjumphostkeyrawbase64":"AAAA",' +
          '"sshjumphostkeytrustedat":"99","sshjumphostkeytrustmode":"1",' +
          '"localpersonalizationversion":"1",' +
          '"localdisplayconfig":"{\\"width\\":1280,\\"height\\":720}",' +
          '"locallastconnected":"101","locallasthealth":"3",' +
          '"locallastlatency":"72",' +
          '"localrustdeskadaptiveorientation":"1",' +
          '"localrustdeskdesktopflipmode":"image_only",' +
          '"localrustdeskprolastseenat":"202",' +
          '"localrustdeskprosyncerror":"not_seen"}', updatedat: '100'
      }], {}, 'owner-test');
      const parsed = validateLocalBackupDocument(JSON.stringify(document));
      expect(parsed !== null).assertTrue();
      expect(parsed?.extensions?.length).assertEqual(1);
      expect(parsed?.extensions?.[0]['payload'].indexOf('rdpendpointmode') >= 0).assertTrue();
      expect(parsed?.extensions?.[0]['payload'].indexOf('rdpclienthostname') >= 0).assertTrue();
      expect(parsed?.extensions?.[0]['payload'].indexOf('sshproxytype') >= 0).assertTrue();
      expect(parsed?.extensions?.[0]['payload'].indexOf('sshjumphostkeyalgorithm') >= 0).assertTrue();
      expect(parsed?.extensions?.[0]['payload'].indexOf('localdisplayconfig') >= 0).assertTrue();
      expect(parsed?.extensions?.[0]['payload'].indexOf(
        'localrustdeskdesktopflipmode') >= 0).assertTrue();
    });

    it('rejects_duplicate_primary_keys', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.7');
      document.tables['remotehosts'].push({ id: 'host-1' }, { id: 'host-1' });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('rejects_orphan_extension_rows', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.7', [{
        id: 'remotehosts:missing', tablename: 'remotehosts', recordid: 'missing',
        payload: '{"rustdeskdirectport":"21117"}', updatedat: '100'
      }]);
      expect(validateLocalBackupDocument(JSON.stringify(document)) === null).assertTrue();
    });

    it('rejects_unknown_extension_payload_fields', 0, (): void => {
      const tables = emptyTables();
      tables['remotehosts'].push({ id: 'host-1' });
      const document = createLocalBackupDocument(tables, 100, '1.0.7', [{
        id: 'remotehosts:host-1', tablename: 'remotehosts', recordid: 'host-1',
        payload: '{"unknownsecret":"value"}', updatedat: '100'
      }]);
      expect(validateLocalBackupDocument(JSON.stringify(document)) === null).assertTrue();
    });

    it('accepts_a_legacy_seven_table_backup_without_clearing_vnc', 0, (): void => {
      const tables = legacySevenTables();
      tables['remotehosts'].push({
        id: 'host-1', userid: 'legacy-user', label: 'Legacy',
        passward: 'plaintext-secret'
      });
      const document = legacyDocument(1, tables);
      const parsed = validateLocalBackupDocument(
        JSON.stringify(document));
      expect(parsed !== null).assertTrue();
      const preview = createLocalBackupRestorePreview(
        parsed as LocalBackupDocument);
      expect(preview.absentTables.indexOf('vncrecordv2') >= 0)
        .assertTrue();
      const plan = adaptLocalBackupDocumentForRestore(
        parsed as LocalBackupDocument, 'owner-target', true);
      expect(plan !== null).assertTrue();
      expect(plan?.presentTables.indexOf('vncrecordv2') < 0)
        .assertTrue();
      expect(plan?.tables['remotehosts'][0]['userid'])
        .assertEqual('owner-target');
      expect(plan?.tables['remotehosts'][0]['passward'] === undefined)
        .assertTrue();
    });

    it('redacts_secrets_and_totp_but_retains_device_trust', 0, (): void => {
      const tables = emptyTables();
      tables['cryptoparams'].push({
        id: 'salt', key: 'crypto_salt', value: 'secret'
      });
      tables['remotehosts'].push({
        id: 'host-1', userid: 'owner-test', label: 'host',
        passward: 'password',
        sshhostkeyfingerprintsha256: 'fingerprint',
        displayconfig: '{"width":1920,"height":1080,' +
          '"_remoteDeskExtensionV1":{' +
          '"sshhostkeyfingerprintsha256":"nested-fingerprint",' +
          '"password":"nested-password",' +
          '"futureSecret":"unknown",' +
          '"rustdeskdirectport":"21117",' +
          '"rdpendpointmode":"microsoft_rd_gateway",' +
          '"rdpgatewaytransport":"no-websockets",' +
          '"rdpgatewayservername":"gateway.example.test"}}'
      });
      tables['sshkeys'].push({
        id: 'key-1', userid: 'owner-test',
        privatekey: 'private', publickey: 'public'
      });
      tables['totpentries'].push({
        id: 'totp-1', userid: 'owner-test',
        secret: 'totp-secret'
      });
      tables['usersettings'].push({
        id: 'setting:accentColor', userid: 'owner-test',
        payload: '{"accentColor":"#336699",' +
          '"accessToken":"must-not-export"}',
        schemaversion: '1', updatedat: '100'
      }, {
        id: 'setting:loginToken', userid: 'owner-test',
        key: 'loginToken', value: '"must-not-export"',
        schemaversion: '1', updatedat: '100'
      });
      const document = createLocalBackupDocument(
        tables, 100, '1.0.8', [{
          id: 'remotehosts:host-1', tablename: 'remotehosts',
          recordid: 'host-1',
          payload: '{"sshkeypassphrase":"passphrase",' +
            '"sshhostkeyfingerprintsha256":"trust",' +
            '"rustdeskdirectport":"21117"}',
          updatedat: '100'
        }], {}, 'owner-test');
      expect(document.tables['cryptoparams'] === undefined)
        .assertTrue();
      expect(document.tables['remotehosts'][0]['passward'] ===
        undefined).assertTrue();
      // Device trust (public SSH host key / RDP certificate material) is not
      // secret and is intentionally retained in every backup mode.
      expect(document.tables['remotehosts'][0]
        ['sshhostkeyfingerprintsha256']).assertEqual('fingerprint');
      expect(document.tables['remotehosts'][0]['displayconfig']
        .indexOf('nested-fingerprint') >= 0).assertTrue();
      expect(document.tables['remotehosts'][0]['displayconfig']
        .indexOf('nested-password') < 0).assertTrue();
      expect(document.tables['remotehosts'][0]['displayconfig']
        .indexOf('futureSecret') < 0).assertTrue();
      expect(document.tables['remotehosts'][0]['displayconfig']
        .indexOf('rustdeskdirectport') >= 0).assertTrue();
      expect(document.tables['remotehosts'][0]['displayconfig']
        .indexOf('rdpendpointmode') >= 0).assertTrue();
      expect(document.extensions?.[0]['payload'])
        .assertEqual('{"sshhostkeyfingerprintsha256":"trust",' +
          '"rustdeskdirectport":"21117"}');
      expect(JSON.stringify(document).indexOf('rustdesktotpentryid'))
        .assertEqual(-1);
      expect(JSON.stringify(document).indexOf('rustdesktotpautosubmit'))
        .assertEqual(-1);
      expect(document.tables['sshkeys'][0]['privatekey'] ===
        undefined).assertTrue();
      expect(document.tables['totpentries'][0]['secret'] ===
        undefined).assertTrue();
      expect(document.tables['usersettings'].length)
        .assertEqual(1);
      expect(document.tables['usersettings'][0]['payload'])
        .assertEqual('{"accentColor":"#336699"}');
      expect(validateLocalBackupDocument(
        JSON.stringify(document)) !== null).assertTrue();
    });

    it('rejects_v3_restore_into_a_different_account', 0, (): void => {
      const document = createLocalBackupDocument(
        emptyTables(), 100, '1.0.8', [], {}, 'owner-a');
      expect(adaptLocalBackupDocumentForRestore(
        document, 'owner-b', false) === null).assertTrue();
    });

    it('restores_device_local_v3_only_into_the_device_local_scope',
      0, (): void => {
        const document = createLocalBackupDocument(
          emptyTables(), 100, '1.0.10', [], {}, 'device-local');
        const localPlan = adaptLocalBackupDocumentForRestore(
          document, 'device-local', false);
        expect(localPlan !== null).assertTrue();
        expect(localPlan?.sourceAccountScope).assertEqual('device-local');
        expect(localPlan?.targetAccountScope).assertEqual('device-local');
        expect(adaptLocalBackupDocumentForRestore(
          document, 'owner-account', false) === null).assertTrue();
      });

    it('preserves_absent_and_empty_as_distinct_v3_sections', 0, (): void => {
      const document = createLocalBackupDocument(
        emptyTables(), 100, '1.0.8', [], {}, 'owner-a');
      const sections = document.manifest?.sections || [];
      let cryptoState: string = '';
      let hostState: string = '';
      let localVncState: string = '';
      for (let i = 0; i < sections.length; i++) {
        if (sections[i].id === 'cloud:cryptoparams') {
          cryptoState = sections[i].state;
        }
        if (sections[i].id === 'cloud:remotehosts') {
          hostState = sections[i].state;
        }
        if (sections[i].id === 'local:vnclocalrecords') {
          localVncState = sections[i].state;
        }
      }
      expect(cryptoState).assertEqual('absent');
      expect(hostState).assertEqual('empty');
      expect(localVncState).assertEqual('absent');
    });

    it('rejects_manifest_count_tampering_even_with_a_new_outer_hash', 0, (): void => {
      const document = createLocalBackupDocument(
        emptyTables(), 100, '1.0.8', [], {}, 'owner-a');
      const sections = document.manifest?.sections || [];
      for (let i = 0; i < sections.length; i++) {
        if (sections[i].id === 'cloud:remotehosts') {
          sections[i].rowCount = 1;
        }
      }
      expect(validateLocalBackupDocument(
        signedText(document)) === null).assertTrue();
    });

    it('accepts_v2_without_vnc_extensions_or_local_tables_as_partial_input', 0, (): void => {
      const document = legacyDocument(2, legacySevenTables());
      const parsed = validateLocalBackupDocument(
        JSON.stringify(document));
      expect(parsed !== null).assertTrue();
      const plan = adaptLocalBackupDocumentForRestore(
        parsed as LocalBackupDocument, 'owner-target', true);
      expect(plan !== null).assertTrue();
      expect(plan?.presentTables.indexOf('vncrecordv2') < 0)
        .assertTrue();
      expect(plan?.presentLocalTables.length).assertEqual(0);
      expect(plan?.extensionsPresent).assertFalse();
    });

    it('keeps_legacy_and_current_cloud_download_before_images_upgrade_safe',
      0, (): void => {
        const coreTables:
          Record<string, Array<Record<string, string>>> =
          emptyTables();
        const currentTables:
          Record<string, Array<Record<string, string>>> = {};
        for (let i = 0;
          i < LOCAL_BACKUP_PORTABLE_TABLES.length; i++) {
          currentTables[LOCAL_BACKUP_PORTABLE_TABLES[i]] = [];
        }
        const legacyLocal:
          Record<string, Array<Record<string, string>>> = {
          'vnclocalrecords': []
        };
        const currentLocal:
          Record<string, Array<Record<string, string>>> = {
          'vnclocalrecords': []
        };
        currentLocal[MOONLIGHT_LOCAL_TABLE] = [];

        expect(validateCloudDownloadRollbackSnapshot(
          coreTables, [], legacyLocal)).assertTrue();
        expect(validateCloudDownloadRollbackSnapshot(
          coreTables, [], currentLocal)).assertTrue();
        expect(validateCloudDownloadRollbackSnapshot(
          currentTables, [], currentLocal)).assertTrue();
        // Portable full-replacement input remains the original eight-table
        // contract; the Moonlight physical projection is restored only via
        // its local overlay adapter.
        expect(validateLocalBackupSnapshot(
          coreTables, [], legacyLocal)).assertTrue();
        expect(validateLocalBackupSnapshot(
          currentTables, [], currentLocal)).assertFalse();

        const partialTables:
          Record<string, Array<Record<string, string>>> = {};
        for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
          if (CLOUD_SYNC_TABLES[i] !== 'sshkeys') {
            partialTables[CLOUD_SYNC_TABLES[i]] = [];
          }
        }
        expect(validateCloudDownloadRollbackSnapshot(
          partialTables, [], legacyLocal)).assertFalse();
        const invalidLocal:
          Record<string, Array<Record<string, string>>> = {};
        invalidLocal[MOONLIGHT_LOCAL_TABLE] = [];
        expect(validateCloudDownloadRollbackSnapshot(
          currentTables, [], invalidLocal)).assertFalse();
        expect(Object.keys(currentTables).indexOf(
          MOONLIGHT_CLOUD_TABLE) >= 0).assertTrue();
      });

    it('accepts_a_pre_moonlight_v3_backup_without_new_manifest_sections',
      0, (): void => {
        const document: LocalBackupDocument = createLocalBackupDocument(
          emptyTables(), 100, '1.0.10', [], {}, 'owner-a');
        const manifest = document.manifest!;
        manifest.moonlight = undefined;
        manifest.sections = manifest.sections.filter((section): boolean =>
          section.id !== 'cloud:' + MOONLIGHT_CLOUD_TABLE &&
          section.id !== 'local:' + MOONLIGHT_LOCAL_TABLE);
        if (document.localTables !== undefined) {
          const legacyLocal:
            Record<string, Array<Record<string, string>>> = {};
          if (document.localTables['vnclocalrecords'] !== undefined) {
            legacyLocal['vnclocalrecords'] =
              document.localTables['vnclocalrecords'];
          }
          document.localTables = legacyLocal;
        }
        document.sha256 = localBackupSha256(localBackupCanonicalPayload(
          document.createdAt, document.appVersion, document.tables,
          document.extensions, document.version, document.localTables,
          document.manifest, CLOUD_SYNC_TABLES));

        const parsed: LocalBackupDocument | null =
          validateLocalBackupDocument(JSON.stringify(document));
        expect(parsed !== null).assertTrue();
        const plan = adaptLocalBackupDocumentForRestore(
          parsed!, 'owner-a', false);
        expect(plan !== null).assertTrue();
        expect(plan?.presentTables.indexOf(
          MOONLIGHT_CLOUD_TABLE)).assertEqual(-1);
        expect(plan?.presentLocalTables.indexOf(
          MOONLIGHT_LOCAL_TABLE)).assertEqual(-1);
      });

    it('excludes_vnc_secret_trust_and_tombstone_rows_from_v3', 0, (): void => {
      const owner: string = 'owner-a';
      const tables = emptyTables();
      const host: Record<string, string> =
        portableVncHostRow(owner, 'vnc-host');
      const secret: Record<string, string> = {
        id: 'vnc-secret', userid: owner, recordtype: 'secret'
      };
      const trust: Record<string, string> = {
        id: 'vnc-trust', userid: owner, recordtype: 'trust'
      };
      const tombstone: Record<string, string> =
        portableVncHostRow(owner, 'vnc-deleted');
      tombstone['deletedat'] = '9';
      tables['vncrecordv2'].push(
        host, secret, trust, tombstone);
      const document = createLocalBackupDocument(
        tables, 100, '1.0.8', [], {
          vnclocalrecords: [secret, trust]
        }, owner);
      expect(document.manifest?.trust.vncTrustCandidatesIncluded).assertFalse();
      expect(document.manifest?.trust.vncLocalConfirmationMarkerIncluded).assertFalse();
      expect(document.tables['vncrecordv2'].length).assertEqual(1);
      expect(document.tables['vncrecordv2'][0]['id'])
        .assertEqual('vnc-host');
      expect(document.localTables?.['vnclocalrecords'].length)
        .assertEqual(0);
      expect(validateLocalBackupDocument(
        JSON.stringify(document)) !== null).assertTrue();
    });
  });
}
