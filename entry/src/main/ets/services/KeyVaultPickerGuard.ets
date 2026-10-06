import { keyVaultPickerKeepsUnlocked } from './KeyVaultFormPolicy';

/**
 * A file picker or the QR scanner sends the app to the background. That trip keeps the 2FA page unlocked, but only for
 * KEY_VAULT_PICKER_GRACE_MS: a picker left open longer while the app was in the background (the user may have gone to
 * another app meanwhile) relocks the page when it returns, and a picker that never returns stops counting. A picker
 * that left the app in the foreground (a PC file window) relocks nothing.
 */
const PICKER_SINCE_KEY: string = 'keyVaultExternalPickerSince';
const PICKER_SKIPPED_BACKGROUND_KEY: string = 'keyVaultExternalPickerSkippedBackground';

export function beginKeyVaultExternalPicker(): void {
  AppStorage.setOrCreate<number>(PICKER_SINCE_KEY, Date.now());
  AppStorage.setOrCreate<boolean>(PICKER_SKIPPED_BACKGROUND_KEY, false);
}

export function endKeyVaultExternalPicker(): void {
  const since: number = AppStorage.get<number>(PICKER_SINCE_KEY) ?? 0;
  const skipped: boolean = AppStorage.get<boolean>(PICKER_SKIPPED_BACKGROUND_KEY) === true;
  AppStorage.setOrCreate<number>(PICKER_SINCE_KEY, 0);
  AppStorage.setOrCreate<boolean>(PICKER_SKIPPED_BACKGROUND_KEY, false);
  if (since > 0 && skipped && !keyVaultPickerKeepsUnlocked(since, Date.now())) {
    AppStorage.setOrCreate<boolean>('totpUnlocked', false);
  }
}

/** The app went to the background: true when an open picker explains it (the 2FA page then stays unlocked). */
export function keyVaultPickerExplainsBackground(): boolean {
  if (!keyVaultPickerKeepsUnlocked(AppStorage.get<number>(PICKER_SINCE_KEY) ?? 0, Date.now())) { return false; }
  AppStorage.setOrCreate<boolean>(PICKER_SKIPPED_BACKGROUND_KEY, true);
  return true;
}
