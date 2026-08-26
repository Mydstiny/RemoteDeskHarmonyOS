/**
 * One-shot, process-local authorization tickets for independent session windows.
 *
 * Certificate/host-key preflight is not protocol authentication. RDP, VNC,
 * RustDesk and SSH may issue a window ticket only after the native session is
 * connected and can be handed to the new ability without reconnecting. The
 * ticket is consumed before a new UIAbility is started and never enters Want
 * parameters, logs, persistence or cloud data.
 */
import { util } from '@kit.ArkTS';
import {
  RemoteSessionWindowProtocol
} from './RemoteSessionWindowPolicy';

export type RemoteSessionWindowAuthorizationKind =
  'rdp_preflight_complete' |
  'rdp_authenticated' |
  'rustdesk_authenticated' |
  'vnc_preflight_complete' |
  'vnc_authenticated' |
  'ssh_preflight_complete' |
  'ssh_broker_handoff' |
  'ssh_authenticated' |
  'moonlight_preflight_complete';

export interface RemoteSessionWindowAuthorizationProof {
  token: string;
  protocol: RemoteSessionWindowProtocol;
  hostId: string;
  kind: RemoteSessionWindowAuthorizationKind;
  issuedAtMs: number;
  expiresAtMs: number;
}

const AUTHORIZATION_TTL_MS: number = 60000;

export function remoteSessionWindowAuthorizationMatches(
  protocol: RemoteSessionWindowProtocol,
  kind: RemoteSessionWindowAuthorizationKind
): boolean {
  if (protocol === 'rdp') { return kind === 'rdp_authenticated'; }
  if (protocol === 'rustdesk') { return kind === 'rustdesk_authenticated'; }
  if (protocol === 'vnc') { return kind === 'vnc_authenticated'; }
  if (protocol === 'ssh') { return kind === 'ssh_authenticated'; }
  return protocol === 'moonlight' && kind === 'moonlight_preflight_complete';
}

export function remoteSessionWindowAuthorizationRequiresLiveHandoff(
  kind: RemoteSessionWindowAuthorizationKind
): boolean {
  return kind === 'rdp_authenticated' || kind === 'rustdesk_authenticated' ||
    kind === 'vnc_authenticated' || kind === 'ssh_authenticated';
}

export class RemoteSessionWindowAuthorizationService {
  private static instance: RemoteSessionWindowAuthorizationService | null = null;
  private proofs: Map<string, RemoteSessionWindowAuthorizationProof> =
    new Map<string, RemoteSessionWindowAuthorizationProof>();

  static getInstance(): RemoteSessionWindowAuthorizationService {
    if (RemoteSessionWindowAuthorizationService.instance === null) {
      RemoteSessionWindowAuthorizationService.instance =
        new RemoteSessionWindowAuthorizationService();
    }
    return RemoteSessionWindowAuthorizationService.instance;
  }

  issue(protocol: RemoteSessionWindowProtocol, hostId: string,
    kind: RemoteSessionWindowAuthorizationKind,
    nowMs: number = Date.now()): string {
    const normalizedHostId: string = hostId.trim();
    this.prune(nowMs);
    if (normalizedHostId.length === 0 || normalizedHostId.length > 256 ||
      !remoteSessionWindowAuthorizationMatches(protocol, kind)) {
      return '';
    }
    let token: string = util.generateRandomUUID(true);
    while (this.proofs.has(token)) { token = util.generateRandomUUID(true); }
    this.proofs.set(token, {
      token,
      protocol,
      hostId: normalizedHostId,
      kind,
      issuedAtMs: nowMs,
      expiresAtMs: nowMs + AUTHORIZATION_TTL_MS
    });
    return token;
  }

  consume(token: string, protocol: RemoteSessionWindowProtocol,
    hostId: string, nowMs: number = Date.now()): RemoteSessionWindowAuthorizationProof | null {
    const normalizedToken: string = token.trim();
    const normalizedHostId: string = hostId.trim();
    const proof: RemoteSessionWindowAuthorizationProof | undefined =
      this.proofs.get(normalizedToken);
    // Every lookup is destructive. A mismatched caller cannot probe and then
    // replay a valid authorization ticket against a different destination.
    if (normalizedToken.length > 0) { this.proofs.delete(normalizedToken); }
    this.prune(nowMs);
    if (proof === undefined || proof.expiresAtMs < nowMs ||
      proof.protocol !== protocol || proof.hostId !== normalizedHostId ||
      !remoteSessionWindowAuthorizationMatches(protocol, proof.kind)) {
      return null;
    }
    return proof;
  }

  revoke(token: string): void { this.proofs.delete(token.trim()); }

  resetForTest(): void { this.proofs.clear(); }

  private prune(nowMs: number): void {
    const expired: string[] = [];
    this.proofs.forEach((proof: RemoteSessionWindowAuthorizationProof,
      token: string): void => {
      if (proof.expiresAtMs < nowMs) { expired.push(token); }
    });
    for (let index: number = 0; index < expired.length; index++) {
      this.proofs.delete(expired[index]);
    }
  }
}
