/** Device-local privacy policy for connection summaries rendered on host cards. */

export const HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY: string =
  'hostCardSensitiveInfoHidden';
export const HOST_CARD_SENSITIVE_INFO_HIDDEN_TEXT: string = '敏感信息已隐藏';

export function shouldHideHostCardSensitiveInfo(preferenceEnabled: boolean,
  hostLocked: boolean): boolean {
  return preferenceEnabled || hostLocked;
}

export function hostCardSensitiveValue(hidden: boolean, visibleValue: string): string {
  return hidden ? HOST_CARD_SENSITIVE_INFO_HIDDEN_TEXT : visibleValue;
}

/** Preserve user-facing labels, but replace a RustDesk ID that became the fallback label. */
export function hostCardDisplayLabel(hidden: boolean, protocol: string, label: string,
  rustdeskPeerId: string, rustdeskControlId: string): string {
  const normalizedLabel: string = label.trim();
  if (normalizedLabel.length === 0) { return '未命名主机'; }
  if (hidden && protocol === 'rustdesk') {
    const peerId: string = rustdeskPeerId.trim();
    const controlId: string = rustdeskControlId.trim();
    if ((peerId.length > 0 && normalizedLabel === peerId) ||
      (controlId.length > 0 && normalizedLabel === controlId)) {
      return 'RustDesk 主机';
    }
  }
  return label;
}
