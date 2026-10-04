import { describe, expect, it } from '@ohos/hypium';
import {
  cryptoResetExtensionPayload,
  cryptoResetJournalTables,
  cryptoResetUploadBlockTables,
  cryptoResetKeepsVncRecord,
  cryptoResetRelayAccountsJson,
  cryptoResetSecretColumns,
  cryptoResetSecretTables
} from '../main/ets/services/CryptoResetDataPolicy';

export default function cryptoResetDataPolicyTest(): void {
  describe('CryptoResetDataPolicy', (): void => {
    it('clears_only_secret_columns_of_the_sensitive_tables', 0, (): void => {
      expect(cryptoResetSecretTables().length).assertEqual(5);
      expect(cryptoResetSecretColumns('remotehosts').indexOf('passward') >= 0).assertTrue();
      expect(cryptoResetSecretColumns('remotehosts').indexOf('host') < 0).assertTrue();
      expect(cryptoResetSecretColumns('remotehosts').indexOf('username') < 0).assertTrue();
      expect(cryptoResetSecretColumns('sshkeys').indexOf('publickey') < 0).assertTrue();
      expect(cryptoResetSecretColumns('totpentries').indexOf('secret') >= 0).assertTrue();
      expect(cryptoResetSecretColumns('usersettings').length).assertEqual(0);
      expect(cryptoResetSecretColumns('constructor').length).assertEqual(0);
    });

    it('keeps_relay_accounts_but_clears_their_passwords', 0, (): void => {
      const cleared: string = cryptoResetRelayAccountsJson(
        '[{"username":"alice","password":"cipher","default":true}]');
      const accounts: Array<Record<string, Object>> =
        JSON.parse(cleared) as Array<Record<string, Object>>;
      expect(accounts.length).assertEqual(1);
      expect(accounts[0]['username'] as string).assertEqual('alice');
      expect(accounts[0]['password'] as string).assertEqual('');
      expect(cryptoResetRelayAccountsJson('not json')).assertEqual('');
      expect(cryptoResetRelayAccountsJson('{"password":"x"}')).assertEqual('');
      expect(cryptoResetRelayAccountsJson('')).assertEqual('');
    });

    it('clears_extension_secrets_and_keeps_links_trust_and_lan_hosts', 0, (): void => {
      const hostPayload: Record<string, string> = {};
      hostPayload['sshkeyid'] = 'key-1';
      hostPayload['sshkeypassphrase'] = 'cipher';
      hostPayload['sshproxypassword'] = 'cipher';
      hostPayload['sshhostkeytrustmode'] = '1';
      const host: Record<string, string> | null =
        cryptoResetExtensionPayload('remotehosts', hostPayload);
      expect(host !== null).assertTrue();
      expect(host!['sshkeyid']).assertEqual('key-1');
      expect(host!['sshkeypassphrase']).assertEqual('');
      expect(host!['sshproxypassword']).assertEqual('');
      expect(host!['sshhostkeytrustmode']).assertEqual('1');
      const lanPayload: Record<string, string> = {};
      lanPayload['hostjson'] = '{"host":"192.168.1.2"}';
      lanPayload['password'] = 'cipher';
      const lan: Record<string, string> | null =
        cryptoResetExtensionPayload('dynamiclanhosts', lanPayload);
      expect(lan!['hostjson']).assertEqual('{"host":"192.168.1.2"}');
      expect(lan!['password']).assertEqual('');
      const hash: Record<string, string> = {};
      hash['hash'] = 'cipher';
      expect(cryptoResetExtensionPayload('rdprestrictedadminsecrets', hash) === null).assertTrue();
      const keyMeta: Record<string, string> = {};
      keyMeta['formatversion'] = '2';
      expect(cryptoResetExtensionPayload('sshkeys', keyMeta)!['formatversion']).assertEqual('2');
      // A corrupt table name keeps its payload instead of aborting the reset.
      expect(cryptoResetExtensionPayload('constructor', keyMeta)!['formatversion']).assertEqual('2');
    });

    it('discards_the_pending_journal_of_every_table_the_reset_touches', 0, (): void => {
      const tables: string[] = cryptoResetJournalTables('vncrecordv2', 'vnclocalrecords');
      const touched: string[] = cryptoResetSecretTables().concat(
        ['vncrecordv2', 'vnclocalrecords', 'cryptoparams']);
      for (let i = 0; i < touched.length; i++) {
        expect(tables.indexOf(touched[i]) >= 0).assertTrue();
      }
      expect(tables.indexOf('usersettings')).assertEqual(-1);
      // Uploads of every synced table the reset changed stay blocked.
      const blocked: string[] = cryptoResetUploadBlockTables('vncrecordv2');
      const synced: string[] = cryptoResetSecretTables().concat(['vncrecordv2', 'cryptoparams']);
      for (let i = 0; i < synced.length; i++) {
        expect(blocked.indexOf(synced[i]) >= 0).assertTrue();
      }
      expect(blocked.indexOf('usersettings')).assertEqual(-1);
      expect(blocked.indexOf('vnclocalrecords')).assertEqual(-1);
    });

    it('removes_only_vnc_secret_records', 0, (): void => {
      expect(cryptoResetKeepsVncRecord('secret')).assertFalse();
      expect(cryptoResetKeepsVncRecord('host')).assertTrue();
      expect(cryptoResetKeepsVncRecord('gateway')).assertTrue();
      expect(cryptoResetKeepsVncRecord('settings')).assertTrue();
      expect(cryptoResetKeepsVncRecord('trust')).assertTrue();
    });
  });
}
