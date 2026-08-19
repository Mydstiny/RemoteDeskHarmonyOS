/**
 * Pure policy for PC/2-in-1 system-level remote-session windows.
 *
 * A window target describes the ArkUI page hosted by RemoteSessionAbility.
 * Only opaque launch ids cross the Ability boundary; connection parameters
 * remain in the in-process coordinator.
 */

export type RemoteSessionWindowTarget = 'remote_desktop' | 'ssh_terminal' | 'moonlight_stream';
export type RemoteSessionWindowProtocol = 'rdp' | 'rustdesk' | 'vnc' | 'ssh' | 'moonlight';

export interface RemoteSessionWindowRequest {
  target: RemoteSessionWindowTarget;
  protocol: RemoteSessionWindowProtocol;
  hostId: string;
  title: string;
  authorizationToken: string;
  routeParams: Record<string, Object>;
}

export interface RemoteSessionWindowPlacement {
  left: number;
  top: number;
  width: number;
  height: number;
}

export const REMOTE_SESSION_WINDOW_MIN_WIDTH_VP: number = 360;
export const REMOTE_SESSION_WINDOW_MIN_HEIGHT_VP: number = 480;
const REMOTE_SESSION_WINDOW_INITIAL_WIDTH_VP: number = 680;
const REMOTE_SESSION_WINDOW_INITIAL_HEIGHT_VP: number = 520;
const REMOTE_SESSION_WINDOW_INITIAL_LEFT_VP: number = 40;
const REMOTE_SESSION_WINDOW_INITIAL_TOP_VP: number = 32;
const REMOTE_SESSION_WINDOW_CASCADE_X_VP: number = 24;
const REMOTE_SESSION_WINDOW_CASCADE_Y_VP: number = 20;

export function remoteSessionWindowPage(target: RemoteSessionWindowTarget): string {
  if (target === 'remote_desktop') { return 'pages/RemoteDesktop'; }
  if (target === 'ssh_terminal') { return 'pages/SshTerminal'; }
  if (target === 'moonlight_stream') { return 'pages/MoonlightStreamPage'; }
  return '';
}

export function remoteSessionWindowRequestIsValid(request: RemoteSessionWindowRequest): boolean {
  const hostId: string = request.hostId.trim();
  if (hostId.length === 0 || hostId.length > 256 ||
    request.authorizationToken.trim().length === 0 ||
    remoteSessionWindowPage(request.target) === '') {
    return false;
  }
  if (request.target === 'remote_desktop') {
    return request.protocol === 'rdp' || request.protocol === 'rustdesk' || request.protocol === 'vnc';
  }
  if (request.target === 'ssh_terminal') {
    return request.protocol === 'ssh';
  }
  return request.target === 'moonlight_stream' && request.protocol === 'moonlight';
}

/** StartOptions geometry is px while its min/max constraints are vp. */
export function remoteSessionWindowPlacement(sequence: number,
  densityPixels: number = 1): RemoteSessionWindowPlacement {
  const slot: number = Math.max(0, Math.floor(sequence)) % 8;
  const density: number = Number.isFinite(densityPixels) && densityPixels > 0 ? densityPixels : 1;
  return {
    left: Math.round((REMOTE_SESSION_WINDOW_INITIAL_LEFT_VP + slot *
      REMOTE_SESSION_WINDOW_CASCADE_X_VP) * density),
    top: Math.round((REMOTE_SESSION_WINDOW_INITIAL_TOP_VP + slot *
      REMOTE_SESSION_WINDOW_CASCADE_Y_VP) * density),
    width: Math.round(REMOTE_SESSION_WINDOW_INITIAL_WIDTH_VP * density),
    height: Math.round(REMOTE_SESSION_WINDOW_INITIAL_HEIGHT_VP * density)
  };
}

export function remoteSessionWindowIdFromParams(params: Object | null | undefined): string {
  if (params === null || params === undefined) { return ''; }
  const values: Record<string, Object> = params as Record<string, Object>;
  const raw: Object | undefined = values['sessionWindowId'];
  return typeof raw === 'string' ? raw.trim() : '';
}
