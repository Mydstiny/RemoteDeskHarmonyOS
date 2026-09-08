/** Session-only opt-in. Peer platform never grants the user-choice scope. */
import { RemoteHost } from '../model/RemoteHost';

export function hasExplicitRustDeskPhoneChoice(host: RemoteHost): boolean {
  return host.protocol === 'rustdesk' && host.rustdeskTargetDevice === 'phone' &&
    host.sourceType === 'manual' && !host.rustdeskProManaged &&
    host.rustdeskProAccountId === '' && host.rustdeskProPeerId === '' &&
    host.rustdeskProPlatform === '';
}

export function explicitPhoneControlMode(selected: boolean, savedMode: number): number {
  return selected ? 1 : savedMode;
}

/** Android subtracts TouchPan updates from the current absolute pointer. */
export function explicitPhonePanDelta(previous: number, next: number): number {
  return Math.round(previous - next);
}

/** Fail closed until source provenance and decoded-frame identity pass review. */
export function explicitPhoneImplementationReady(): boolean {
  return false;
}
