/** Cold-start policies kept independent from ArkUI lifecycle callbacks. */

export const FIRST_LAUNCH_PREPARATION_BLOCKS_UI: boolean = false;

const PRIMARY_STARTUP_PAGE: string = 'pages/GuidePage';
const FALLBACK_STARTUP_PAGE: string = 'pages/LoginPage';

/**
 * A broken onboarding page must not leave the WindowStage without UIContent.
 * The fallback remains interactive and leaves the guide marker untouched, so
 * a later healthy launch can still present the first-install guide.
 */
export function startupContentPathForAttempt(attempt: number): string {
  if (attempt === 0) { return PRIMARY_STARTUP_PAGE; }
  if (attempt === 1) { return FALLBACK_STARTUP_PAGE; }
  return '';
}
