/** TotpImportService.test.ets — 2FA 文件导入格式回归测试 */

import { describe, it, expect } from '@ohos/hypium';
import { TotpImportService, TotpImportResult, totpImportFileName } from '../main/ets/services/TotpImportService';
import { TotpAlgorithm } from '../main/ets/model/TotpEntry';

export default function totpImportServiceTest() {
  const service = new TotpImportService();
  const secret = 'JBSWY3DPEHPK3PXP';

  describe('TotpImportService_FileName', () => {
    it('extract_should_decode_document_name', 0, () => {
      expect(totpImportFileName('file://local/Documents/my%202fa.atsf?open=1')).assertEqual('my 2fa.atsf');
    });
  });

  describe('TotpImportService_ATSF', () => {
    it('array_should_import_entries', 0, () => {
      const result: TotpImportResult = service.parse('backup.atsf',
        '[{"issuer":"GitHub","account":"dev@example.com","secret":"' + secret + '"}]');
      expect(result.ok).assertTrue();
      expect(result.format).assertEqual('ATSF');
      expect(result.entries.length).assertEqual(1);
      expect(result.entries[0].issuer).assertEqual('GitHub');
    });

    it('versioned_wrapper_should_import_entries', 0, () => {
      const result: TotpImportResult = service.parse('backup.atsf',
        '{"version":1,"entries":[{"uri":"otpauth://totp/Acme:user?secret=' + secret + '&issuer=Acme"}]}');
      expect(result.ok).assertTrue();
      expect(result.entries[0].account).assertEqual('user');
    });

    it('future_version_should_be_rejected', 0, () => {
      const result: TotpImportResult = service.parse('backup.atsf', '{"version":2,"entries":[]}');
      expect(result.ok).assertFalse();
      expect(result.error.indexOf('版本') >= 0).assertTrue();
    });

    it('damaged_file_should_be_rejected', 0, () => {
      const result: TotpImportResult = service.parse('backup.atsf', '{damaged');
      expect(result.ok).assertFalse();
      expect(result.entries.length).assertEqual(0);
    });

    it('encrypted_container_should_fail_with_clear_error', 0, () => {
      const result: TotpImportResult = service.parse('backup.atsf',
        '{"version":1,"encrypted":true,"ciphertext":"fixture"}');
      expect(result.ok).assertFalse();
      expect(result.error.indexOf('加密') >= 0).assertTrue();
    });
  });

  describe('TotpImportService_TextJsonCsv', () => {
    it('txt_should_import_multiple_uris', 0, () => {
      const text = 'first otpauth://totp/One:a?secret=' + secret + '&issuer=One\n' +
        'otpauth://totp/Two:b?secret=KRUGS4ZANFZSAYJA&issuer=Two';
      const result: TotpImportResult = service.parse('accounts.txt', text);
      expect(result.ok).assertTrue();
      expect(result.entries.length).assertEqual(2);
    });

    it('json_accounts_wrapper_should_import_metadata', 0, () => {
      const result: TotpImportResult = service.parse('accounts.json',
        '{"accounts":[{"issuer":"Cloud","accountName":"ops","secretBase32":"' + secret +
        '","algorithm":"SHA256","digits":8,"period":60}]}');
      expect(result.ok).assertTrue();
      expect(result.entries[0].algorithm).assertEqual(TotpAlgorithm.SHA256);
      expect(result.entries[0].digits).assertEqual(8);
      expect(result.entries[0].period).assertEqual(60);
    });

    it('csv_should_parse_quoted_columns', 0, () => {
      const result: TotpImportResult = service.parse('accounts.csv',
        'issuer,account,secret,algorithm,digits,period\n"Acme, Inc",user,' + secret + ',SHA512,8,60');
      expect(result.ok).assertTrue();
      expect(result.entries[0].issuer).assertEqual('Acme, Inc');
      expect(result.entries[0].algorithm).assertEqual(TotpAlgorithm.SHA512);
    });

    it('empty_or_invalid_records_should_be_rejected', 0, () => {
      expect(service.parse('empty.txt', 'nothing here').ok).assertFalse();
      expect(service.parse('empty.json', '{"items":[]}').ok).assertFalse();
      expect(service.parse('empty.csv', 'issuer,account,secret').ok).assertFalse();
    });
  });
}
