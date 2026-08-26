export interface RemoteVirtualTouchpadKeyboardGuide {
  title: string;
  message: string;
}

export function shouldShowRemoteVirtualTouchpadKeyboardGuide(protocol: string,
  connected: boolean, controlMode: number, shownThisSession: boolean,
  promptVisible: boolean, viewOnly: boolean, alreadyShownEver: boolean = false,
  alwaysVisible: boolean = false): boolean {
  if (!connected || shownThisSession || promptVisible || controlMode !== 0) { return false; }
  if (alreadyShownEver && !alwaysVisible) { return false; }
  if (protocol !== 'rdp' && protocol !== 'rustdesk' && protocol !== 'vnc') { return false; }
  return protocol !== 'vnc' || !viewOnly;
}

export function shouldRetryRemoteVirtualTouchpadKeyboardGuide(
  connected: boolean, retryCount: number): boolean {
  return connected && Number.isSafeInteger(retryCount) && retryCount >= 0 && retryCount < 2;
}

export function remoteVirtualTouchpadKeyboardGuide(
  protocol: string): RemoteVirtualTouchpadKeyboardGuide {
  if (protocol === 'vnc') {
    return {
      title: '虚拟触控板已启用',
      message: '需要输入文字时，可展开贴边的 VNC 控制栏并点击“键盘”。' +
        '\n\n也可以在远程画面上三指轻点打开控制面板，再选择“虚拟键盘”。'
    };
  }
  const protocolLabel: string = protocol === 'rdp' ? 'RDP' : 'RustDesk';
  return {
    title: '虚拟触控板已启用',
    message: protocolLabel + ' 会话中需要输入文字时，请在远程画面上三指轻点打开控制面板，' +
      '再选择“虚拟键盘”。\n\n顶部或贴边会话栏的键盘入口也可以直接打开虚拟键盘。'
  };
}
