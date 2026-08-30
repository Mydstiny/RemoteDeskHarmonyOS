import {
  cloudTableColumns,
  projectLocalRow,
  normalizeCloudRow,
  encodeUserSettingsPayload,
  decodeUserSettingsPayload,
  projectRemoteHostCloudExtension,
  encodeRemoteHostDisplayPayload,
  decodeRemoteHostDisplayPayload
} from '../main/ets/services/CloudTableAdapter';
import {
  extractLegacyRemoteHostDeviceTrust,
  mergeRemoteHostDeviceTrust
} from '../main/ets/services/RemoteHostDeviceTrustPolicy';
import { TotpEntry } from '../main/ets/model/TotpEntry';

describe('CloudTableAdapter', (): void => {
  it('projects remote host password to the existing passward cloud field', (): void => {
    const row = projectLocalRow('remotehosts', {
      id: 'h1', password: 'secret', host: '192.0.2.1', rustdeskdirectport: '21117'
    });
    expect(row['passward']).assertEqual('secret');
    expect(row['rustdeskdirectport']).assertUndefined();
    expect(cloudTableColumns('remotehosts').indexOf('passward') >= 0).assertTrue();
    expect(cloudTableColumns('rdpcredentials').indexOf('userid') >= 0).assertTrue();
    expect(cloudTableColumns('rdpcredentials').indexOf('username') >= 0).assertTrue();
  });

  it('does_not_allow_a_legacy_password_shadow_to_override_passward', (): void => {
    const row = projectLocalRow('remotehosts', {
      id: 'h1', passward: 'canonical', password: 'legacy-shadow'
    });
    expect(row['passward']).assertEqual('canonical');
  });

  it('does_not_project_device_local_relay_control_plane_authorization', (): void => {
    const row = projectLocalRow('rustdeskrelays', {
      id: 'relay-1', relayserver: 'relay.example.com',
      controlplaneprofile: 'official_server_pro_token'
    });
    expect(row['controlplaneprofile']).assertUndefined();
    expect(cloudTableColumns('rustdeskrelays').indexOf('controlplaneprofile')).assertEqual(-1);
  });

  it('normalizes the cloud typo back to the local password field', (): void => {
    const row = normalizeCloudRow('remotehosts', { id: 'h1', passward: 'secret' });
    expect(row['password']).assertEqual('secret');
  });

  it('round trips usersettings through payload', (): void => {
    const payload = encodeUserSettingsPayload([
      { id: 'setting:a', key: 'a', value: 'true', updatedat: '1' },
      { id: 'setting:b', key: 'b', value: '"dark"', updatedat: '1' }
    ]);
    const rows = decodeUserSettingsPayload({ id: 'settings', payload, updatedat: '2' });
    expect(rows.length).assertEqual(2);
    expect(rows[0]['key']).assertEqual('a');
  });

  it('carries local-only host routing through the existing displayconfig field', (): void => {
    const extension = projectRemoteHostCloudExtension({
      rustdeskdirectenabled: '1',
      rustdeskdirecthost: '192.0.2.20',
      rustdeskdirectport: '21117',
      sshproxytype: 'socks5',
      rustdeskproaccountid: 'account-1',
      rustdesktargetdevice: 'phone',
      rustdeskadaptiveorientation: '1',
      rdpauthmode: 'restricted_admin',
      rdprestrictedadminsecretsource: 'ntlm_hash',
      rdpendpointmode: 'microsoft_rd_gateway',
      rdpgatewaytransport: 'no-websockets',
      rdpgatewayservername: 'gateway.example.test',
      rdpclienthostname: 'HARMONY-CLIENT',
      lanaddressmode: 'static',
      landiscoveryidentity: 'peer-stable-id',
      lanlastresolvedat: '1234',
      sshhostkeyfingerprintsha256: 'must-stay-local',
      sshhostkeyrouteidentity: 'must-stay-local-route',
      rdpcertificateallowhostmismatch: '1',
      rdprestrictedadminhash: '0123456789ABCDEF0123456789ABCDEF',
      password: 'must-not-leak',
      sshkeypassphrase: 'must-not-leak'
    });
    const encoded = encodeRemoteHostDisplayPayload(
      '{"width":1920,"height":1080,"multiMonitor":false,"monitorCount":1,"dynamicResolution":true,"colorDepth":32}',
      extension
    );
    const decoded = decodeRemoteHostDisplayPayload(encoded);
    expect(decoded.extension['rustdeskdirectport']).assertEqual('21117');
    expect(decoded.extension['sshproxytype']).assertEqual('socks5');
    expect(decoded.extension['rustdeskproaccountid']).assertUndefined();
    expect(decoded.extension['rustdesktargetdevice']).assertEqual('phone');
    expect(decoded.extension['rustdeskadaptiveorientation']).assertEqual('1');
    expect(decoded.extension['lanaddressmode']).assertEqual('static');
    expect(decoded.extension['landiscoveryidentity']).assertEqual('peer-stable-id');
    expect(decoded.extension['lanlastresolvedat']).assertEqual('1234');
    expect(decoded.extension['rustdesktotpentryid']).assertUndefined();
    expect(decoded.extension['rustdesktotpautosubmit']).assertUndefined();
    expect(decoded.extension['rdpauthmode']).assertEqual('restricted_admin');
    expect(decoded.extension['rdprestrictedadminsecretsource']).assertEqual('ntlm_hash');
    expect(decoded.extension['rdpendpointmode']).assertEqual('microsoft_rd_gateway');
    expect(decoded.extension['rdpgatewaytransport']).assertEqual('no-websockets');
    expect(decoded.extension['rdpgatewayservername']).assertEqual('gateway.example.test');
    expect(decoded.extension['rdpclienthostname']).assertEqual('HARMONY-CLIENT');
    expect(decoded.extension['rdprestrictedadminhash']).assertUndefined();
    expect(decoded.extension['password']).assertUndefined();
    expect(decoded.extension['sshkeypassphrase']).assertUndefined();
    expect(decoded.extension['sshhostkeyfingerprintsha256'])
      .assertUndefined();
    expect(decoded.extension['sshhostkeyrouteidentity']).assertUndefined();
    expect(decoded.extension['rdpcertificateallowhostmismatch'])
      .assertUndefined();
    expect(decoded.displayConfigJson.indexOf('"width":1920') >= 0).assertTrue();
  });

  it('keeps RDP Gateway route fields out of the fixed cloud table schema', (): void => {
    const columns: string[] = cloudTableColumns('remotehosts');
    expect(columns.indexOf('rdpendpointmode')).assertEqual(-1);
    expect(columns.indexOf('rdpgatewaytransport')).assertEqual(-1);
    expect(columns.indexOf('rdpgatewayservername')).assertEqual(-1);
    expect(columns.indexOf('rdpclienthostname')).assertEqual(-1);
  });

  it('extracts_legacy_device_trust_only_for_local_migration', (): void => {
    const legacy: string =
      '{"width":1280,"_remoteDeskExtensionV1":{' +
      '"sshhostkeyfingerprintsha256":"SHA256:old",' +
      '"sshhostkeytrustedat":"100",' +
      '"rdpcertificatenotbeforems":"1000",' +
      '"rdpgatewaycertificatenotafterms":"2000",' +
      '"rustdeskdirecthost":"192.0.2.4"}}';
    const extracted = extractLegacyRemoteHostDeviceTrust(legacy);
    expect(extracted['sshhostkeyfingerprintsha256'])
      .assertEqual('SHA256:old');
    expect(extracted['rdpcertificatenotbeforems']).assertEqual('1000');
    expect(extracted['rdpgatewaycertificatenotafterms']).assertEqual('2000');
    expect(extracted['rustdeskdirecthost'])
      .assertUndefined();
    const merged = mergeRemoteHostDeviceTrust(
      { sshhostkeyfingerprintsha256: 'physical' },
      extracted,
      { sshhostkeyfingerprintsha256: 'local' });
    expect(merged['sshhostkeyfingerprintsha256'])
      .assertEqual('local');
  });

  it('keeps legacy displayconfig rows readable', (): void => {
    const legacy = '{"width":1366,"height":768,"multiMonitor":false,"monitorCount":1,"dynamicResolution":true,"colorDepth":32}';
    const decoded = decodeRemoteHostDisplayPayload(legacy);
    expect(decoded.displayConfigJson).assertEqual(legacy);
    expect(Object.keys(decoded.extension).length).assertEqual(0);
  });

  it('keeps_totpentries_schema_exact_and_brand_fields_local_only', (): void => {
    const expected: string[] = [
      'id', 'userid', 'issuer', 'account', 'displayname', 'secret', 'algorithm', 'digits',
      'period', 'iconurl', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat'
    ];
    const actual: string[] = cloudTableColumns('totpentries');
    expect(actual.length).assertEqual(expected.length);
    for (let index = 0; index < expected.length; index++) {
      expect(actual[index]).assertEqual(expected[index]);
    }
    expect(actual.indexOf('brandid')).assertEqual(-1);
    expect(actual.indexOf('avatarmode')).assertEqual(-1);
    const entry: TotpEntry = new TotpEntry();
    const json: Record<string, Object> = entry.toJSON() as Record<string, Object>;
    expect(json['brandId']).assertUndefined();
    expect(json['avatarMode']).assertUndefined();
    expect(json['brandid']).assertUndefined();
    expect(json['avatarmode']).assertUndefined();
  });
});
