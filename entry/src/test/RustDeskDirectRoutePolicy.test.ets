import { describe, expect, it } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
  rustDeskDirectAddressClass,
  rustDeskDirectAddressClassCode,
  rustDeskDirectSourceCode,
  rustDeskDirectEndpointReadbackError,
  rustDeskDirectEndpointSource,
  rustDeskDirectFailureMessage,
  rustDeskDirectFailureStage,
  rustDeskDirectStageCode
} from '../main/ets/services/RustDeskDirectRoutePolicy';

function directHost(address: string, port: number): RemoteHost {
  const host: RemoteHost = new RemoteHost();
  host.protocol = 'rustdesk';
  host.rustdeskDirectEnabled = true;
  host.rustdeskDirectHost = address;
  host.rustdeskDirectPort = port;
  host.host = address;
  host.port = port;
  host.rustdeskRelayId = '';
  return host;
}

export default function rustDeskDirectRoutePolicyTest(): void {
  describe('RustDeskDirectRoutePolicy', () => {
    it('separates manual/overlay addresses from LAN discovery without guessing the overlay', 0, () => {
      const manual: RemoteHost = directHost('10.126.126.5', 21118);
      expect(rustDeskDirectEndpointSource(manual)).assertEqual('manual_direct');
      const discovered: RemoteHost = directHost('192.168.1.20', 21118);
      discovered.lanDiscoveryIdentity = '123456789';
      discovered.lanAddressMode = 'static';
      expect(rustDeskDirectEndpointSource(discovered)).assertEqual('lan_discovery');
      // A discovery identity without a static/dynamic address policy is not a discovery record.
      discovered.lanAddressMode = 'manual';
      expect(rustDeskDirectEndpointSource(discovered)).assertEqual('manual_direct');
      const relay: RemoteHost = directHost('', 21118);
      relay.rustdeskDirectEnabled = false;
      expect(rustDeskDirectEndpointSource(relay)).assertEqual('relay');
    });

    it('reduces endpoints to closed address classes', 0, () => {
      expect(rustDeskDirectAddressClass('10.126.126.5', 21118)).assertEqual('ipv4_private');
      expect(rustDeskDirectAddressClass('192.168.3.4', 21118)).assertEqual('ipv4_private');
      expect(rustDeskDirectAddressClass('172.20.0.1', 21118)).assertEqual('ipv4_private');
      expect(rustDeskDirectAddressClass('100.100.1.2', 21118)).assertEqual('ipv4_shared');
      expect(rustDeskDirectAddressClass('8.8.8.8', 21118)).assertEqual('ipv4_public');
      expect(rustDeskDirectAddressClass('127.0.0.1', 21118)).assertEqual('ipv4_loopback');
      expect(rustDeskDirectAddressClass('fd00:1::5', 21118)).assertEqual('ipv6_unique_local');
      expect(rustDeskDirectAddressClass('2001:db8::1', 21118)).assertEqual('ipv6_global');
      expect(rustDeskDirectAddressClass('pc.example.com', 21118)).assertEqual('hostname');
      expect(rustDeskDirectAddressClass('not an address', 21118)).assertEqual('invalid');
    });

    it('splits native direct failures into TCP, login and first-frame stages', 0, () => {
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=direct_peer_connect_failed|attempt=3|detail=connection stage timed out'))
        .assertEqual('tcp_timeout');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=direct_peer_connect_failed|attempt=3|detail=connection stage was refused'))
        .assertEqual('tcp_refused');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=direct_peer_connect_failed|attempt=3|detail=connection endpoint is unavailable'))
        .assertEqual('tcp_unreachable');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=direct_peer_connect_failed|attempt=3|detail=connection configuration is invalid'))
        .assertEqual('input');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_login|code=peer_password_rejected|attempt=3|detail=remote device rejected the device password'))
        .assertEqual('login_password');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_login|code=peer_password_required|attempt=3|detail=x')).assertEqual('login_rejected');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_login|code=peer_login_failed|attempt=3|detail=x')).assertEqual('login_failed');
      // An authentication code wins over the native state that reported it.
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=peer_password_rejected|attempt=3|detail=x')).assertEqual('login_password');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=peer_password_required|attempt=3|detail=x')).assertEqual('login_rejected');
      expect(rustDeskDirectFailureStage(
        'RDERR|stage=peer_channel|code=cancelled|attempt=3|detail=connection attempt was cancelled'))
        .assertEqual('cancelled');
      expect(rustDeskDirectFailureStage('[E-RUSTDESK-FIRST-FRAME] no video')).assertEqual('first_frame');
      expect(rustDeskDirectFailureStage('连接失败 -2')).assertEqual('unknown');
      // These codes are documented for the AI glossary; they must stay stable.
      expect(rustDeskDirectStageCode('unknown')).assertEqual(0);
      expect(rustDeskDirectStageCode('validation')).assertEqual(1);
      expect(rustDeskDirectStageCode('tcp_timeout')).assertEqual(3);
      expect(rustDeskDirectStageCode('tcp_unreachable')).assertEqual(5);
      expect(rustDeskDirectStageCode('first_frame')).assertEqual(11);
      expect(rustDeskDirectStageCode('connected')).assertEqual(13);
      expect(rustDeskDirectSourceCode('relay')).assertEqual(0);
      expect(rustDeskDirectSourceCode('manual_direct')).assertEqual(1);
      expect(rustDeskDirectSourceCode('lan_discovery')).assertEqual(2);
      expect(rustDeskDirectAddressClassCode('invalid')).assertEqual(0);
      expect(rustDeskDirectAddressClassCode('ipv4_private')).assertEqual(2);
      expect(rustDeskDirectAddressClassCode('ipv6_unique_local')).assertEqual(7);
      expect(rustDeskDirectAddressClassCode('ipv6_global')).assertEqual(10);
      expect(rustDeskDirectAddressClassCode('not_applicable')).assertEqual(11);
    });

    it('explains the failed layer and never blames the overlay network for login or video', 0, () => {
      expect(rustDeskDirectFailureMessage('tcp_refused', 21119).indexOf('21119') >= 0).assertTrue();
      expect(rustDeskDirectFailureMessage('tcp_timeout', 21118).indexOf('虚拟组网') >= 0).assertTrue();
      expect(rustDeskDirectFailureMessage('login_password', 21118).indexOf('虚拟组网') < 0).assertTrue();
      expect(rustDeskDirectFailureMessage('first_frame', 21118).indexOf('与直连网络无关') >= 0).assertTrue();
      expect(rustDeskDirectFailureMessage('unknown', 21118)).assertEqual('');
    });

    it('rejects a saved direct record whose endpoint does not read back', 0, () => {
      const expected: RemoteHost = directHost('10.126.126.5', 21119);
      expect(rustDeskDirectEndpointReadbackError(expected, directHost('10.126.126.5', 21119)))
        .assertEqual('');
      expect(rustDeskDirectEndpointReadbackError(expected, directHost('10.126.126.5', 21118)) !== '')
        .assertTrue();
      expect(rustDeskDirectEndpointReadbackError(expected, directHost('10.126.126.6', 21119)) !== '')
        .assertTrue();
      const relayBound: RemoteHost = directHost('10.126.126.5', 21119);
      relayBound.rustdeskRelayId = 'relay-1';
      expect(rustDeskDirectEndpointReadbackError(expected, relayBound) !== '').assertTrue();
      expect(rustDeskDirectEndpointReadbackError(expected, undefined) !== '').assertTrue();
      const relayHost: RemoteHost = directHost('', 21118);
      relayHost.rustdeskDirectEnabled = false;
      expect(rustDeskDirectEndpointReadbackError(relayHost, undefined)).assertEqual('');
    });
  });
}
