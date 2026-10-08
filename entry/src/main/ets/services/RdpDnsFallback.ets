import { connection } from '@kit.NetworkKit';
import { parseEndpointHost } from './EndpointAddressPolicy';
import { rdpDnsFallbackCandidates, rdpLocalNameEligible, rdpSearchDomainNames } from './RdpDnsFallbackPolicy';

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

const RDP_SEARCH_DOMAIN_TIMEOUT_MS: number = 3000;

/** How a name was finally resolved: DNS, DNS with a search suffix, the local network, or not at all. */
export type RdpNameResolutionVia = 'dns' | 'dns-suffix' | 'local' | '';

export interface RdpNameResolution {
  addresses: string[];
  via: RdpNameResolutionVia;
}

async function networkSearchDomains(): Promise<string> {
  try {
    const handle: connection.NetHandle = await connection.getDefaultNet();
    const properties: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
    return properties.domains ?? '';
  } catch (_error) {
    return '';
  }
}

/**
 * Resolve an RDP host name the way mstsc would reach it: DNS through the
 * HarmonyOS network stack, then the network's DNS search suffixes for a
 * computer name, then the local network itself (mDNS for "<name>.local",
 * LLMNR and NetBIOS for a computer name). `localResolver` performs the last
 * step; `onStage` reports which step is running for the progress text.
 */
export async function resolveRdpHostCandidates(
  host: string,
  localResolver: (name: string) => Promise<string[]>,
  onStage: (stage: RdpNameResolutionVia) => void = (_stage: RdpNameResolutionVia): void => {}
): Promise<RdpNameResolution> {
  onStage('dns');
  const direct: string[] = await resolveRdpDnsFallback(host);
  if (direct.length > 0) {
    return { addresses: direct, via: 'dns' };
  }
  const suffixed: string[] = rdpSearchDomainNames(host, await networkSearchDomains());
  if (suffixed.length > 0) {
    onStage('dns-suffix');
    for (let index = 0; index < suffixed.length; index++) {
      const found: string[] = await resolveRdpDnsFallback(suffixed[index], RDP_SEARCH_DOMAIN_TIMEOUT_MS);
      if (found.length > 0) {
        return { addresses: found, via: 'dns-suffix' };
      }
    }
  }
  if (!rdpLocalNameEligible(host)) {
    return { addresses: [], via: '' };
  }
  onStage('local');
  let local: string[] = [];
  try {
    local = rdpDnsFallbackCandidates(await localResolver(host.trim()));
  } catch (_error) {
    local = [];
  }
  return { addresses: local, via: local.length > 0 ? 'local' : '' };
}
