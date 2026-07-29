import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;

export default class EntryBackupAbility extends BackupExtensionAbility {
  onBackup(): void {
    // backup_config keeps this extension disabled until a real device-transfer
    // pilot proves the account/schema/crypto restore pipeline. Never log a
    // false success from this compatibility entry point.
    hilog.warn(DOMAIN, 'EntryBackup',
      'system backup is disabled; use portable backup v3');
  }

  onRestore(bundleVersion: BundleVersion): void {
    hilog.warn(DOMAIN, 'EntryBackup',
      'system restore ignored while disabled source=%{public}s',
      JSON.stringify(bundleVersion));
  }
}
