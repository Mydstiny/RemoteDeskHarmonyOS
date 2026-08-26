/**
 * Extract only the finite platform error code for hilog metadata. Error
 * messages and arbitrary object fields may contain host names, URIs, paths or
 * secrets and must stay out of SSH diagnostics.
 */

interface SshDiagnosticErrorShape {
  code?: number;
}

export function sshDiagnosticErrorCode(error: Object): string {
  if (error === null || typeof error !== 'object') { return 'unknown'; }
  const code: number | undefined = (error as SshDiagnosticErrorShape).code;
  return typeof code === 'number' && Number.isFinite(code)
    ? Math.floor(code).toString() : 'unknown';
}
