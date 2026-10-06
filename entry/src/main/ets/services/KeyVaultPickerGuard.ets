import { keyVaultPickerKeepsUnlocked } from './KeyVaultFormPolicy';

/**
 * A file picker or the QR scanner sends the app to the background. That trip keeps the 2FA page unlocked, but only for
 * KEY_VAULT_PICKER_GRACE_MS: a picker left open longer (the user may have gone to another app meanwhile, or the picker
 * never returned) no longer counts, and relocks the page when it returns.
 */
const PICKER_SINCE_KEY: string = 'keyVaultExternalPickerSince';

export function beginKeyVaultExternalPicker(): void {
  AppStorage.setOrCreate<number>(PICKER_SINCE_KEY, Date.now());
}

export function endKeyVaultExternalPicker(): void {
  const since: number = AppStorage.get<number>(PICKER_SINCE_KEY) ?? 0;
  AppStorage.setOrCreate<number>(PICKER_SINCE_KEY, 0);
  if (since > 0 && !keyVaultPickerKeepsUnlocked(since, Date.now())) {
    AppStorage.setOrCreate<boolean>('totpUnlocked', false);
  }
}

/** Whether the app going to the background now is the picker's doing. */
export function keyVaultExternalPickerOpen(): boolean {
  return keyVaultPickerKeepsUnlocked(AppStorage.get<number>(PICKER_SINCE_KEY) ?? 0, Date.now());
}
