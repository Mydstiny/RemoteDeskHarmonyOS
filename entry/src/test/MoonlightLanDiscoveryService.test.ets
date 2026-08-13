/** Moonlight API 23 mDNS discovery, resolve and lifecycle tests. */

import { common } from '@kit.AbilityKit';
import { mdns } from '@kit.NetworkKit';
import { describe, it, expect } from '@ohos/hypium';
import {
  MOONLIGHT_MDNS_SERVICE_TYPE,
  MoonlightLanDiscoveryCandidate,
  MoonlightLanDiscoveryFence,
  MoonlightLanMdnsPort,
  MoonlightMdnsDiscovery,
  MoonlightMdnsDiscoveryStartCallback,
  MoonlightMdnsServiceCallback,
  MoonlightLanDiscoveryService,
  moonlightLanDiscoveryFenceEquals,
  resolveMoonlightLanCandidate
} from '../main/ets/services/MoonlightLanDiscoveryService';

class FakeMoonlightMdnsDiscovery implements MoonlightMdnsDiscovery {
  private discoveryStartCallback: MoonlightMdnsDiscoveryStartCallback | null = null;
  private serviceFoundCallback: MoonlightMdnsServiceCallback | null = null;
  private serviceLostCallback: MoonlightMdnsServiceCallback | null = null;
  private lastServiceFoundCallback: MoonlightMdnsServiceCallback | null = null;
  private lastServiceLostCallback: MoonlightMdnsServiceCallback | null = null;
  startCount: number = 0;
  stopCount: number = 0;
  offDiscoveryStartCount: number = 0;
  offServiceFoundCount: number = 0;
  offServiceLostCount: number = 0;

  onDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void {
    this.discoveryStartCallback = callback;
  }

  offDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void {
    this.offDiscoveryStartCount++;
    if (this.discoveryStartCallback === callback) {
      this.discoveryStartCallback = null;
    }
  }

  onServiceFound(callback: MoonlightMdnsServiceCallback): void {
    this.serviceFoundCallback = callback;
    this.lastServiceFoundCallback = callback;
  }

  offServiceFound(callback: MoonlightMdnsServiceCallback): void {
    this.offServiceFoundCount++;
    if (this.serviceFoundCallback === callback) {
      this.serviceFoundCallback = null;
    }
  }

  onServiceLost(callback: MoonlightMdnsServiceCallback): void {
    this.serviceLostCallback = callback;
    this.lastServiceLostCallback = callback;
  }

  offServiceLost(callback: MoonlightMdnsServiceCallback): void {
    this.offServiceLostCount++;
    if (this.serviceLostCallback === callback) {
      this.serviceLostCallback = null;
    }
  }

  startSearching(): void {
    this.startCount++;
  }

  stopSearching(): void {
    this.stopCount++;
  }

  emitFound(serviceInfo: mdns.LocalServiceInfo): void {
    if (this.serviceFoundCallback !== null) {
      this.serviceFoundCallback(serviceInfo);
    }
  }

  emitLateFound(serviceInfo: mdns.LocalServiceInfo): void {
    if (this.lastServiceFoundCallback !== null) {
      this.lastServiceFoundCallback(serviceInfo);
    }
  }

  emitLateLost(serviceInfo: mdns.LocalServiceInfo): void {
    if (this.lastServiceLostCallback !== null) {
      this.lastServiceLostCallback(serviceInfo);
    }
  }
}

interface PendingResolve {
  resolve: (serviceInfo: mdns.LocalServiceInfo) => void;
}

class FakeMoonlightMdnsPort implements MoonlightLanMdnsPort {
  readonly discoveries: Array<FakeMoonlightMdnsDiscovery> = [];
  readonly requests: Array<mdns.LocalServiceInfo> = [];
  readonly pending: Array<PendingResolve> = [];
  createCount: number = 0;
  lastServiceType: string = '';

  createDiscoveryService(_context: common.Context, serviceType: string): MoonlightMdnsDiscovery {
    this.createCount++;
    this.lastServiceType = serviceType;
    const discovery: FakeMoonlightMdnsDiscovery = new FakeMoonlightMdnsDiscovery();
    this.discoveries.push(discovery);
    return discovery;
  }

