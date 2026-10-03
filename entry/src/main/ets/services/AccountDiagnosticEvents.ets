import { DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

/** account_login count: how the sign-in was attempted. */
export const ACCOUNT_LOGIN_INTERACTIVE: number = 1;
export const ACCOUNT_LOGIN_SILENT: number = 2;
export const ACCOUNT_LOGIN_OFFLINE: number = 3;

/** One Huawei ID sign-in attempt: its outcome and the Account Kit error code (numbers only). */
export function recordAccountLogin(kind: number, outcome: DiagnosticOutcome, code: number = 0): void {
  recordDiagnosticEvent('core.account', 'account_login', outcome, 0, 0, code, 0, kind);
}
