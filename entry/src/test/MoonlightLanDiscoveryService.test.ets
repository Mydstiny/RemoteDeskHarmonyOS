/** Moonlight API 23 mDNS discovery, resolve and lifecycle tests. */

import { common } from '@kit.AbilityKit';
import { mdns } from '@kit.NetworkKit';
import { describe, it, expect } from '@ohos/hypium';
import { MoonlightAddress } from '../main/ets/model/MoonlightModels';
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
import {
  MoonlightHostOperationFence,
  createMoonlightHostOperationFence,
  moonlightHostOperationFenceEquals,
  moonlightServerInfoProbeEndpoint,
  moonlightVerificationUuidHint,
  moonlightVerificationMatchesFence,
  parseMoonlightServerInfo
} from '../main/ets/services/MoonlightLanProbeService';

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
  reject: (reason: Error) => void;
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
    return new Promise<mdns.LocalServiceInfo>((resolve: (value: mdns.LocalServiceInfo) => void,
      reject: (reason: Error) => void): void => {
      this.pending.push({ resolve: resolve, reject: reject });
    });
  }

  resolveAt(index: number, serviceInfo: mdns.LocalServiceInfo): void {
    this.pending[index].resolve(serviceInfo);
  }

  rejectAt(index: number): void {
    this.pending[index].reject(new Error('transient resolve failure'));
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

    it('retries_one_transient_mdns_resolve_failure_within_the_same_scan', 0,
      async (): Promise<void> => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const results: Array<MoonlightLanDiscoveryCandidate> = [];
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port);
        service.start('owner-a', 5, (candidate: MoonlightLanDiscoveryCandidate): void => {
          results.push(candidate);
        });

        port.discoveries[0].emitFound(serviceInfo('Gaming PC'));
        port.rejectAt(0);
        await settleMicrotasks();
        expect(port.requests.length).assertEqual(2);
        port.resolveAt(1, resolvedInfo('Gaming PC', '192.168.1.20', 47989, 'sunshine-1'));
        await settleMicrotasks();

        expect(results.length).assertEqual(1);
        expect(results[0].serverUuid).assertEqual('sunshine-1');
        service.stop();
      });

    it('tombstones_a_service_after_permanent_resolve_failure', 0,
      async (): Promise<void> => {
        const port: FakeMoonlightMdnsPort = new FakeMoonlightMdnsPort();
        const service: MoonlightLanDiscoveryService = new MoonlightLanDiscoveryService(
          undefined as common.Context, port, { maxResults: 2 });
        service.start('owner-a', 6, (_candidate: MoonlightLanDiscoveryCandidate): void => {});
        const discovery: FakeMoonlightMdnsDiscovery = port.discoveries[0];

        discovery.emitFound(serviceInfo('always-fails'));
        port.rejectAt(0);
        await settleMicrotasks();
        port.rejectAt(1);
        await settleMicrotasks();
        discovery.emitFound(serviceInfo('always-fails'));

        expect(port.requests.length).assertEqual(2);
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
        expect(service.acceptedResultCount()).assertEqual(0);

        port.resolveAt(0, resolvedInfo('one', '192.168.1.20', 47989, 'same-server'));
        port.resolveAt(1, resolvedInfo('two', '192.168.1.20', 47989, 'same-server'));
        await settleMicrotasks();
        expect(results.length).assertEqual(1);
        expect(service.acceptedResultCount()).assertEqual(1);
        discovery.emitFound(serviceInfo('one'));
        expect(port.requests.length).assertEqual(2);
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

      const resolved: mdns.LocalServiceInfo = resolvedInfo(
        'Gaming PC', 'fe80::20%wlan0', 47989);
      const candidate: MoonlightLanDiscoveryCandidate | null =
        resolveMoonlightLanCandidate(firstFence, discovered, resolved);
      expect(candidate === null).assertFalse();
      if (candidate !== null) {
        expect(candidate.family).assertEqual('ipv6');
        expect(candidate.host).assertEqual('fe80::20');
        expect(candidate.scope).assertEqual('wlan0');
        expect(candidate.interfaceName).assertEqual('wlan0');
        expect(candidate.generation).assertEqual(1);
      }
      expect(resolveMoonlightLanCandidate(firstFence, discovered,
        resolvedInfo('Gaming PC', 'fe80::20', 47989)) === null).assertTrue();
    });

    it('requires_mdns_and_serverinfo_uuid_to_match_without_truncation', 0, (): void => {
      const address: MoonlightAddress = {
        host: '192.168.1.20', family: 'ipv4', port: 47989
      };
      const matching: string = '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<hostname>Gaming PC</hostname><appversion>1.0</appversion></root>';
      const accepted = parseMoonlightServerInfo(matching, address, 'sunshine-1');
      expect(accepted === null).assertFalse();
      if (accepted !== null) {
        expect(accepted.serverUuid).assertEqual('sunshine-1');
        expect(accepted.serverName).assertEqual('Gaming PC');
      }
      expect(parseMoonlightServerInfo(matching, address, 'another-host') === null).assertTrue();

      const prefix: string = 'a'.repeat(255);
      const collisionA: string = prefix + 'a';
      const collisionB: string = prefix + 'b';
      const boundedBody: string = '<root status_code="200"><uniqueid>' + collisionA +
        '</uniqueid></root>';
      expect(parseMoonlightServerInfo(boundedBody, address, collisionB) === null).assertTrue();
      const oversizedBody: string = '<root status_code="200"><uniqueid>' +
        'u'.repeat(257) + '</uniqueid></root>';
      expect(parseMoonlightServerInfo(oversizedBody, address, '') === null).assertTrue();
      expect(parseMoonlightServerInfo(
        '<root status_code="200"></root>', address, 'u'.repeat(257)) === null).assertTrue();
    });

    it('treats_only_the_scan_address_fallback_as_a_non_authoritative_uuid_hint', 0,
      (): void => {
        const address: MoonlightAddress = {
          host: '192.168.1.20', family: 'ipv4', port: 47989
        };
        expect(moonlightVerificationUuidHint(address, '192.168.1.20:47989'))
          .assertEqual('');
        expect(moonlightVerificationUuidHint(address, '192.168.1.20:48000'))
          .assertEqual('192.168.1.20:48000');
        expect(moonlightVerificationUuidHint(address, 'sunshine-1'))
          .assertEqual('sunshine-1');
        expect(moonlightVerificationUuidHint({
          host: '2001:db8::20', family: 'ipv6', port: 47989
        }, '[2001:db8::20]:47989')).assertEqual('');

        const hint: string = moonlightVerificationUuidHint(
          address, '192.168.1.20:47989');
        const verification = parseMoonlightServerInfo(
          '<root status_code="200"><uniqueid>sunshine-real-uuid</uniqueid></root>',
          address, hint);
        const fence: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 7, 'owner-a', 3, hint, address);
        expect(verification === null).assertFalse();
        expect(fence === null).assertFalse();
        if (verification !== null && fence !== null) {
          expect(moonlightVerificationMatchesFence(verification, fence)).assertTrue();
        }
      });

    it('reads_official_serverinfo_pair_status_before_pairing_response_fallback', 0, (): void => {
      const address: MoonlightAddress = {
        host: '192.168.1.20', family: 'ipv4', port: 47989
      };
      const official = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<PairStatus>1</PairStatus></root>', address, 'sunshine-1');
      expect(official === null).assertFalse();
      if (official !== null) {
        expect(official.paired).assertTrue();
      }

      const compatibility = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<paired>true</paired></root>', address, 'sunshine-1');
      expect(compatibility === null).assertFalse();
      if (compatibility !== null) {
        expect(compatibility.paired).assertTrue();
      }

      const officialWins = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<PairStatus>0</PairStatus><paired>1</paired></root>', address, 'sunshine-1');
      expect(officialWins === null).assertFalse();
      if (officialWins !== null) {
        expect(officialWins.paired).assertFalse();
      }

      const sunshine = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<GfeVersion>3.23.0.74</GfeVersion><state>SUNSHINE_SERVER_FREE</state></root>',
        address, 'sunshine-1');
      expect(sunshine === null).assertFalse();
      if (sunshine !== null) {
        expect(sunshine.hostType).assertEqual('sunshine');
      }
      const legacyGameStream = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>gamestream-1</uniqueid>' +
        '<GfeVersion>3.23.0.74</GfeVersion><state>SERVER_FREE</state></root>',
        address, 'gamestream-1');
      expect(legacyGameStream === null).assertFalse();
      if (legacyGameStream !== null) {
        expect(legacyGameStream.hostType).assertEqual('gamestream');
      }

      const customHttpsPort = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<HttpsPort>48084</HttpsPort></root>', address, 'sunshine-1');
      expect(customHttpsPort === null).assertFalse();
      if (customHttpsPort !== null) {
        expect(customHttpsPort.httpsPort).assertEqual(48084);
      }

      const legacyDefault = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid></root>',
        address, 'sunshine-1');
      expect(legacyDefault === null).assertFalse();
      if (legacyDefault !== null) {
        expect(legacyDefault.httpsPort).assertEqual(47984);
      }

      expect(parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<HttpsPort>abc</HttpsPort></root>', address, 'sunshine-1') === null).assertTrue();
      expect(parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<HttpsPort>0</HttpsPort></root>', address, 'sunshine-1') === null).assertTrue();
      expect(parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>sunshine-1</uniqueid>' +
        '<HttpsPort>65536</HttpsPort></root>', address, 'sunshine-1') === null).assertTrue();
    });

    it('builds_the_official_serverinfo_query_for_ipv4_and_ipv6', 0, (): void => {
      const requestUuid: string = '12345678-1234-4abc-8def-1234567890ab';
      expect(moonlightServerInfoProbeEndpoint({
        host: '192.168.1.20', family: 'ipv4', port: 47989
      }, requestUuid)).assertEqual(
        'http://192.168.1.20:47989/serverinfo?uniqueid=0123456789ABCDEF&uuid=' + requestUuid);
      expect(moonlightServerInfoProbeEndpoint({
        host: '2001:db8::20', family: 'ipv6', port: 48089
      }, requestUuid)).assertEqual(
        'http://[2001:db8::20]:48089/serverinfo?uniqueid=0123456789ABCDEF&uuid=' + requestUuid);
      expect(moonlightServerInfoProbeEndpoint({
        host: 'sunshine.local', family: 'hostname', port: 47989
      }, 'invalid')).assertEqual('');
    });

    it('rejects_control_characters_and_accepts_only_exact_operation_fences', 0, (): void => {
      const address: MoonlightAddress = {
        host: 'sunshine.local', family: 'hostname', port: 47989
      };
      const controlUuid: string = '<root status_code="200"><uniqueid>host\u0001</uniqueid></root>';
      const encodedControl: string =
        '<root status_code="200"><uniqueid>host&#10;</uniqueid></root>';
      expect(parseMoonlightServerInfo(controlUuid, address, '') === null).assertTrue();
      expect(parseMoonlightServerInfo(encodedControl, address, '') === null).assertTrue();
      expect(parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>host</uniqueid></root>',
        address, 'host\u0001') === null).assertTrue();

      const verification = parseMoonlightServerInfo(
        '<root status_code="200"><uniqueid>host</uniqueid></root>', address, 'host');
      const current: MoonlightHostOperationFence | null =
        createMoonlightHostOperationFence(11, 7, 'owner-a', 3, 'host', address);
      expect(verification === null).assertFalse();
      expect(current === null).assertFalse();
      if (verification !== null && current !== null) {
        expect(moonlightVerificationMatchesFence(verification, current)).assertTrue();
        const ownerChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(12, 7, 'owner-a', 3, 'host', address);
        const generationChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 8, 'owner-a', 3, 'host', address);
        const scopeChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 7, 'owner-b', 3, 'host', address);
        const accountGenerationChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 7, 'owner-a', 4, 'host', address);
        const uuidChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 7, 'owner-a', 3, 'other-host', address);
        const addressChanged: MoonlightHostOperationFence | null =
          createMoonlightHostOperationFence(11, 7, 'owner-a', 3, 'host', {
            host: address.host, family: address.family, port: 47990
          });
        expect(moonlightHostOperationFenceEquals(current, ownerChanged)).assertFalse();
        expect(moonlightHostOperationFenceEquals(current, generationChanged)).assertFalse();
        expect(moonlightHostOperationFenceEquals(current, scopeChanged)).assertFalse();
        expect(moonlightHostOperationFenceEquals(current, accountGenerationChanged)).assertFalse();
        expect(moonlightHostOperationFenceEquals(current, uuidChanged)).assertFalse();
        expect(moonlightHostOperationFenceEquals(current, addressChanged)).assertFalse();
        if (uuidChanged !== null) {
          expect(moonlightVerificationMatchesFence(verification, uuidChanged)).assertFalse();
        }
        if (addressChanged !== null) {
          expect(moonlightVerificationMatchesFence(verification, addressChanged)).assertFalse();
        }
      }
    });
  });
}
