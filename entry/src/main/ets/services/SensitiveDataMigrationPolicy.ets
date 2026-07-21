/** Canonical remote-host password ownership: cloud passward -> old main password -> old extension. */
export type HostPasswordMigrationSource = 'passward' | 'legacy_password' | 'extension_password' | 'empty';

export class PasswordMigrationDecision {
  value: string = '';
  source: HostPasswordMigrationSource = 'empty';
  writeCanonical: boolean = false;
  clearLegacyMain: boolean = false;
  clearExtensionPassword: boolean = false;
}

function hasValue(value: string): boolean {
  return value.length > 0;
}

/**
 * Never let a local extension overwrite a non-empty canonical cloud value.
 * The decision is intentionally data-format agnostic: both plaintext and the
 * existing DataCrypto envelope are valid opaque values during migration.
 */
export function canonicalHostPassword(
  passward: string,
  legacyPassword: string,
  extensionPassword: string
): PasswordMigrationDecision {
  const result = new PasswordMigrationDecision();
  if (hasValue(passward)) {
    result.value = passward;
    result.source = 'passward';
    result.clearLegacyMain = hasValue(legacyPassword);
    result.clearExtensionPassword = hasValue(extensionPassword);
    return result;
  }
  if (hasValue(legacyPassword)) {
    result.value = legacyPassword;
    result.source = 'legacy_password';
    result.writeCanonical = true;
    result.clearLegacyMain = true;
    result.clearExtensionPassword = hasValue(extensionPassword);
    return result;
  }
  if (hasValue(extensionPassword)) {
    result.value = extensionPassword;
    result.source = 'extension_password';
    result.writeCanonical = true;
    result.clearExtensionPassword = true;
    return result;
  }
  return result;
}
