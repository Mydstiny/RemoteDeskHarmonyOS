import {
  VncSettingsValues,
  VncTransport,
  VncRepeaterMode,
  validVncPort
} from './VncModelPolicy';

export interface VncSelectableGateway {
  id: string;
  userId: string;
  transport: VncTransport;
  repeaterMode: VncRepeaterMode;
  enabled: boolean;
}

export interface VncHostDefaultsResolution {
  transport: VncTransport;
  port: number;
  gatewayId: string;
  repeaterMode: VncRepeaterMode;
  usedFallback: boolean;
  fallbackCode: string;
}

function directDefaults(port: number, usedFallback: boolean,
  fallbackCode: string): VncHostDefaultsResolution {
  return {
    transport: 'direct_tcp',
    port: validVncPort(port) ? Math.floor(port) : 5900,
    gatewayId: '',
    repeaterMode: 'mode12',
    usedFallback: usedFallback,
    fallbackCode: fallbackCode
  };
}

export function isSelectableVncDefaultGateway(gateway: VncSelectableGateway,
  userId: string): boolean {
  return gateway.id.trim() !== '' && gateway.userId.trim() === userId.trim() &&
    gateway.transport === 'ultravnc_repeater' && gateway.repeaterMode === 'mode12' &&
    gateway.enabled;
}

/** Resolve one immutable draft default; no other gateway may be substituted. */
export function resolveVncHostDefaults(settings: VncSettingsValues,
  userId: string, gateways: VncSelectableGateway[]): VncHostDefaultsResolution {
  const port: number = validVncPort(settings.defaultPort) ? Math.floor(settings.defaultPort) : 5900;
  if (settings.defaultTransport === 'direct_tcp') {
    return directDefaults(port, false, '');
  }
  if (settings.defaultTransport !== 'ultravnc_repeater') {
    return directDefaults(port, true, 'E-VNC-DEFAULT-TRANSPORT');
  }
  const requestedId: string = settings.defaultGatewayId.trim();
  if (requestedId === '') {
    return directDefaults(port, true, 'E-VNC-DEFAULT-GATEWAY');
  }
  for (let i = 0; i < gateways.length; i++) {
    if (gateways[i].id.trim() === requestedId &&
      isSelectableVncDefaultGateway(gateways[i], userId)) {
      return {
        transport: 'ultravnc_repeater',
        port: port,
        gatewayId: requestedId,
        repeaterMode: 'mode12',
        usedFallback: false,
        fallbackCode: ''
      };
    }
  }
  return directDefaults(port, true, 'E-VNC-DEFAULT-GATEWAY');
}
