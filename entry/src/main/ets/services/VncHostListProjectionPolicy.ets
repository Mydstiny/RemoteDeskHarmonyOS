import { RemoteHost } from '../model/RemoteHost';
import { VncHostView } from './VncHostService';

/**
 * VNC remains owned by VncHostService/vncrecord. These helpers only create a
 * transient RemoteHost-shaped view for the existing host-card UI and routing.
 */
export const VNC_HOST_UI_PREFIX: string = 'vnc:';

export function vncHostUiId(recordId: string): string {
  return VNC_HOST_UI_PREFIX + recordId.trim();
}

export function vncHostRecordIdFromUiId(uiId: string): string {
  if (!uiId.startsWith(VNC_HOST_UI_PREFIX)) { return ''; }
  const recordId: string = uiId.substring(VNC_HOST_UI_PREFIX.length).trim();
  return recordId;
}

export function isVncHostProjection(host: RemoteHost): boolean {
  return host.protocol === 'vnc' && host.sourceType === 'vnc' &&
    vncHostRecordIdFromUiId(host.id) !== '';
}

export function projectVncHost(host: VncHostView): RemoteHost {
  const projection: RemoteHost = new RemoteHost();
  projection.id = vncHostUiId(host.id);
  projection.userId = host.userId;
  projection.label = host.label;
  projection.protocol = 'vnc';
  projection.host = host.host;
  projection.port = host.port;
  projection.username = '';
  projection.password = '';
  projection.locked = host.locked;
  projection.lockType = host.lockType;
  projection.syncVersion = host.syncVersion;
  projection.createdAt = host.createdAt;
  projection.sourceType = 'vnc';
  return projection;
}
