/**
 * Explicit remote-platform choice used when the native peer does not expose
 * PeerInfo yet.  The choice is deliberately session/generation scoped: a
 * command choice from one RustDesk peer cannot silently follow a recycled
 * session id or another account/host.
 */
export type RemoteKeyboardLayoutChoice = 'unknown' | 'ctrl' | 'command';

export interface RemoteKeyboardLayoutSelection {
  ownerId: string;
  sessionId: number;
  generation: number;
  choice: RemoteKeyboardLayoutChoice;
}

export function emptyRemoteKeyboardLayoutSelection(): RemoteKeyboardLayoutSelection {
  return { ownerId: '', sessionId: -1, generation: -1, choice: 'unknown' };
}

export function normalizeRemoteKeyboardLayoutChoice(value: string): RemoteKeyboardLayoutChoice {
  const candidate: string = value.trim().toLowerCase();
  if (candidate === 'ctrl' || candidate === 'control' || candidate === 'windows') {
    return 'ctrl';
  }
  if (candidate === 'command' || candidate === 'macos' || candidate === 'mac') {
    return 'command';
  }
  return 'unknown';
}

export function resetRemoteKeyboardLayoutSelection(previous: RemoteKeyboardLayoutSelection,
  ownerId: string, sessionId: number, generation: number): RemoteKeyboardLayoutSelection {
  // Do not mutate the previous snapshot.  ArkUI callbacks can retain the old
  // object while a new connection is being installed.
  return {
    ownerId,
    sessionId,
    generation,
    choice: 'unknown'
  };
}

export function chooseRemoteKeyboardLayout(previous: RemoteKeyboardLayoutSelection,
  ownerId: string, sessionId: number, generation: number,
  choice: string): RemoteKeyboardLayoutSelection {
  if (previous.ownerId !== ownerId || previous.sessionId !== sessionId ||
    previous.generation !== generation) {
    return resetRemoteKeyboardLayoutSelection(previous, ownerId, sessionId, generation);
  }
  return {
    ownerId: previous.ownerId,
    sessionId: previous.sessionId,
    generation: previous.generation,
    choice: normalizeRemoteKeyboardLayoutChoice(choice)
  };
}

export function remoteKeyboardLayoutForSession(selection: RemoteKeyboardLayoutSelection,
  ownerId: string, sessionId: number, generation: number): RemoteKeyboardLayoutChoice {
  if (selection.ownerId !== ownerId || selection.sessionId !== sessionId ||
    selection.generation !== generation) {
    return 'unknown';
  }
  return selection.choice;
}

export function remoteKeyboardLayoutChoiceLabel(choice: RemoteKeyboardLayoutChoice): string {
  if (choice === 'command') { return 'Command（手动选择）'; }
  if (choice === 'ctrl') { return 'Ctrl（手动选择）'; }
  return '未知平台（安全默认 Ctrl，未检测到 Windows）';
}
