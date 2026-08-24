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
