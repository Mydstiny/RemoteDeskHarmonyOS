/**
 * RemoteImeSessionPolicy.ets - system IME shadow-session decisions.
 *
 * The shadow editor is deliberately local-only.  Its selection deltas become
 * relative remote cursor commands; its whitespace content is never sent.
 */

export const REMOTE_IME_CENTER: number = 2048;
export const REMOTE_IME_EDGE_THRESHOLD: number = 256;
export const REMOTE_IME_MAX_CARET_MOVEMENT: number = 32;
// The remote editor cannot mirror HarmonyOS composing text. Keep the local
// IME responsible for candidate selection and forward only committed text.
export const REMOTE_IME_PREVIEW_ENABLED: boolean = false;

export enum RemoteImeSelectionAction {
  IGNORE_INACTIVE = 0,
  IGNORE_PROGRAMMATIC = 1,
  IGNORE_EXPECTED = 2,
  MOVE_LEFT = 3,
  MOVE_RIGHT = 4,
  COLLAPSE_LOCAL = 5,
  IGNORE_INITIAL = 6
}

export interface RemoteImeShadow {
  text: string;
  caret: number;
}

export interface RemoteImeSelectionInput {
  active: boolean;
  programmatic: boolean;
  initialSelectionPending: boolean;
  expectedStart: number;
  expectedEnd: number;
  syncedCaret: number;
  selectionStart: number;
  selectionEnd: number;
}

export interface RemoteImeSelectionResult {
  action: RemoteImeSelectionAction;
  count: number;
  nextSyncedCaret: number;
  consumeExpected: boolean;
  consumeInitial: boolean;
}

export interface RemoteImeDeleteResult {
  backwardCount: number;
  forwardCount: number;
}

/**
 * Diagnostic fields are deliberately metadata-only: never pass or retain IME
 * input text here, because this object may be logged by the caller.
 */
export interface RemoteImeDiagnostic {
  source: string;
  units: number;
  oldCaret: number;
  newCaret: number;
  delta: number;
  result: string;
}

export function createRemoteImeShadow(): RemoteImeShadow {
  let text = '';
  const length = REMOTE_IME_CENTER * 2;
  for (let index = 0; index < length; index++) {
    text += ' ';
  }
  return {
    text,
    caret: REMOTE_IME_CENTER
  };
}

export function resolveRemoteImeSelection(
  input: RemoteImeSelectionInput
): RemoteImeSelectionResult {
  if (!input.active) {
    return {
      action: RemoteImeSelectionAction.IGNORE_INACTIVE,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: false,
      consumeInitial: false
    };
  }

  if (input.initialSelectionPending) {
    return {
      action: RemoteImeSelectionAction.IGNORE_INITIAL,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: false,
      consumeInitial: true
    };
  }

  if (input.programmatic) {
    return {
      action: RemoteImeSelectionAction.IGNORE_PROGRAMMATIC,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: false,
      consumeInitial: false
    };
  }

  if (input.selectionStart === input.expectedStart && input.selectionEnd === input.expectedEnd) {
    return {
      action: RemoteImeSelectionAction.IGNORE_EXPECTED,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: true,
      consumeInitial: false
    };
  }

  if (input.selectionStart !== input.selectionEnd) {
    return {
      action: RemoteImeSelectionAction.COLLAPSE_LOCAL,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: false,
      consumeInitial: false
    };
  }

  const delta = input.selectionStart - input.syncedCaret;
  if (Math.abs(delta) > REMOTE_IME_MAX_CARET_MOVEMENT) {
    return {
      action: RemoteImeSelectionAction.COLLAPSE_LOCAL,
      count: 0,
      nextSyncedCaret: input.syncedCaret,
      consumeExpected: false,
      consumeInitial: false
    };
  }
  if (delta < 0) {
    return {
      action: RemoteImeSelectionAction.MOVE_LEFT,
      count: -delta,
      nextSyncedCaret: input.selectionStart,
      consumeExpected: false,
      consumeInitial: false
    };
  }

  if (delta > 0) {
    return {
      action: RemoteImeSelectionAction.MOVE_RIGHT,
      count: delta,
      nextSyncedCaret: input.selectionStart,
      consumeExpected: false,
      consumeInitial: false
    };
  }

  return {
    action: RemoteImeSelectionAction.COLLAPSE_LOCAL,
    count: 0,
    nextSyncedCaret: input.syncedCaret,
    consumeExpected: false,
    consumeInitial: false
  };
}

export function splitRemoteImeCaretMovement(count: number, maxChunkSize: number = 256): number[] {
  const chunks: number[] = [];
  let remaining = count;
  while (remaining > 0) {
    const chunk = Math.min(remaining, maxChunkSize);
    chunks.push(chunk);
    remaining -= chunk;
  }
  return chunks;
}

export function resolveRemoteImeDelete(
  direction: number,
  deleteValueLength: number
): RemoteImeDeleteResult {
  const count = Math.max(0, deleteValueLength);
  if (direction === 0) {
    return { backwardCount: count, forwardCount: 0 };
  }
  return { backwardCount: 0, forwardCount: count };
}

export function shouldRecenterRemoteImeShadow(caret: number, textLength: number): boolean {
  return caret < REMOTE_IME_EDGE_THRESHOLD || caret > textLength - REMOTE_IME_EDGE_THRESHOLD;
}

export function shouldAcceptRemoteImeTextChange(active: boolean, previewTextLength: number): boolean {
  return active && previewTextLength === 0;
}

export function shouldCloseRemoteImeSessionOnEditChange(
  keyboardOpen: boolean,
  isEditing: boolean,
  editingObserved: boolean,
  selectionAcknowledgementPending: boolean = false
): boolean {
  return keyboardOpen && !isEditing && editingObserved && !selectionAcknowledgementPending;
}

export function shouldWaitForRemoteImeInput(
  connected: boolean,
  sessionId: number,
  inputForwardReady: boolean
): boolean {
  return connected && sessionId > 0 && !inputForwardReady;
}

export function shouldResetRemoteImeOnPointerDown(keyboardOpen: boolean): boolean {
  return !keyboardOpen;
}

export function createRemoteImeDiagnostic(
  source: string,
  units: number,
  oldCaret: number,
  newCaret: number,
  resultValue: string
): RemoteImeDiagnostic {
  return {
    source,
    units,
    oldCaret,
    newCaret,
    delta: newCaret - oldCaret,
    result: resultValue
  };
}
