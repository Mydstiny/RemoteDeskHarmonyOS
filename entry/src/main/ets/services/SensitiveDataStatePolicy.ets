/**
 * DataCrypto intentionally keeps only the DEK in memory.  These helpers make
 * it explicit that configured-but-locked storage is not equivalent to the
 * legacy no-encryption mode.
 */
export type SensitiveDataState = 'disabled' | 'locked' | 'unlocked';

export function sensitiveDataState(configured: boolean, ready: boolean): SensitiveDataState {
  if (!configured) { return 'disabled'; }
  return ready ? 'unlocked' : 'locked';
}

export function sensitiveWriteRequiresUnlock(configured: boolean, ready: boolean): boolean {
  return sensitiveDataState(configured, ready) === 'locked';
}

/** An encrypted envelope cannot be used as plaintext while the DEK is locked. */
export function shouldRedactLockedCiphertext(configured: boolean, ready: boolean, encrypted: boolean): boolean {
  return sensitiveDataState(configured, ready) === 'locked' && encrypted;
}
