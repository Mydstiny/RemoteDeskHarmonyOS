import { VncHostValues } from './VncModelPolicy';
import { SecretEditMutationKind } from './SecretEditMutationPolicy';

export interface VncSecretEditDecision {
  storageMutation: SecretEditMutationKind;
  submissionValue: string;
  bindingUnchanged: boolean;
}

function normalized(value: string): string {
  return value.trim();
}

/**
 * A VNC password belongs to one exact connection/security endpoint. Repeater
 * target IDs and gateway IDs are both included because either can redirect
 * authentication to another server.
 */
export function vncSecretBindingUnchanged(previous: VncHostValues,
  next: VncHostValues): boolean {
  return previous.transport === next.transport &&
    normalized(previous.host) === normalized(next.host) &&
    previous.port === next.port &&
    normalized(previous.gatewayId) === normalized(next.gatewayId) &&
    previous.repeaterMode === next.repeaterMode &&
    previous.tls === next.tls &&
    previous.securityPolicy === next.securityPolicy;
}

/**
 * Separates persistent mutation from the password handed to the current
 * connection. This preserves an unchanged hidden password only for the same
 * endpoint, supports explicit clearing, and never hands an old password to a
 * changed endpoint.
 */
export function vncSecretEditDecision(existing: string, draft: string,
  draftChanged: boolean, rememberAfterSave: boolean, useForCurrentAction: boolean,
  previous: VncHostValues | null, next: VncHostValues): VncSecretEditDecision {
  const bindingUnchanged: boolean = previous !== null &&
    vncSecretBindingUnchanged(previous, next);
  let storageMutation: SecretEditMutationKind = 'keep';
  if (!rememberAfterSave) {
    storageMutation = 'clear';
  } else if (draftChanged) {
    storageMutation = draft.length > 0 ? 'replace' : 'clear';
  } else if (previous !== null && !bindingUnchanged) {
    storageMutation = 'clear';
  }

  let submissionValue: string = '';
  if (draftChanged) {
    submissionValue = draft;
  } else if (!rememberAfterSave && useForCurrentAction && bindingUnchanged) {
    submissionValue = existing;
  }
  return { storageMutation, submissionValue, bindingUnchanged };
}
