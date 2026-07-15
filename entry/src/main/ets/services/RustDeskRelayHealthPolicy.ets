import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';

/**
 * Create a fresh selected-relay object from the current list entry.
 *
 * Relay health is updated on the service-owned config object. The PC detail
 * panel keeps its own @State reference, so replacing that reference is
 * required for ArkUI to render the new latency and status immediately.
 */
export function snapshotSelectedRelay(
  relays: RustDeskRelayConfig[],
  selectedRelayId: string
): RustDeskRelayConfig | null {
  const source = relays.find((relay: RustDeskRelayConfig): boolean => relay.id === selectedRelayId);
  return source ? RustDeskRelayConfig.fromJSON(source.toJSON()) : null;
}
