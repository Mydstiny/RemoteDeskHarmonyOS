import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { VncHostService, VncHostView } from './VncHostService';
import { VncGatewayService, VncGatewayView } from './VncGatewayService';
import {
  VncTlsEndpointResolution,
  vncTlsGatewayInput,
  vncTlsHostInput,
  resolveVncTlsEndpoint
} from './VncTlsEndpointPolicy';
import { VncTrustService, VncTrustView, vncStoreIdentityFingerprint } from './VncTrustService';

export type VncTrustEndpointStatus = 'current' | 'changed' | 'orphaned' | 'target_missing' | 'ambiguous';

export interface VncTrustDirectoryItem {
  trust: VncTrustView;
  status: VncTrustEndpointStatus;
  endpointExists: boolean;
  transport: string;
  selectedHostId: string;
  matchingHostCount: number;
  endpointLabel: string;
  ownerLabel: string;
}

export interface VncTrustBindingCandidate {
  hostId: string;
  label: string;
  endpointBindingFingerprint: string;
}

export interface VncTrustBindingSelection {
  status: 'current' | 'changed' | 'target_missing' | 'ambiguous';
  selectedHostId: string;
  matchingHostCount: number;
}

function storeFingerprint(): string {
  return vncStoreIdentityFingerprint(AccountSessionCoordinator.getInstance().currentScope().storeIdentity);
}

function hostResolution(host: VncHostView, gateway: VncGatewayView | null,
  store: string): VncTlsEndpointResolution {
  return resolveVncTlsEndpoint(
    vncTlsHostInput(host.id, host.userId, host, host.host, store),
    gateway === null ? null : vncTlsGatewayInput(gateway.id, gateway.userId, gateway, store));
}

function ownerLabel(trust: VncTrustView, hosts: VncHostView[], gateways: VncGatewayView[]): string {
  if (trust.ownerType === 'host') {
    const host: VncHostView | undefined = hosts.find((item: VncHostView): boolean => item.id === trust.ownerId);
    return host === undefined ? trust.ownerId : host.label;
  }
  const gateway: VncGatewayView | undefined = gateways.find((item: VncGatewayView): boolean => item.id === trust.ownerId);
  return gateway === undefined ? trust.ownerId : gateway.label;
}

export function selectVncTrustRecheckHost(trust: VncTrustView,
  candidates: VncTrustBindingCandidate[]): VncTrustBindingSelection {
  if (candidates.length === 0) {
    return { status: 'target_missing', selectedHostId: '', matchingHostCount: 0 };
  }
  const matches: VncTrustBindingCandidate[] = candidates.filter((candidate: VncTrustBindingCandidate): boolean =>
    candidate.endpointBindingFingerprint.trim().toLowerCase() === trust.endpointBindingFingerprint.trim().toLowerCase());
  if (matches.length === 1) {
    return { status: 'current', selectedHostId: matches[0].hostId, matchingHostCount: 1 };
  }
  if (matches.length > 1) {
    const labelled: VncTrustBindingCandidate[] = matches.filter((candidate: VncTrustBindingCandidate): boolean =>
      trust.endpointLabel.trim() !== '' && candidate.label.trim() === trust.endpointLabel.trim());
    if (labelled.length === 1) {
      return { status: 'current', selectedHostId: labelled[0].hostId, matchingHostCount: matches.length };
    }
    return { status: 'ambiguous', selectedHostId: '', matchingHostCount: matches.length };
  }
  return { status: 'changed', selectedHostId: '', matchingHostCount: 0 };
}

/**
 * Projects trust rows against the live VNC host/gateway directory. This is a
 * read-only view helper: it never changes trust state and never treats a row
 * as a connection authorization. A recheck is offered only when a concrete
 * current host can be resolved to the same endpoint binding.
 */
export function buildVncTrustDirectory(trusts: VncTrustView[],
  hosts: VncHostView[], gateways: VncGatewayView[]): VncTrustDirectoryItem[] {
  const store: string = storeFingerprint();
  const result: VncTrustDirectoryItem[] = [];
  for (let i = 0; i < trusts.length; i++) {
    const trust: VncTrustView = trusts[i];
    const item: VncTrustDirectoryItem = {
      trust: trust,
      status: 'orphaned',
      endpointExists: false,
      transport: trust.ownerType === 'gateway' ? 'ultravnc_repeater' : 'direct_tcp',
      selectedHostId: '',
      matchingHostCount: 0,
      endpointLabel: trust.endpointLabel.trim(),
      ownerLabel: ownerLabel(trust, hosts, gateways)
    };
    if (trust.ownerType === 'host') {
      const host: VncHostView | undefined = hosts.find((value: VncHostView): boolean => value.id === trust.ownerId);
      if (host !== undefined) {
        const resolution: VncTlsEndpointResolution = hostResolution(host, null, store);
        item.transport = host.transport;
        item.endpointExists = resolution.ok;
        const selection = selectVncTrustRecheckHost(trust, [{
          hostId: host.id, label: host.label,
          endpointBindingFingerprint: resolution.ok ? resolution.endpointBindingFingerprint : ''
        }]);
        item.status = selection.status;
        item.selectedHostId = selection.selectedHostId;
        item.matchingHostCount = selection.matchingHostCount;
      }
      result.push(item);
      continue;
    }

    const gateway: VncGatewayView | undefined = gateways.find((value: VncGatewayView): boolean => value.id === trust.ownerId);
    if (gateway === undefined) {
      result.push(item);
      continue;
    }
    item.transport = gateway.transport;
    const candidates: VncHostView[] = hosts.filter((host: VncHostView): boolean =>
      host.gatewayId.trim() === gateway.id.trim() && host.userId.trim() === trust.userId.trim());
    const candidatesForSelection: VncTrustBindingCandidate[] = [];
    for (let j = 0; j < candidates.length; j++) {
      const resolution: VncTlsEndpointResolution = hostResolution(candidates[j], gateway, store);
      candidatesForSelection.push({
        hostId: candidates[j].id,
        label: candidates[j].label,
        endpointBindingFingerprint: resolution.ok ? resolution.endpointBindingFingerprint : ''
      });
    }
    item.endpointExists = gateway.host.trim() !== '' && gateway.port > 0;
    const selection = selectVncTrustRecheckHost(trust, candidatesForSelection);
    item.status = selection.status;
    item.selectedHostId = selection.selectedHostId;
    item.matchingHostCount = selection.matchingHostCount;
    if (item.status === 'target_missing') { item.endpointExists = false; }
    result.push(item);
  }
  return result;
}

export function buildCurrentVncTrustDirectory(): VncTrustDirectoryItem[] {
  const trustService = VncTrustService.getInstance();
  const hosts = VncHostService.getInstance().list();
  const gateways = VncGatewayService.getInstance().list();
  return buildVncTrustDirectory(trustService.list(), hosts, gateways);
}
