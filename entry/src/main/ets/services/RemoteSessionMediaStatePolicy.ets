import { LiveViewMode } from './LiveViewTypes';

export enum RemoteSessionMediaKind {
  NONE = 0,
  VIDEO = 1,
  AUDIO = 2
}

export interface RemoteSessionMediaSnapshot {
  hasAudio: boolean;
  hasVideo: boolean;
}

export function resolveRemoteSessionMediaKind(snapshot: RemoteSessionMediaSnapshot): RemoteSessionMediaKind {
  if (snapshot.hasVideo) {
    return RemoteSessionMediaKind.VIDEO;
  }
  if (snapshot.hasAudio) {
    return RemoteSessionMediaKind.AUDIO;
  }
  return RemoteSessionMediaKind.NONE;
}

export function backgroundModesForRemoteMedia(snapshot: RemoteSessionMediaSnapshot): string[] {
  const modes: string[] = ['multiDeviceConnection'];
  if (resolveRemoteSessionMediaKind(snapshot) !== RemoteSessionMediaKind.NONE) {
    modes.push('audioPlayback');
  }
  return modes;
}

export function shouldUseAvSessionForMedia(preferredMode: number, snapshot: RemoteSessionMediaSnapshot): boolean {
  if (preferredMode !== LiveViewMode.AVSESSION) {
    return false;
  }
  return resolveRemoteSessionMediaKind(snapshot) !== RemoteSessionMediaKind.NONE;
}

export function avSessionTypeForRemoteMedia(snapshot: RemoteSessionMediaSnapshot): string {
  return avSessionTypeForRemoteMediaKind(resolveRemoteSessionMediaKind(snapshot));
}

export function avSessionTypeForRemoteMediaKind(kind: RemoteSessionMediaKind): string {
  if (kind === RemoteSessionMediaKind.NONE) {
    return '';
  }
  return 'video';
}

export function shouldRestartLiveViewForMediaChange(currentMode: number, currentKind: RemoteSessionMediaKind,
  nextMode: number, nextKind: RemoteSessionMediaKind): boolean {
  if (currentMode !== nextMode) {
    return true;
  }
  if (nextMode === LiveViewMode.AVSESSION) {
    return avSessionTypeForRemoteMediaKind(currentKind) !== avSessionTypeForRemoteMediaKind(nextKind);
  }
  return currentKind !== nextKind;
}
