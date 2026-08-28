import { DisplayConfig, DisplayConfigJSON, RemoteHost } from '../model/RemoteHost';
import { VncHostValues, VncScalingMode } from './VncModelPolicy';
import { normalizeRustDeskDesktopFlipMode } from './RustDeskDesktopFlipPolicy';

/**
 * Device-local host personalization envelope.
 *
 * Version 1 deliberately lives in localextensions only. Existing distributed
 * columns remain readable and writable as a compatibility snapshot for older
 * clients, but they are no longer the effective value after this envelope has
 * been established on a device.
 */
export const HOST_LOCAL_PERSONALIZATION_VERSION: string = '1';

export interface RemoteHostLegacyPersonalization {
  displayConfigJson: string;
  lastConnected: number;
  lastHealth: number;
  lastLatency: number;
  rustdeskAdaptiveOrientation: boolean;
  rustdeskProLastSeenAt: number;
  rustdeskProSyncError: string;
}

export function remoteHostLocalPersonalizationValues(host: RemoteHost): Record<string, string> {
  const values: Record<string, string> = {};
  values['localpersonalizationversion'] = HOST_LOCAL_PERSONALIZATION_VERSION;
  values['localdisplayconfig'] = JSON.stringify(host.displayConfig.toJSON());
  values['locallastconnected'] = host.lastConnected.toString();
  values['locallasthealth'] = host.lastHealth.toString();
  values['locallastlatency'] = host.lastLatency.toString();
  values['localrustdeskadaptiveorientation'] = host.rustdeskAdaptiveOrientation ? '1' : '0';
  values['localrustdeskdesktopflipmode'] = host.rustdeskDesktopFlipMode;
  values['localrustdeskprolastseenat'] = host.rustdeskProLastSeenAt.toString();
  values['localrustdeskprosyncerror'] = host.rustdeskProSyncError;
  return values;
}

