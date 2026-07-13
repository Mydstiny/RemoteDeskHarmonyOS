/**
 * RustDeskHostConfigPolicy — RustDesk host add/edit pure rules
 */
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';

export interface RustDeskHostEndpoint {
  host: string;
  port: number;
}

export function normalizeRustDeskPort(port: number): number {
  return port > 0 && port <= 65535 ? port : 21116;
}

export function resolveRustDeskHostEndpoint(relay: RustDeskRelayConfig | null, fallbackHost: string,
  directEnabled: boolean, directHost: string, directPort: number): RustDeskHostEndpoint {
  if (directEnabled) {
    return {
      host: directHost.trim(),
      port: normalizeRustDeskPort(directPort)
    };
  }
  if (relay !== null) {
    return {
      host: relay.idServer.trim(),
      port: normalizeRustDeskPort(relay.idServerPort)
    };
  }
  return {
    host: fallbackHost.trim(),
    port: 21116
  };
}
