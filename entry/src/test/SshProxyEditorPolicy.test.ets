import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
  SshProxyEditorValue,
  applySshProxyProfileToLegacyHost,
  buildSshProxyProfile,
  defaultSshProxyEditorValue,
  defaultSshProxyHop
} from '../main/ets/services/SshProxyEditorPolicy';

export default function sshProxyEditorPolicyTest(): void {
  describe('SshProxyEditorPolicy', (): void => {
    it('builds_http_socks_and_external_frp_tcp_endpoints_without_secrets', 0, (): void => {
      const value: SshProxyEditorValue = defaultSshProxyEditorValue();
      value.kind = 'http_connect';
      value.proxyHost = 'proxy.example';
      value.proxyPortText = '8080';
      value.proxyUsername = 'proxy-user';
      value.proxyAuthRequired = true;
      const http = buildSshProxyProfile('host-a', 'target.example', 22, value);
      expect(http.valid).assertTrue();
      expect(http.profile?.proxyHost).assertEqual('proxy.example');
      expect(http.profile?.proxyAuthRequired).assertTrue();
      expect(JSON.stringify(http.profile).indexOf('password')).assertEqual(-1);
      value.kind = 'socks5';
      value.proxyPortText = '1080';
      expect(buildSshProxyProfile('host-a', 'target.example', 22, value).valid).assertTrue();

      value.kind = 'http_connect';
      value.proxyHost = '[2001:0DB8:0:0:0:0:0:20]';
      value.proxyPortText = '8080';
      const ipv6 = buildSshProxyProfile('host-v6', '2001:0DB8::10', 22, value);
      expect(ipv6.valid).assertTrue();
      expect(ipv6.profile?.route.endpointHost).assertEqual('2001:db8::10');
      expect(ipv6.profile?.proxyHost).assertEqual('2001:db8::20');
      value.proxyPortText = '8080junk';
      expect(buildSshProxyProfile('host-v6', '2001:db8::10', 22, value).valid).assertFalse();
      value.kind = 'frp_tcp';
      value.proxyPortText = '60022';
      value.proxyAuthRequired = false;
      value.proxyUsername = '';
      expect(buildSshProxyProfile('host-a', 'target.example', 22, value).valid).assertTrue();
    });

    it('builds_one_to_three_ordered_jump_hops_and_rejects_a_fourth', 0, (): void => {
      const value: SshProxyEditorValue = defaultSshProxyEditorValue();
      value.kind = 'ssh_jump';
      value.hops[0].host = 'jump-1.example';
      value.hops[0].username = 'user-1';
      value.hops[0].authMethod = 'password';
      value.hops[0].expectedHostKeyFingerprintSha256 = 'SHA256:jump-1';
      for (let index: number = 1; index < 3; index++) {
        const hop = defaultSshProxyHop(index);
        hop.host = 'jump-' + (index + 1).toString() + '.example';
        hop.username = 'user-' + (index + 1).toString();
        hop.expectedHostKeyFingerprintSha256 = 'SHA256:jump-' + (index + 1).toString();
        value.hops.push(hop);
      }
      const result = buildSshProxyProfile('host-a', 'target.example', 22, value);
      expect(result.valid).assertTrue();
      expect(result.profile?.route.hops.length).assertEqual(3);
      expect(result.profile?.hopMetadata?.[2].position).assertEqual(2);
      const fourth = defaultSshProxyHop(3);
      fourth.host = 'jump-4.example';
      fourth.username = 'user-4';
      fourth.expectedHostKeyFingerprintSha256 = 'SHA256:jump-4';
      value.hops.push(fourth);
      expect(buildSshProxyProfile('host-a', 'target.example', 22, value).code)
        .assertEqual('E-SSH-PROXY-HOP-LIMIT');
    });

    it('canonicalizes_ipv6_jump_hosts_and_rejects_scoped_link_local_hops', 0, (): void => {
      const value: SshProxyEditorValue = defaultSshProxyEditorValue();
      value.kind = 'ssh_jump';
      value.hops[0].host = '[2001:0DB8::30]';
      value.hops[0].username = 'jump-user';
      value.hops[0].expectedHostKeyFingerprintSha256 = 'SHA256:jump';
      const accepted = buildSshProxyProfile('host-v6', '2001:db8::10', 22, value);
      expect(accepted.valid).assertTrue();
      expect(accepted.profile?.route.hops[0].host).assertEqual('2001:db8::30');
      value.hops[0].host = 'fe80::30%wlan0';
      expect(buildSshProxyProfile('host-v6', '2001:db8::10', 22, value).valid).assertFalse();
    });

    it('keeps_legacy_flat_fields_additive_and_secret_free', 0, (): void => {
      const value: SshProxyEditorValue = defaultSshProxyEditorValue();
      value.kind = 'ssh_jump';
      value.hops[0].host = 'jump.example';
      value.hops[0].username = 'jump-user';
      value.hops[0].expectedHostKeyFingerprintSha256 = 'SHA256:jump';
      const result = buildSshProxyProfile('host-a', 'target.example', 22, value);
      const host: RemoteHost = new RemoteHost();
      applySshProxyProfileToLegacyHost(host, result.profile!);
      expect(host.proxyHost).assertEqual('jump.example');
      expect(host.sshProxyPassword).assertEqual('');
      expect(host.sshProxyKeyPassphrase).assertEqual('');
    });
  });
}
