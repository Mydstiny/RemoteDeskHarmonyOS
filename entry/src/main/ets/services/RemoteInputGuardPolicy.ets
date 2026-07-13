export function shouldBlockRemoteInputForBrowseMode(protocol: string, rustdeskBrowseMode: boolean): boolean {
  return protocol === 'rustdesk' && rustdeskBrowseMode;
}

export function remoteInputBlockedReason(protocol: string, rustdeskBrowseMode: boolean): string {
  if (shouldBlockRemoteInputForBrowseMode(protocol, rustdeskBrowseMode)) {
    return 'RustDesk 浏览模式已开启，仅查看远端画面，不会发送键盘、鼠标或触控输入';
  }
  return '';
}