function finiteNonNegative(value: string, fallback: number): number {
  const parsed: number = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

/** Missing, corrupt or future-version local state is never a startup gate. */
export function applyRemoteHostLocalPersonalization(
  host: RemoteHost,
  values: Record<string, string>
): RemoteHost {
  if (values['localpersonalizationversion'] !== HOST_LOCAL_PERSONALIZATION_VERSION) {
    return host;
  }
  const displayJson: string = values['localdisplayconfig'] || '';
  if (displayJson !== '') {
    try {
      const parsed: DisplayConfigJSON = JSON.parse(displayJson) as DisplayConfigJSON;
      host.displayConfig = DisplayConfig.fromJSON(parsed);
    } catch (_err) {
      // Keep the legacy cloud value when one local field is malformed.
    }
  }
  if (values['locallastconnected'] !== undefined) {
    host.lastConnected = finiteNonNegative(values['locallastconnected'], host.lastConnected);
  }
  if (values['locallasthealth'] !== undefined) {
    const health: number = finiteNonNegative(values['locallasthealth'], host.lastHealth);
    if (Number.isInteger(health) && health <= 5) { host.lastHealth = health; }
  }
  if (values['locallastlatency'] !== undefined) {
    host.lastLatency = finiteNonNegative(values['locallastlatency'], host.lastLatency);
  }
  if (values['localrustdeskadaptiveorientation'] === '1' ||
    values['localrustdeskadaptiveorientation'] === '0') {
    host.rustdeskAdaptiveOrientation = values['localrustdeskadaptiveorientation'] === '1';
  }
  if (values['localrustdeskdesktopflipmode'] !== undefined) {
    host.rustdeskDesktopFlipMode = normalizeRustDeskDesktopFlipMode(
      values['localrustdeskdesktopflipmode']);
  }
  if (values['localrustdeskprolastseenat'] !== undefined) {
    host.rustdeskProLastSeenAt = finiteNonNegative(
      values['localrustdeskprolastseenat'], host.rustdeskProLastSeenAt);
  }
  if (values['localrustdeskprosyncerror'] !== undefined) {
    host.rustdeskProSyncError = values['localrustdeskprosyncerror'];
  }
  return host;
}

/**
 * Detect whether a host edit changes anything that belongs in the cloud.
 * Existing device-local trust and secret fields are excluded together with
 * the new personalization fields, preventing a local-only edit from creating
 * a distributed mutation.
 */
export function remoteHostCloudBaseSnapshot(host: RemoteHost): string {
  const projected: RemoteHost = RemoteHost.fromJSON(host.toJSON());
  projected.displayConfig = new DisplayConfig();
  projected.lastConnected = 0;
  projected.lastHealth = 0;
  projected.lastLatency = 0;
  projected.rustdeskAdaptiveOrientation = false;
  projected.rustdeskDesktopFlipMode = 'reset';
  projected.rustdeskProLastSeenAt = 0;
  projected.rustdeskProSyncError = '';
  projected.sshKeyPassphrase = '';
  projected.sshProxyPassword = '';
  projected.sshProxyKeyPassphrase = '';
  projected.sshHostKeyAlgorithm = '';
  projected.sshHostKeyFingerprintSha256 = '';
  projected.sshHostKeyRawBase64 = '';
  projected.sshHostKeyTrustedAt = 0;
  projected.sshHostKeyTrustMode = 0;
  projected.sshJumpHostKeyAlgorithm = '';
  projected.sshJumpHostKeyFingerprintSha256 = '';
  projected.sshJumpHostKeyRawBase64 = '';
  projected.sshJumpHostKeyTrustedAt = 0;
  projected.sshJumpHostKeyTrustMode = 0;
  projected.rdpCertificateFingerprintSha256 = '';
  projected.rdpCertificateSubject = '';
  projected.rdpCertificateIssuer = '';
  projected.rdpCertificateCommonName = '';
  projected.rdpCertificateNotBeforeMs = 0;
  projected.rdpCertificateNotAfterMs = 0;
  projected.rdpCertificateTrustedAt = 0;
  projected.rdpCertificateTrustMode = 0;
  projected.rdpCertificateAllowUntrustedRoot = false;
  projected.rdpCertificateAllowHostMismatch = false;
  projected.rdpCertificateRouteIdentity = '';
  projected.rdpGatewayCertificateFingerprintSha256 = '';
  projected.rdpGatewayCertificateSubject = '';
  projected.rdpGatewayCertificateIssuer = '';
  projected.rdpGatewayCertificateCommonName = '';
  projected.rdpGatewayCertificateNotBeforeMs = 0;
  projected.rdpGatewayCertificateNotAfterMs = 0;
  projected.rdpGatewayCertificateTrustedAt = 0;
  projected.rdpGatewayCertificateTrustMode = 0;
  projected.rdpGatewayCertificateAllowUntrustedRoot = false;
  projected.rdpGatewayCertificateAllowHostMismatch = false;
  projected.rdpGatewayCertificateRouteIdentity = '';
  return JSON.stringify(projected.toJSON());
}

export function remoteHostCloudBaseChanged(before: RemoteHost, after: RemoteHost): boolean {
  return remoteHostCloudBaseSnapshot(before) !== remoteHostCloudBaseSnapshot(after);
}

export interface VncHostLocalPersonalization {
  rememberPassword: boolean;
  viewOnly: boolean;
  displayOverrideEnabled: boolean;
  scalingMode: VncScalingMode;
  clipboardEnabled: boolean;
}

function copyVncHostValues(values: VncHostValues): VncHostValues {
  return {
    label: values.label,
    host: values.host,
    port: values.port,
    username: values.username,
    gatewayId: values.gatewayId,
    transport: values.transport,
    repeaterMode: values.repeaterMode,
    rememberPassword: values.rememberPassword,
    viewOnly: values.viewOnly,
    displayOverrideEnabled: values.displayOverrideEnabled,
    scalingMode: values.scalingMode,
    clipboardEnabled: values.clipboardEnabled,
    securityPolicy: values.securityPolicy,
    tls: values.tls,
    locked: values.locked,
    lockType: values.lockType
  };
}

function validScalingMode(value: string): boolean {
  return value === 'fit' || value === 'integer' || value === 'one_to_one' || value === 'pan';
}

export function vncHostLocalPersonalizationPayload(values: VncHostValues): string {
  const payload: Record<string, Object> = {};
  payload['version'] = 1;
  payload['rememberPassword'] = values.rememberPassword;
  payload['viewOnly'] = values.viewOnly;
  payload['displayOverrideEnabled'] = values.displayOverrideEnabled;
  payload['scalingMode'] = values.scalingMode;
  payload['clipboardEnabled'] = values.clipboardEnabled;
  return JSON.stringify(payload);
}

/** Merge a local override over the legacy-compatible cloud host payload. */
export function applyVncHostLocalPersonalization(
  values: VncHostValues,
  payload: string
): VncHostValues {
  const result: VncHostValues = copyVncHostValues(values);
  if (payload.trim() === '') { return result; }
  try {
    const parsed: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
    if (parsed['version'] !== 1) { return result; }
    if (typeof parsed['rememberPassword'] === 'boolean') {
      result.rememberPassword = parsed['rememberPassword'] as boolean;
    }
    if (typeof parsed['viewOnly'] === 'boolean') {
      result.viewOnly = parsed['viewOnly'] as boolean;
    }
    if (typeof parsed['displayOverrideEnabled'] === 'boolean') {
      result.displayOverrideEnabled = parsed['displayOverrideEnabled'] as boolean;
    }
    if (typeof parsed['scalingMode'] === 'string' &&
      validScalingMode(parsed['scalingMode'] as string)) {
      result.scalingMode = parsed['scalingMode'] as VncScalingMode;
    }
    if (typeof parsed['clipboardEnabled'] === 'boolean') {
      result.clipboardEnabled = parsed['clipboardEnabled'] as boolean;
    }
  } catch (_err) {
    // Legacy cloud values remain authoritative when local state is corrupt.
  }
  return result;
}

/**
 * Preserve old cloud personalization during an update. New hosts still write
 * a complete legacy payload once so 1.0.7/1.0.8 clients can open the row.
 */
export function vncHostCloudValuesForSave(
  next: VncHostValues,
  previousCloud: VncHostValues | null
): VncHostValues {
  const result: VncHostValues = copyVncHostValues(next);
  if (previousCloud === null) { return result; }
  result.rememberPassword = previousCloud.rememberPassword;
  result.viewOnly = previousCloud.viewOnly;
  result.displayOverrideEnabled = previousCloud.displayOverrideEnabled;
  result.scalingMode = previousCloud.scalingMode;
  result.clipboardEnabled = previousCloud.clipboardEnabled;
  return result;
}
