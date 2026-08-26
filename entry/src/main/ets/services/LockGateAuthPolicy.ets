export type LockGateAuthKind = 'pin' | 'fingerprint' | 'face';

const SYSTEM_AUTH_KINDS: LockGateAuthKind[] = [
  'pin',
  'fingerprint',
  'face'
];

function copySystemAuthKinds(): LockGateAuthKind[] {
  return SYSTEM_AUTH_KINDS.slice();
}

/**
 * Maps the legacy string contract onto credential types owned by the system
 * User Authentication widget. Unknown protected modes fail closed by using
 * normal system authentication; only an explicit `none` bypasses the gate.
 */
export function lockGateRequestedAuthKinds(mode: string): LockGateAuthKind[] {
  switch (mode.trim().toLowerCase()) {
    case 'none':
      return [];
    case 'pin':
    case 'password':
      // UserAuthType.PIN covers both numeric PIN and mixed lock-screen
      // passwords. The application never reads the credential itself.
      return ['pin'];
    case 'fingerprint':
      return ['fingerprint'];
    case 'face':
      return ['face'];
    case '':
    case 'biometric':
    case 'system':
    default:
      return copySystemAuthKinds();
  }
}

/** Keep request order stable while excluding unavailable and duplicate types. */
export function lockGateAvailableAuthKinds(
  requested: LockGateAuthKind[],
  available: LockGateAuthKind[]
): LockGateAuthKind[] {
  const result: LockGateAuthKind[] = [];
  for (let i = 0; i < requested.length; i++) {
    const kind: LockGateAuthKind = requested[i];
    if (available.indexOf(kind) >= 0 && result.indexOf(kind) < 0) {
      result.push(kind);
    }
  }
  return result;
}

/**
 * Preserve the most actionable availability failure when several credential
 * probes fail. Later TYPE_NOT_SUPPORT results must not hide an expired PIN or
 * a system/service error returned by an earlier probe.
 */
export function lockGatePreferredUnavailableCode(codes: number[]): number {
  if (codes.length === 0) {
    return 12500010;
  }
  let preferredCode: number = codes[0];
  let preferredPriority: number = unavailableCodePriority(preferredCode);
  for (let i = 1; i < codes.length; i++) {
    const priority: number = unavailableCodePriority(codes[i]);
    if (priority > preferredPriority) {
      preferredCode = codes[i];
      preferredPriority = priority;
    }
  }
  return preferredCode;
}

function unavailableCodePriority(code: number): number {
  switch (code) {
    case 12500013: return 100; // PIN_EXPIRED: user must update the credential.
    case 12500008: return 95; // INVALID_PARAMETERS: integration/configuration error.
    case 12500002: return 90; // GENERAL_ERROR: preserve service failures.
    case 12500007: return 90; // BUSY: retry is actionable.
    case 12500010: return 80; // NOT_ENROLLED.
    case 12500006: return 20; // TRUST_LEVEL_NOT_SUPPORT.
    case 12500005: return 10; // TYPE_NOT_SUPPORT.
    case -1: return 0;
    default: return 85; // Do not mask an unknown system error with capability noise.
  }
}
