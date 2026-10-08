import { ProConnectionDescription, ProConnectionEnvelope, copyProConnectionDescription,
  parseProConnectionEnvelope, PRO_CONNECTION_TTL_MS } from './ProConnectionEnvelope';

export const PRO_CONNECTION_SHARE_MAX_LINK_CHARS: number = 32768;
const SHARE_FRAGMENT: string = '#rd=';

/** This value comes from the compiled configuration, never from a received Want. */
export function proConnectionShareBaseValid(base: string): boolean {
  return typeof base === 'string' && base.length <= 512 &&
    /^https:\/\/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+$/.test(base);
}

export function makeProConnectionShareEnvelope(description: ProConnectionDescription,
  transferId: string, channelId: string, now: number = Date.now()): ProConnectionEnvelope | null {
  // Copy only the wire-model fields; no serialization of a RemoteHost or account.
  const connection = copyProConnectionDescription(description);
  connection.hostReference = '';
  const envelope: ProConnectionEnvelope = { version: 1, purpose: 'share', transferId, channelId,
    owner: '', createdAt: now, expiresAt: now + PRO_CONNECTION_TTL_MS, connection };
  return parseProConnectionEnvelope(JSON.stringify(envelope), now);
}

export function buildProConnectionShareLink(base: string, envelope: ProConnectionEnvelope,
  now: number = Date.now()): string {
  if (!proConnectionShareBaseValid(base)) { return ''; }
  const checked = parseProConnectionEnvelope(JSON.stringify(envelope), now);
  if (checked === null || checked.purpose !== 'share') { return ''; }
  // URL fragments are not sent in the website's HTTP request. The device path
  // must still be verified to preserve this fragment through Share Kit/App Linking.
  const link = base + SHARE_FRAGMENT + encodeURIComponent(JSON.stringify(checked));
  return link.length <= PRO_CONNECTION_SHARE_MAX_LINK_CHARS ? link : '';
}

export function parseProConnectionShareLink(base: string, link: string,
  now: number = Date.now()): ProConnectionEnvelope | null {
  if (!proConnectionShareBaseValid(base) || typeof link !== 'string' ||
      link.length > PRO_CONNECTION_SHARE_MAX_LINK_CHARS || !link.startsWith(base + SHARE_FRAGMENT)) {
    return null;
  }
  const encoded = link.substring(base.length + SHARE_FRAGMENT.length);
  if (encoded.length === 0) { return null; }
  try {
    const serialized = decodeURIComponent(encoded);
    if (encodeURIComponent(serialized) !== encoded) { return null; }
    const envelope = parseProConnectionEnvelope(serialized, now);
    return envelope !== null && envelope.purpose === 'share' ? envelope : null;
  } catch (_error) { return null; }
}
