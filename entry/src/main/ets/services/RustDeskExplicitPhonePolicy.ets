/** Session-only opt-in. Peer platform never grants the user-choice scope. */
import { RemoteHost } from '../model/RemoteHost';

/** Candidate only. A normalized manual source is never selection evidence. */
export function isManualRustDeskPhoneTarget(host: RemoteHost): boolean {
  return host.protocol === 'rustdesk' && host.rustdeskTargetDevice === 'phone' &&
    host.sourceType === 'manual' && !host.rustdeskProManaged &&
    host.rustdeskProAccountId === '' && host.rustdeskProPeerId === '' &&
    host.rustdeskProPlatform === '';
}

export function hasExplicitRustDeskPhoneChoice(host: RemoteHost): boolean {
  return isManualRustDeskPhoneTarget(host) && host.rustdeskPhoneChoiceVersion === 1;
}

/** Only the owner-scoped local extension reader may restore this evidence. */
export function restoreLocalRustDeskPhoneChoice(host: RemoteHost, version: string | undefined): void {
  if (host.protocol === 'rustdesk') {
    host.rustdeskPhoneChoiceVersion = isManualRustDeskPhoneTarget(host) && version === '1' ? 1 : 0;
  }
}

export function explicitPhoneControlMode(selected: boolean, savedMode: number): number {
  return selected ? 1 : savedMode;
}

/** Android subtracts TouchPan updates from the current absolute pointer. */
export function explicitPhonePanDelta(previous: number, next: number): number {
  return Math.round(previous - next);
}

/** Rollout boundary; selection proof and native frame readiness remain mandatory. */
export function explicitPhoneImplementationReady(): boolean {
  return true;
}
