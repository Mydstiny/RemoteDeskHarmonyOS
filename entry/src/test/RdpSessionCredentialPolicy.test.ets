import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
  connectTimeRdpHostIdsFromRows,
  rdpSessionCredentialBindingIsCurrent,
  rdpSessionCredentialNativeAdmissionIsCurrent,
  rdpSessionCredentialRequiredForNewConnection,
  remoteHostMergeUsesConnectTimeRdpCredentials,
  sanitizeRemoteHostExtensionForRdpCredentialPolicy,
  sanitizeRemoteHostRowForRdpCredentialPolicy,
  shouldInvalidatePendingRdpSessionCredentialOnBackground,
  shouldInvalidatePendingRdpSessionCredentialRouteOnBackground
} from '../main/ets/services/RdpSessionCredentialPolicy';
import {
  decodeRemoteHostDisplayPayload,
  encodeRemoteHostDisplayPayload
} from '../main/ets/services/CloudTableAdapter';
import {
  fullPortableBackupData,
  redactPortableBackupData
} from '../main/ets/services/BackupManifestV3';

function connectTimeHost(): RemoteHost {
  const host = new RemoteHost();
  host.id = 'host-1';
  host.userId = 'owner-a';
  host.label = 'RDP';
  host.protocol = 'rdp';
  host.host = '192.0.2.40';
  host.port = 3389;
  host.rdpAuthMode = 'password';
  host.rdpCredentialStorageMode = 'connect_time';
  return host;
}