  resolveLocalService(_context: common.Context,
    serviceInfo: mdns.LocalServiceInfo): Promise<mdns.LocalServiceInfo> {
    this.requests.push(serviceInfo);
    return new Promise<mdns.LocalServiceInfo>((resolve: (value: mdns.LocalServiceInfo) => void): void => {
      this.pending.push({ resolve: resolve });
    });
  }

  resolveAt(index: number, serviceInfo: mdns.LocalServiceInfo): void {
    this.pending[index].resolve(serviceInfo);
  }
}

function serviceInfo(name: string, serviceType: string = MOONLIGHT_MDNS_SERVICE_TYPE,
  address: string = '', port: number = 0): mdns.LocalServiceInfo {
  const info: mdns.LocalServiceInfo = {
    serviceType: serviceType,
    serviceName: name
  };
  if (address !== '') {
    info.host = { address: address, family: address.indexOf(':') >= 0 ? 2 : 1 };
  }
  if (port > 0) {
    info.port = port;
  }
  return info;
}

function ascii(value: string): Array<number> {
  const bytes: Array<number> = [];
  for (let index = 0; index < value.length; index++) {
    bytes.push(value.charCodeAt(index));
  }
  return bytes;
}

function resolvedInfo(name: string, address: string = '192.168.1.20',
  port: number = 47989, serverUuid: string = ''): mdns.LocalServiceInfo {
  const info: mdns.LocalServiceInfo = serviceInfo(name, MOONLIGHT_MDNS_SERVICE_TYPE, address, port);
  if (serverUuid !== '') {
    info.serviceAttribute = [{ key: 'uuid', value: ascii(serverUuid) }];
  }
  return info;
}

async function settleMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

