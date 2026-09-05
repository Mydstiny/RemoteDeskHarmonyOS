/** SSH 连接前置安全校验的 UI 状态。 */
export enum SshPreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  HOST_KEY_CHANGED = 3,
  PASSPHRASE_REQUIRED = 4,
  VERIFYING_PASSPHRASE = 5,
  ERROR = 6
}
