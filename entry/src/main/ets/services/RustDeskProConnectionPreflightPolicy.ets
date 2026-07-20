export enum RustDeskProPreflightState {
  IDLE = 0,
  CONNECTING = 1,
  AUTHENTICATED = 2,
  ERROR = 3
}

export function shouldOpenRustDeskProPreflight(protocol: string, sourceType: string,
  rustdeskProManaged: boolean): boolean {
  // 这个 Sheet 实际承载所有 RustDesk 主机的连接鉴权选择；
  // Server Pro 只是其中一种主机来源，不能决定是否显示设备密码/请求批准。
  return protocol === 'rustdesk';
}

export function shouldRouteAfterRustDeskProPreflight(state: RustDeskProPreflightState): boolean {
  return state === RustDeskProPreflightState.AUTHENTICATED;
}

export function shouldKeepRustDeskProSheetOpen(state: RustDeskProPreflightState): boolean {
  return state === RustDeskProPreflightState.CONNECTING || state === RustDeskProPreflightState.ERROR;
}

export function rustDeskProPeerIdForConnection(stablePeerId: string, legacyPeerId: string): string {
  const stable: string = stablePeerId.trim();
  return stable.length > 0 ? stable : legacyPeerId.trim();
}
