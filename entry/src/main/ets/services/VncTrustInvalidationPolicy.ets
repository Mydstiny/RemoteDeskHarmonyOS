import { VncGatewayValues, VncHostValues } from './VncModelPolicy';

/**
 * Device-local VNC confirmation markers are preference values, not cloud
 * records. This policy keeps the current marker format explicit while still
 * recognizing the two legacy formats written before endpoint binding existed.
 */
export interface VncTrustMarkerIdentity {
  userId: string;
  storeIdentityFingerprint: string;
  ownerType: 'host' | 'gateway' | '';
  ownerId: string;
  fingerprintSha256: string;
  endpointBindingFingerprint: string;
}

function markerParts(marker: string): string[] {
  return marker.split('|');
}

function hasSafeMarkerPart(value: string): boolean {
  return value.trim() !== '' && value.indexOf('|') < 0;
}

/** New markers carry ownerType; old markers remain readable for migration. */
export function vncTrustMarkerKey(identity: VncTrustMarkerIdentity): string {
  const userId: string = identity.userId.trim();
  const store: string = identity.storeIdentityFingerprint.trim().toLowerCase();
  const ownerType: string = identity.ownerType.trim();
  const ownerId: string = identity.ownerId.trim();
  const fingerprint: string = identity.fingerprintSha256.trim().toLowerCase();
  const binding: string = identity.endpointBindingFingerprint.trim().toLowerCase();
  if (!hasSafeMarkerPart(userId) || !/^[0-9a-f]{64}$/.test(store) ||
    (ownerType !== 'host' && ownerType !== 'gateway') || !hasSafeMarkerPart(ownerId) ||
    !/^[0-9a-f]{64}$/.test(fingerprint) || !/^[0-9a-f]{64}$/.test(binding)) {
    return '';
  }
  return userId + '|' + store + '|' + ownerType + '|' + ownerId + '|' + fingerprint + '|' + binding;
}

function parsedMarker(marker: string): VncTrustMarkerIdentity | null {
  const parts: string[] = markerParts(marker);
  if (parts.length === 6) {
    return {
      userId: parts[0], storeIdentityFingerprint: parts[1].toLowerCase(),
      ownerType: parts[2] === 'host' || parts[2] === 'gateway' ? parts[2] : '',
      ownerId: parts[3], fingerprintSha256: parts[4].toLowerCase(),
      endpointBindingFingerprint: parts[5].toLowerCase()
    };
  }
  if (parts.length === 5) {
    // Pre-ownerType endpoint-bound format: user|store|owner|fingerprint|binding.
    return {
      userId: parts[0], storeIdentityFingerprint: parts[1].toLowerCase(), ownerType: '',
      ownerId: parts[2], fingerprintSha256: parts[3].toLowerCase(),
      endpointBindingFingerprint: parts[4].toLowerCase()
    };
  }
  if (parts.length === 4) {
    // Intermediate format without endpoint binding.
    return {
      userId: parts[0], storeIdentityFingerprint: parts[1].toLowerCase(), ownerType: '',
      ownerId: parts[2], fingerprintSha256: parts[3].toLowerCase(),
      endpointBindingFingerprint: ''
    };
  }
  if (parts.length === 3) {
    // v1 device-local marker: user|owner|fingerprint.
    return {
      userId: parts[0], storeIdentityFingerprint: '', ownerType: '',
      ownerId: parts[1], fingerprintSha256: parts[2].toLowerCase(),
      endpointBindingFingerprint: ''
    };
  }
  return null;
}

export function vncTrustMarkerMatchesOwner(marker: string, userId: string,
  ownerType: 'host' | 'gateway', ownerId: string): boolean {
  const parsed: VncTrustMarkerIdentity | null = parsedMarker(marker);
  return parsed !== null && parsed.userId === userId.trim() &&
    parsed.ownerId === ownerId.trim() &&
    (parsed.ownerType === '' || parsed.ownerType === ownerType);
}

export function vncTrustMarkerMatchesEndpoint(marker: string, userId: string,
  ownerType: 'host' | 'gateway', ownerId: string, endpointBindingFingerprint: string,
  fingerprintSha256: string = ''): boolean {
  const parsed: VncTrustMarkerIdentity | null = parsedMarker(marker);
  if (parsed === null || parsed.userId !== userId.trim() ||
    parsed.ownerId !== ownerId.trim() ||
    (parsed.ownerType !== '' && parsed.ownerType !== ownerType)) {
    return false;
  }
  const binding: string = endpointBindingFingerprint.trim().toLowerCase();
  if (binding !== '' && parsed.endpointBindingFingerprint !== '' &&
    parsed.endpointBindingFingerprint !== binding) {
    return false;
  }
  const fingerprint: string = fingerprintSha256.trim().toLowerCase();
  return fingerprint === '' || parsed.fingerprintSha256 === fingerprint;
}

export function removeVncTrustMarkersForOwner(markers: string[], userId: string,
  ownerType: 'host' | 'gateway', ownerId: string): string[] {
  return markers.filter((marker: string): boolean =>
    !vncTrustMarkerMatchesOwner(marker, userId, ownerType, ownerId));
}

/** Remove old endpoint markers while retaining an optional newly-confirmed pin. */
export function removeVncTrustMarkersForEndpoint(markers: string[], userId: string,
  ownerType: 'host' | 'gateway', ownerId: string, endpointBindingFingerprint: string,
  keepFingerprintSha256: string = ''): string[] {
  const keep: string = keepFingerprintSha256.trim().toLowerCase();
  return markers.filter((marker: string): boolean => {
    if (!vncTrustMarkerMatchesEndpoint(marker, userId, ownerType, ownerId,
      endpointBindingFingerprint)) { return true; }
    if (keep !== '') {
      const parsed: VncTrustMarkerIdentity | null = parsedMarker(marker);
      return parsed !== null && parsed.fingerprintSha256 === keep;
    }
    return false;
  });
}

function normalized(value: string): string { return value.trim().toLowerCase(); }

/** Certificate endpoint identity for a VNC host; repeater target is not TLS identity. */
export function vncHostTrustEndpointChanged(previous: VncHostValues,
  next: VncHostValues): boolean {
  if (previous.transport !== next.transport ||
    normalized(previous.gatewayId) !== normalized(next.gatewayId) ||
    previous.repeaterMode !== next.repeaterMode) { return true; }
  if (previous.transport === 'direct_tcp' || next.transport === 'direct_tcp') {
    return normalized(previous.host) !== normalized(next.host) ||
      previous.port !== next.port || previous.tls !== next.tls;
  }
  return false;
}

/** Gateway certificate endpoint identity. Labels, path and target are not TLS identity. */
export function vncGatewayTrustEndpointChanged(previous: VncGatewayValues,
  next: VncGatewayValues): boolean {
  return previous.transport !== next.transport || normalized(previous.host) !== normalized(next.host) ||
    previous.port !== next.port || previous.tls !== next.tls ||
    previous.repeaterMode !== next.repeaterMode || previous.enabled !== next.enabled;
}