export default function moonlightLanDiscoveryServiceTest(): void {
  describe('MoonlightLanDiscoveryService', (): void => {
    it('uses_api23_mdns_type_and_publishes_only_resolved_candidates', 0,
      async (): Promise<void> => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const results: Array<MoonlightLanDiscoveryCandidate> = [];
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port);

        expect(service.start('owner-a', 4, (candidate: MoonlightLanDiscoveryCandidate): void => {
          results.push(candidate);
        })).assertTrue();
        expect(port.lastServiceType).assertEqual(MOONLIGHT_MDNS_SERVICE_TYPE);
        expect(port.discoveries[0].startCount).assertEqual(1);

        port.discoveries[0].emitFound(serviceInfo('Gaming PC'));
        expect(port.requests.length).assertEqual(1);
        expect(results.length).assertEqual(0);
        port.resolveAt(0, resolvedInfo('Gaming PC', '192.168.1.20', 47989, 'sunshine-1'));
        await settleMicrotasks();

        expect(results.length).assertEqual(1);
        expect(results[0].ownerId).assertEqual('owner-a');
        expect(results[0].generation).assertEqual(4);
        expect(results[0].serviceName).assertEqual('Gaming PC');
        expect(results[0].serverUuid).assertEqual('sunshine-1');
        expect(results[0].host).assertEqual('192.168.1.20');
        expect(results[0].family).assertEqual('ipv4');
        expect(results[0].port).assertEqual(47989);
        service.stop();
      });

    it('deduplicates_service_instances_and_enforces_a_result_bound', 0,
      async (): Promise<void> => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const results: Array<MoonlightLanDiscoveryCandidate> = [];
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port, { maxResults: 2 });
        service.start('owner-a', 1, (candidate: MoonlightLanDiscoveryCandidate): void => {
          results.push(candidate);
        });

        const discovery: FakeMoonlightMdnsDiscovery = port.discoveries[0];
        discovery.emitFound(serviceInfo('one'));
        discovery.emitFound(serviceInfo('one'));
        discovery.emitFound(serviceInfo('two'));
        discovery.emitFound(serviceInfo('three'));
        expect(port.requests.length).assertEqual(2);
        expect(service.acceptedResultCount()).assertEqual(2);

        port.resolveAt(0, resolvedInfo('one', '192.168.1.20', 47989, 'same-server'));
        port.resolveAt(1, resolvedInfo('two', '192.168.1.20', 47989, 'same-server'));
        await settleMicrotasks();
        expect(results.length).assertEqual(1);
        service.stop();
      });

    it('fences_late_resolve_and_native_callbacks_by_owner_and_generation', 0,
      async (): Promise<void> => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const results: Array<MoonlightLanDiscoveryCandidate> = [];
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port);
        service.start('owner-a', 7, (candidate: MoonlightLanDiscoveryCandidate): void => {
          results.push(candidate);
        });
        const firstDiscovery: FakeMoonlightMdnsDiscovery = port.discoveries[0];
        firstDiscovery.emitFound(serviceInfo('old-host'));
        service.stop();
        port.resolveAt(0, resolvedInfo('old-host', '192.168.1.21', 47989, 'old'));
        await settleMicrotasks();
        expect(results.length).assertEqual(0);

        service.start('owner-b', 8, (candidate: MoonlightLanDiscoveryCandidate): void => {
          results.push(candidate);
        });
        const secondDiscovery: FakeMoonlightMdnsDiscovery = port.discoveries[1];
        firstDiscovery.emitLateFound(serviceInfo('late-old-host'));
        expect(port.requests.length).assertEqual(1);
        secondDiscovery.emitFound(serviceInfo('new-host'));
        port.resolveAt(1, resolvedInfo('new-host', '192.168.1.22', 47989, 'new'));
        await settleMicrotasks();

        expect(results.length).assertEqual(1);
        expect(results[0].ownerId).assertEqual('owner-b');
        expect(results[0].generation).assertEqual(8);
        expect(results[0].serviceName).assertEqual('new-host');
        service.stop();
      });

    it('unregisters_all_callbacks_clears_state_and_blocks_late_lost_events', 0,
      (): void => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port);
        service.start('owner-a', 2, (_candidate: MoonlightLanDiscoveryCandidate): void => {});
        const discovery: FakeMoonlightMdnsDiscovery = port.discoveries[0];
        discovery.emitFound(serviceInfo('host'));
        service.stop();

        expect(service.isRunning()).assertFalse();
        expect(service.currentFence() === null).assertTrue();
        expect(service.acceptedResultCount()).assertEqual(0);
        expect(discovery.offDiscoveryStartCount).assertEqual(1);
        expect(discovery.offServiceFoundCount).assertEqual(1);
        expect(discovery.offServiceLostCount).assertEqual(1);
        expect(discovery.stopCount).assertEqual(1);
        discovery.emitLateFound(serviceInfo('late-host'));
        discovery.emitLateLost(serviceInfo('late-host'));
        expect(service.acceptedResultCount()).assertEqual(0);
      });

    it('rejects_cross_service_resolves_and_keeps_the_fence_exact', 0, (): void => {
      const firstFence: MoonlightLanDiscoveryFence = { ownerId: 'owner-a', generation: 1 };
      const secondFence: MoonlightLanDiscoveryFence = { ownerId: 'owner-a', generation: 2 };
      expect(moonlightLanDiscoveryFenceEquals(firstFence, firstFence)).assertTrue();
      expect(moonlightLanDiscoveryFenceEquals(firstFence, secondFence)).assertFalse();

      const discovered: mdns.LocalServiceInfo = serviceInfo('Gaming PC');
      const mismatched: mdns.LocalServiceInfo = resolvedInfo('Other PC');
      expect(resolveMoonlightLanCandidate(firstFence, discovered, mismatched) === null).assertTrue();

      const resolved: mdns.LocalServiceInfo = resolvedInfo('Gaming PC', 'fe80::20', 47989);
      const candidate: MoonlightLanDiscoveryCandidate | null =
        resolveMoonlightLanCandidate(firstFence, discovered, resolved);
      expect(candidate === null).assertFalse();
      if (candidate !== null) {
        expect(candidate.family).assertEqual('ipv6');
        expect(candidate.generation).assertEqual(1);
      }
    });
  });
}
