import { describe, it, expect } from '@ohos/hypium';
import {
  relayDeleteMessage,
  relayDirectoryEntry,
  relayDirectoryMatchesFilter,
  relayDirectoryOwner,
  relayProbeToast,
  relaySaveStageLabel,
  summarizeRustDeskRelayProbe,
  vncGatewayCheckMessage
} from '../main/ets/services/RelayDirectoryPolicy';

export default function relayDirectoryPolicyTest(): void {
  describe('RelayDirectoryPolicy', (): void => {
    it('filters_protocols_without_mixing_owners', 0, (): void => {
      expect(relayDirectoryMatchesFilter('rustdesk', 'vnc')).assertFalse();
      expect(relayDirectoryMatchesFilter('vnc', 'all')).assertTrue();
      expect(relayDirectoryOwner('vnc')).assertEqual('VncGatewayService/vncrecord');
      expect(relayDirectoryOwner('rustdesk')).assertEqual('HostSyncService/rustdeskrelays');
    });

    it('keeps_gateway_entry_non_sensitive_and_read_only', 0, (): void => {
      const entry = relayDirectoryEntry('vnc', 'gateway-1', 'Office', 'relay.example.com:5901',
        '/vnc', true, '可用');
      expect(entry.kind).assertEqual('vnc');
      expect(entry.owner).assertEqual('VncGatewayService/vncrecord');
      expect(entry.endpoint.includes('token')).assertFalse();
    });

    it('a_relay_test_needs_both_endpoints', 0, (): void => {
      expect(summarizeRustDeskRelayProbe(true, 20, true, 30).status).assertEqual('online');
      expect(summarizeRustDeskRelayProbe(true, 20, true, 30).latency).assertEqual(30);
      expect(summarizeRustDeskRelayProbe(false, 0, true, 30).status).assertEqual('error');
      expect(summarizeRustDeskRelayProbe(true, 20, false, 0).detail).assertEqual('ID 服务器可达，中继服务器不可达');
      expect(summarizeRustDeskRelayProbe(false, 0, false, 0).status).assertEqual('offline');
      expect(relayProbeToast(summarizeRustDeskRelayProbe(true, 20, true, 30))).assertEqual('中继在线 · 30ms');
    });

    it('speaks_plain_words', 0, (): void => {
      expect(relaySaveStageLabel('waiting_gate')).assertEqual('正在等待本地数据就绪…');
      expect(relayDeleteMessage(2, 1).includes('2 台主机')).assertTrue();
      expect(vncGatewayCheckMessage('E-VNC-GATEWAY-TCP', '')).assertEqual('网关端口连不上，请检查地址、端口和网络');
      expect(vncGatewayCheckMessage('E-VNC-RFB-BANNER', 'RFB banner 无效')).assertEqual('VNC 响应无效');
    });
  });
}
