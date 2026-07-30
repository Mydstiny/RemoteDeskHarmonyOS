export type CryptoEnvelopeKind =
  'plaintext' | 'legacy_v1' | 'vnc_v2' | 'scoped_v3' |
  'malformed_v1' | 'malformed_v2' | 'malformed_v3' |
  'unknown_versioned';

function decimalVersionPrefix(value: string): boolean {
  const colon: number = value.indexOf(':');
  if (colon <= 0) { return false; }
  const prefix: string = value.substring(0, colon);
  for (let i = 0; i < prefix.length; i++) {
    const code: number = prefix.charCodeAt(i);
    if (code < 48 || code > 57) { return false; }
  }
  return true;
}

export function classifyCryptoEnvelope(value: string): CryptoEnvelopeKind {
  if (value.length === 0 || !decimalVersionPrefix(value)) {
    return 'plaintext';
  }
  const parts: string[] = value.split(':');
  if (parts[0] === '1') {
    return parts.length === 3 && parts[1].length > 0 && parts[2].length > 0
      ? 'legacy_v1' : 'malformed_v1';
  }
  if (parts[0] === '2') {
    return parts.length === 4 && parts[1].length > 0 &&
      parts[2].length > 0 && parts[3].length > 0
      ? 'vnc_v2' : 'malformed_v2';
  }
  if (parts[0] === '3') {
    return parts.length === 4 && parts[1].length > 0 &&
      parts[2].length > 0 && parts[3].length > 0
      ? 'scoped_v3' : 'malformed_v3';
  }
  return 'unknown_versioned';
}

/**
 * A version-looking secret is never treated as plaintext. Unknown or damaged
 * envelopes remain redacted and fail decryption until an explicit recovery
 * path understands them.
 */
export function cryptoEnvelopeIsProtected(value: string): boolean {
  return classifyCryptoEnvelope(value) !== 'plaintext';
}

export function cryptoEnvelopeCanMigrateToV3(value: string): boolean {
  const kind: CryptoEnvelopeKind = classifyCryptoEnvelope(value);
  return kind === 'plaintext' || kind === 'legacy_v1' ||
    kind === 'scoped_v3';
}
