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
