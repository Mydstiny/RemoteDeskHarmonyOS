import { connection } from '@kit.NetworkKit';
import { parseEndpointHost } from './EndpointAddressPolicy';
import { rdpDnsFallbackCandidates } from './RdpDnsFallbackPolicy';

const RDP_DNS_FALLBACK_TIMEOUT_MS: number = 5000;

/**
 * Resolve a hostname through the HarmonyOS network stack.  The result is a
 * bounded, numeric, in-memory candidate list for one RDP attempt only.
 */
export async function resolveRdpDnsFallback(
  host: string,
  timeoutMs: number = RDP_DNS_FALLBACK_TIMEOUT_MS
): Promise<string[]> {
  const parsed = parseEndpointHost(host.trim(), 'runtime');
  if (!parsed.ok || parsed.endpoint.family !== 'hostname') {
    return [];
  }
  let timer: number = -1;
  const expired = new Promise<connection.NetAddress[]>((_resolve, reject): void => {
    timer = setTimeout((): void => {
      reject(new Error('RDP_DNS_FALLBACK_TIMEOUT'));
    }, timeoutMs);
  });
  try {
    const addresses = await Promise.race([
      connection.getAddressesByName(parsed.endpoint.canonicalHost), expired
    ]);
    const rawAddresses: string[] = [];
    for (let index = 0; index < addresses.length; index++) {
      rawAddresses.push(addresses[index].address);
    }
    return rdpDnsFallbackCandidates(rawAddresses);
  } catch (_error) {
    return [];
  } finally {
    if (timer !== -1) {
      clearTimeout(timer);
    }
  }
}
