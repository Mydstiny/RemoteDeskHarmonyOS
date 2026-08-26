import { describe, it, expect } from '@ohos/hypium';
import { sshDiagnosticErrorCode } from
  '../main/ets/services/ssh/observability/SshDiagnosticPolicy';

export default function sshDiagnosticPolicyTest(): void {
  describe('SshDiagnosticPolicy', (): void => {
    it('should_expose_only_finite_numeric_error_codes', 0, (): void => {
      const sensitive: Object = {
        code: 1300001,
        message: 'host=private.example sourcePath=/remote/private/key',
        password: 'never-log-this'
      };
      const code: string = sshDiagnosticErrorCode(sensitive);
      expect(code).assertEqual('1300001');
      expect(code.indexOf('private.example')).assertEqual(-1);
      expect(code.indexOf('/remote/private/key')).assertEqual(-1);
      expect(code.indexOf('never-log-this')).assertEqual(-1);
      expect(sshDiagnosticErrorCode({ code: Number.NaN })).assertEqual('unknown');
      expect(sshDiagnosticErrorCode({ code: 'secret' })).assertEqual('unknown');
    });
  });
}
