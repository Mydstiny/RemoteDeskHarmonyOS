import { describe, it, expect } from '@ohos/hypium';
import {
  keyVaultBatchDeleteMessage,
  normalizeTotpSecret,
  totpImportSummary,
  totpSecretProblem
} from '../main/ets/services/KeyVaultFormPolicy';

export default function keyVaultFormPolicyTest(): void {
  describe('KeyVaultFormPolicy', (): void => {
    it('checks_2fa_secrets_like_the_modern_flow', 0, (): void => {
      expect(normalizeTotpSecret(' jbsw y3dp ')).assertEqual('JBSWY3DP');
      expect(totpSecretProblem('', [])).assertEqual('请填写密钥（Secret）');
      expect(totpSecretProblem('JBSW1', []).length > 0).assertTrue();
      expect(totpSecretProblem('JBSWY3DP', ['JBSWY3DP'])).assertEqual('这个 2FA 账户已经添加过了');
      expect(totpSecretProblem('JBSWY3DP', [])).assertEqual('');
    });

    it('says_what_an_import_or_a_batch_delete_did', 0, (): void => {
      expect(totpImportSummary(3, 0)).assertEqual('已导入 3 个 2FA 账户');
      expect(totpImportSummary(0, 2)).assertEqual('文件里的 2 个账户都已存在或无效');
      expect(keyVaultBatchDeleteMessage(3, 1, true).includes('1 把已锁定')).assertTrue();
    });
  });
}
