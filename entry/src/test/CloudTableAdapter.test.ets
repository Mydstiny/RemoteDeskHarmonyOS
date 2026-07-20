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

describe('CloudTableAdapter', (): void => {
  it('projects remote host password to the existing passward cloud field', (): void => {
    const row = projectLocalRow('remotehosts', {
      id: 'h1', password: 'secret', host: '192.0.2.1', rustdeskdirectport: '21117'
    });
    expect(row['passward']).assertEqual('secret');
    expect(row['rustdeskdirectport']).assertUndefined();
    expect(cloudTableColumns('remotehosts').indexOf('passward') >= 0).assertTrue();
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
      rustdeskproaccountid: 'account-1',
      password: 'must-not-leak',
      sshkeypassphrase: 'must-not-leak'
    });
    const encoded = encodeRemoteHostDisplayPayload(
      '{"width":1920,"height":1080,"multiMonitor":false,"monitorCount":1,"dynamicResolution":true,"colorDepth":32}',
      extension
    );
    const decoded = decodeRemoteHostDisplayPayload(encoded);
    expect(decoded.extension['rustdeskdirectport']).assertEqual('21117');
    expect(decoded.extension['rustdeskproaccountid']).assertEqual('account-1');
    expect(decoded.extension['password']).assertUndefined();
    expect(decoded.extension['sshkeypassphrase']).assertUndefined();
    expect(decoded.displayConfigJson.indexOf('"width":1920') >= 0).assertTrue();
  });

  it('keeps legacy displayconfig rows readable', (): void => {
    const legacy = '{"width":1366,"height":768,"multiMonitor":false,"monitorCount":1,"dynamicResolution":true,"colorDepth":32}';
    const decoded = decodeRemoteHostDisplayPayload(legacy);
    expect(decoded.displayConfigJson).assertEqual(legacy);
    expect(Object.keys(decoded.extension).length).assertEqual(0);
  });
});