export default function rdpSessionCredentialPolicyTest(): void {
  describe('RdpSessionCredentialPolicy', (): void => {
    it('admits_only_an_exact_live_host_and_account_generation', 0, (): void => {
      const pending: RemoteHost = connectTimeHost();
      const live: RemoteHost = connectTimeHost();
      expect(rdpSessionCredentialBindingIsCurrent(
        pending, live, 'owner-a', 7, 'owner-a', 7)).assertTrue();

      expect(rdpSessionCredentialBindingIsCurrent(
        pending, live, 'owner-a', 7, 'owner-b', 8)).assertFalse();
      expect(rdpSessionCredentialBindingIsCurrent(
        pending, live, 'owner-a', 7, 'owner-a', 8)).assertFalse();

      live.host = '192.0.2.41';
      expect(rdpSessionCredentialBindingIsCurrent(
        pending, live, 'owner-a', 7, 'owner-a', 7)).assertFalse();
      live.host = pending.host;
      live.rdpCredentialStorageMode = 'saved';
      expect(rdpSessionCredentialBindingIsCurrent(
        pending, live, 'owner-a', 7, 'owner-a', 7)).assertFalse();
    });

    it('does_not_require_new_credentials_for_established_session_restore', 0,
      (): void => {
        const host: RemoteHost = connectTimeHost();
        expect(rdpSessionCredentialRequiredForNewConnection(host, false)).assertTrue();
        expect(rdpSessionCredentialRequiredForNewConnection(host, true)).assertFalse();
      });

    it('invalidates_backgrounded_preconnect_but_preserves_established_restore', 0,
      (): void => {
        const host: RemoteHost = connectTimeHost();
        expect(shouldInvalidatePendingRdpSessionCredentialOnBackground(
          host, true, false, false)).assertTrue();
        // The route is staged before aboutToAppear's first await, while the
        // page has not populated pendingHost yet.
        expect(shouldInvalidatePendingRdpSessionCredentialRouteOnBackground(
          true, true, false, false)).assertTrue();
        expect(shouldInvalidatePendingRdpSessionCredentialOnBackground(
          host, false, false, false)).assertFalse();
        expect(shouldInvalidatePendingRdpSessionCredentialOnBackground(
          host, true, true, false)).assertFalse();
        // A native id alone is not an established session: while the protocol
        // is connecting the same lifecycle decision still invalidates it.
        expect(shouldInvalidatePendingRdpSessionCredentialOnBackground(
          host, true, false, false)).assertTrue();
        // Registry restore has a native session id before the page toggles
        // connected=true. It must remain resumable without a new credential.
        expect(shouldInvalidatePendingRdpSessionCredentialOnBackground(
          host, true, false, true)).assertFalse();
      });

    it('rejects_native_admission_after_attempt_or_foreground_changes', 0,
      (): void => {
        expect(rdpSessionCredentialNativeAdmissionIsCurrent(
          7, 7, false, false)).assertTrue();
        expect(rdpSessionCredentialNativeAdmissionIsCurrent(
          7, 8, false, false)).assertFalse();
        expect(rdpSessionCredentialNativeAdmissionIsCurrent(
          7, 7, true, false)).assertFalse();
        expect(rdpSessionCredentialNativeAdmissionIsCurrent(
          7, 7, false, true)).assertFalse();
      });

    it('scrubs_malformed_connect_time_rows_before_decrypt_or_restore', 0, (): void => {
      const displayExtension: Record<string, string> = {};
      displayExtension['rdpcredentialstoragemode'] = 'connect_time';
      displayExtension['rdpcredentialid'] = 'extension-secret-ref';
      const displayconfig: string = encodeRemoteHostDisplayPayload(
        '{}', displayExtension);
      const unsafe: Record<string, string> = {};
      unsafe['id'] = 'host-1';
      unsafe['userid'] = 'owner-a';
      unsafe['protocol'] = 'rdp';
      unsafe['username'] = 'must-not-remain';
      unsafe['password'] = 'legacy-secret';
      unsafe['passward'] = 'ciphertext-secret';
      unsafe['rdpcredentialid'] = 'physical-secret-ref';
      unsafe['displayconfig'] = displayconfig;
      const safe = sanitizeRemoteHostRowForRdpCredentialPolicy(unsafe);
      expect(safe.connectTime).assertTrue();
      expect(safe.changed).assertTrue();
      expect(safe.row['username']).assertEqual('');
      expect(safe.row['password']).assertEqual('');
      expect(safe.row['passward']).assertEqual('');
      expect(safe.row['rdpcredentialid']).assertEqual('');
      expect(decodeRemoteHostDisplayPayload(safe.row['displayconfig'])
        .extension['rdpcredentialid']).assertEqual('');
    });

    it('scrubs_connect_time_credentials_from_full_and_redacted_backups', 0, (): void => {
      const displayExtension: Record<string, string> = {};
      displayExtension['rdpcredentialstoragemode'] = 'connect_time';
      displayExtension['rdpcredentialid'] = 'credential-ref';
      const displayconfig: string = encodeRemoteHostDisplayPayload(
        '{}', displayExtension);
      const unsafe: Record<string, string> = {};
      unsafe['id'] = 'host-2';
      unsafe['userid'] = 'owner-a';
      unsafe['protocol'] = 'rdp';
      unsafe['username'] = 'user';
      unsafe['password'] = 'legacy-secret';
      unsafe['passward'] = 'stored-secret';
      unsafe['rdpcredentialid'] = 'physical-ref';
      unsafe['displayconfig'] = displayconfig;
      const extensionPayload: Record<string, string> = {};
      extensionPayload['rdpcredentialstoragemode'] = 'connect_time';
      extensionPayload['username'] = 'extension-user';
      extensionPayload['password'] = 'extension-password';
      extensionPayload['passward'] = 'extension-ciphertext';
      extensionPayload['rdpcredentialid'] = 'local-ref';
      const extension: Record<string, string> = {};
      extension['id'] = 'remotehosts:host-2';
      extension['tablename'] = 'remotehosts';
      extension['recordid'] = 'host-2';
      extension['payload'] = JSON.stringify(extensionPayload);
      const tables: Record<string, Array<Record<string, string>>> = {};
      tables['remotehosts'] = [unsafe];
      const localTables: Record<string, Array<Record<string, string>>> = {};
      const full = fullPortableBackupData(
        tables, [extension], localTables);
      const redacted = redactPortableBackupData(
        tables, [extension], localTables);
      expect(full.tables['remotehosts'][0]['username']).assertEqual('');
      expect(full.tables['remotehosts'][0]['passward']).assertEqual('');
      expect(full.tables['remotehosts'][0]['rdpcredentialid']).assertEqual('');
      const fullExtension: Record<string, string> =
        JSON.parse(full.extensions[0]['payload']) as Record<string, string>;
      expect(fullExtension['username']).assertEqual('');
      expect(fullExtension['password']).assertEqual('');
      expect(fullExtension['passward']).assertEqual('');
      expect(fullExtension['rdpcredentialid']).assertEqual('');
      expect(redacted.tables['remotehosts'][0]['username']).assertEqual('');
      expect(redacted.tables['remotehosts'][0]['rdpcredentialid']).assertEqual('');
      const redactedExtension: Record<string, string> =
        JSON.parse(redacted.extensions[0]['payload']) as Record<string, string>;
      expect(redactedExtension['username']).assertEqual('');
      expect(redactedExtension['password']).assertEqual('');
      expect(redactedExtension['passward']).assertEqual('');
      expect(redactedExtension['rdpcredentialid']).assertEqual('');
    });

    it('scrubs_split_extension_reference_using_remote_host_policy', 0, (): void => {
      const displayExtension: Record<string, string> = {};
      displayExtension['rdpcredentialstoragemode'] = 'connect_time';
      const hostRow: Record<string, string> = {};
      hostRow['id'] = 'host-split';
      hostRow['protocol'] = 'rdp';
      hostRow['displayconfig'] = encodeRemoteHostDisplayPayload(
        '{}', displayExtension);
      const extensionPayload: Record<string, string> = {};
      extensionPayload['username'] = 'split-user';
      extensionPayload['password'] = 'split-password';
      extensionPayload['passward'] = 'split-ciphertext';
      extensionPayload['rdpcredentialid'] = 'split-secret-ref';
      const extension: Record<string, string> = {};
      extension['id'] = 'remotehosts:host-split';
      extension['tablename'] = 'remotehosts';
      extension['recordid'] = 'host-split';
      extension['payload'] = JSON.stringify(extensionPayload);
      const ids: string[] = connectTimeRdpHostIdsFromRows([hostRow]);
      expect(ids.length).assertEqual(1);
      const sanitized = sanitizeRemoteHostExtensionForRdpCredentialPolicy(
        extension, ids);
      expect(sanitized.connectTime).assertTrue();
      expect(sanitized.changed).assertTrue();
      const sanitizedPayload: Record<string, string> =
        JSON.parse(sanitized.row['payload']) as Record<string, string>;
      expect(sanitizedPayload['username']).assertEqual('');
      expect(sanitizedPayload['password']).assertEqual('');
      expect(sanitizedPayload['passward']).assertEqual('');
      expect(sanitizedPayload['rdpcredentialid']).assertEqual('');
      const tables: Record<string, Array<Record<string, string>>> = {};
      tables['remotehosts'] = [hostRow];
      const localTables: Record<string, Array<Record<string, string>>> = {};
      const full = fullPortableBackupData(tables, [extension], localTables);
      const redacted = redactPortableBackupData(tables, [extension], localTables);
      const fullPayload: Record<string, string> =
        JSON.parse(full.extensions[0]['payload']) as Record<string, string>;
      const redactedPayload: Record<string, string> =
        JSON.parse(redacted.extensions[0]['payload']) as Record<string, string>;
      expect(fullPayload['username']).assertEqual('');
      expect(fullPayload['password']).assertEqual('');
      expect(fullPayload['passward']).assertEqual('');
      expect(fullPayload['rdpcredentialid']).assertEqual('');
      expect(redactedPayload['username']).assertEqual('');
      expect(redactedPayload['password']).assertEqual('');
      expect(redactedPayload['passward']).assertEqual('');
      expect(redactedPayload['rdpcredentialid']).assertEqual('');
    });

    it('forces_secret_cleanup_when_partial_merge_changes_policy', 0, (): void => {
      const savedExtension: Record<string, string> = {};
      savedExtension['rdpcredentialstoragemode'] = 'saved';
      const incomingExtension: Record<string, string> = {};
      incomingExtension['rdpcredentialstoragemode'] = 'connect_time';
      const existing: Record<string, string> = {};
      existing['protocol'] = 'rdp';
      existing['username'] = 'stored-user';
      existing['passward'] = 'stored-secret';
      existing['rdpcredentialid'] = 'stored-ref';
      existing['displayconfig'] = encodeRemoteHostDisplayPayload(
        '{}', savedExtension);
      const incoming: Record<string, string> = {};
      incoming['displayconfig'] = encodeRemoteHostDisplayPayload(
        '{}', incomingExtension);
      expect(remoteHostMergeUsesConnectTimeRdpCredentials(
        existing, incoming)).assertTrue();
      const linkedIds: string[] = connectTimeRdpHostIdsFromRows([{
        'id': 'partial-host',
        'protocol': existing['protocol'],
        'displayconfig': incoming['displayconfig']
      }]);
      const staleLocalExtension: Record<string, string> = {};
      staleLocalExtension['id'] = 'remotehosts:partial-host';
      staleLocalExtension['tablename'] = 'remotehosts';
      staleLocalExtension['recordid'] = 'partial-host';
      staleLocalExtension['payload'] = JSON.stringify({
        'username': 'stale-local-user',
        'password': 'stale-local-password',
        'passward': 'stale-local-ciphertext',
        'rdpcredentialid': 'stale-local-ref'
      });
      const safeLocalExtension =
        sanitizeRemoteHostExtensionForRdpCredentialPolicy(
          staleLocalExtension, linkedIds);
      expect(safeLocalExtension.changed).assertTrue();
      const safeLocalPayload: Record<string, string> =
        JSON.parse(safeLocalExtension.row['payload']) as Record<string, string>;
      expect(safeLocalPayload['username']).assertEqual('');
      expect(safeLocalPayload['password']).assertEqual('');
      expect(safeLocalPayload['passward']).assertEqual('');
      expect(safeLocalPayload['rdpcredentialid']).assertEqual('');
    });

    it('replaces_malformed_extension_payload_for_a_known_connect_time_host', 0,
      (): void => {
        const malformed: Record<string, string> = {};
        malformed['id'] = 'remotehosts:malformed-host';
        malformed['tablename'] = 'remotehosts';
        malformed['recordid'] = 'malformed-host';
        malformed['payload'] = '{not-json';
        const sanitized = sanitizeRemoteHostExtensionForRdpCredentialPolicy(
          malformed, ['malformed-host']);
        expect(sanitized.connectTime).assertTrue();
        expect(sanitized.changed).assertTrue();
        expect(sanitized.row['payload']).assertEqual('{}');

        const displayExtension: Record<string, string> = {};
        displayExtension['rdpcredentialstoragemode'] = 'connect_time';
        const hostRow: Record<string, string> = {};
        hostRow['id'] = 'malformed-host';
        hostRow['protocol'] = 'rdp';
        hostRow['displayconfig'] = encodeRemoteHostDisplayPayload(
          '{}', displayExtension);
        const tables: Record<string, Array<Record<string, string>>> = {};
        tables['remotehosts'] = [hostRow];
        const localTables: Record<string, Array<Record<string, string>>> = {};
        const full = fullPortableBackupData(tables, [malformed], localTables);
        expect(full.extensions[0]['payload']).assertEqual('{}');
      });

    it('preserves_saved_mode_rows', 0, (): void => {
      const savedDisplayExtension: Record<string, string> = {};
      savedDisplayExtension['rdpcredentialstoragemode'] = 'saved';
      savedDisplayExtension['rdpcredentialid'] = 'saved-ref';
      const source: Record<string, string> = {};
      source['protocol'] = 'rdp';
      source['username'] = 'saved-user';
      source['passward'] = 'saved-secret';
      source['rdpcredentialid'] = 'saved-ref';
      source['displayconfig'] = encodeRemoteHostDisplayPayload(
        '{}', savedDisplayExtension);
      const result = sanitizeRemoteHostRowForRdpCredentialPolicy(source);
      expect(result.connectTime).assertFalse();
      expect(result.changed).assertFalse();
      expect(result.row['username']).assertEqual('saved-user');
      expect(result.row['passward']).assertEqual('saved-secret');
      expect(result.row['rdpcredentialid']).assertEqual('saved-ref');
      const savedExtension: Record<string, string> = {};
      savedExtension['tablename'] = 'remotehosts';
      savedExtension['payload'] = JSON.stringify(savedDisplayExtension);
      expect(sanitizeRemoteHostExtensionForRdpCredentialPolicy(
        savedExtension).changed).assertFalse();
    });
  });
}
