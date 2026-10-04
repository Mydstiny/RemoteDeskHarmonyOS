/**
 * Master password rules (user decision 2026-10-04): no length or complexity
 * requirement. A password must not be empty and both entries must match; it
 * is used exactly as typed, never trimmed or truncated. Unlocking an existing
 * password is not affected by these rules.
 */
export function masterPasswordValueAcceptable(password: string): boolean {
  return password.length > 0;
}

/** '' when the new password can be set; otherwise the message to show. */
export function masterPasswordSetupError(password: string, confirm: string): string {
  if (!masterPasswordValueAcceptable(password)) { return '请输入主密码'; }
  if (password !== confirm) { return '两次输入的密码不一致'; }
  return '';
}
