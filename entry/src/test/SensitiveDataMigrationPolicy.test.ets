import { describe, it, expect } from '@ohos/hypium';
import { canonicalHostPassword } from '../main/ets/services/SensitiveDataMigrationPolicy';

export default function sensitiveDataMigrationPolicyTest(): void {
  describe('SensitiveDataMigrationPolicy', (): void => {
    it('keeps_non_empty_passward_over_every_legacy_shadow', 0, (): void => {
      const decision = canonicalHostPassword('canonical', 'old-main', 'old-extension');
      expect(decision.value).assertEqual('canonical');
      expect(decision.source).assertEqual('passward');
      expect(decision.writeCanonical).assertFalse();
      expect(decision.clearLegacyMain).assertTrue();
      expect(decision.clearExtensionPassword).assertTrue();
    });

    it('migrates_legacy_main_before_extension', 0, (): void => {
      const decision = canonicalHostPassword('', 'old-main', 'old-extension');
      expect(decision.value).assertEqual('old-main');
      expect(decision.source).assertEqual('legacy_password');
      expect(decision.writeCanonical).assertTrue();
      expect(decision.clearExtensionPassword).assertTrue();
    });

    it('uses_extension_only_when_both_main_columns_are_empty', 0, (): void => {
      const decision = canonicalHostPassword('', '', 'old-extension');
      expect(decision.value).assertEqual('old-extension');
      expect(decision.source).assertEqual('extension_password');
      expect(decision.writeCanonical).assertTrue();
      expect(decision.clearExtensionPassword).assertTrue();
    });
  });
}
