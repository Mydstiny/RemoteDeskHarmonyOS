import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight,
  resolveRustDeskProSession,
  rustDeskProLoginHint
} from '../../../main/ets/services/RustDeskProConnectionPreflightPolicy';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';
import { RustDeskProAccountState } from '../../../main/ets/model/RustDeskProModels';

function proAccount(id: string, relayId: string, accessToken: string,
  loginStatus: string = 'logged_in', lastLoginAt: number = 0): RustDeskProAccountState {
  return {
    id, relayId, serverUrl: 'http://pro.example.com:21114', username: 'u',
    displayName: 'u', userId: 'uid', accessToken, deviceId: 'dev', deviceUuid: 'uuid',
    loginStatus, lastLoginAt, lastSyncAt: 0, lastSyncError: ''
  };
}

export default function rustDeskProConnectionPreflightPolicyTest(): void {
  describe('RustDeskProConnectionPreflightPolicy', (): void => {
    it('routes_only_after_real_authentication_succeeds', 0, (): void => {
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.CONNECTING)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.ERROR)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.AUTHENTICATED)).assertTrue();
    });

    it('keeps_portrait_sheet_available_after_authentication_failure', 0, (): void => {
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.ERROR)).assertTrue();
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.AUTHENTICATED)).assertFalse();
    });

    it('passes_the_stable_pro_peer_id_to_native_connection', 0, (): void => {
      expect(rustDeskProPeerIdForConnection('123456789', '')).assertEqual('123456789');
      expect(rustDeskProPeerIdForConnection('', '987654321')).assertEqual('987654321');
    });

    it('opens_auth_preflight_for_all_rustdesk_hosts', 0, (): void => {
      expect(shouldOpenRustDeskProPreflight('rustdesk', 'manual', false)).assertTrue();
      expect(shouldOpenRustDeskProPreflight('rustdesk', 'rustdesk_pro', true)).assertTrue();
      expect(shouldOpenRustDeskProPreflight('rdp', 'rustdesk_pro', true)).assertFalse();
    });

    it('allows_blank_non_direct_password_for_connect_time_prompt', 0, (): void => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.label = 'ask-on-connect';
      host.customHostname = 'peer-456';
      host.host = 'relay.example.com';
      host.port = 21116;
      host.rustdeskRelayId = 'relay-1';
      host.rustdeskAuthMode = 'password';
      host.password = '';
      expect(host.getValidationErrors().length).assertEqual(0);
    });

    it('still_requires_a_password_for_direct_rustdesk_hosts', 0, (): void => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.label = 'direct-host';
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = '192.168.1.20';
      host.rustdeskDirectPort = 21118;
      host.password = '';
      expect(host.getValidationErrors().indexOf('RustDesk 直连模式需要设备密码') >= 0).assertTrue();
    });

    // hbbs 拒绝未登录的 punch hole，所以 Pro 导入主机必须带上它绑定账号的 token。
    it('sends_the_token_of_the_account_the_host_is_bound_to', 0, (): void => {
      const accounts: RustDeskProAccountState[] = [
        proAccount('rdpro_a', 'relay-1', 'token-a'),
        proAccount('rdpro_b', 'relay-1', 'token-b')
      ];
      const resolved = resolveRustDeskProSession(accounts, 'rdpro_b', '', 'relay-1', false);
      expect(resolved.token).assertEqual('token-b');
      expect(resolved.state).assertEqual('ready');
    });

    // 手动添加在 Pro 中继上的主机没有账号绑定，但仍然需要通过账号鉴权。
    it('falls_back_to_the_newest_login_on_the_same_relay', 0, (): void => {
      const accounts: RustDeskProAccountState[] = [
        proAccount('rdpro_old', 'relay-1', 'token-old', 'logged_in', 1000),
        proAccount('rdpro_new', 'relay-1', 'token-new', 'logged_in', 2000),
        proAccount('rdpro_other', 'relay-2', 'token-other', 'logged_in', 9000)
      ];
      expect(resolveRustDeskProSession(accounts, '', '', 'relay-1', false).token)
        .assertEqual('token-new');
    });

    it('accepts_the_legacy_account_binding_when_the_pro_id_is_missing', 0, (): void => {
      const accounts: RustDeskProAccountState[] = [proAccount('rdpro_a', 'relay-9', 'token-a')];
      expect(resolveRustDeskProSession(accounts, '', 'rdpro_a', '', false).token)
        .assertEqual('token-a');
    });

    // 重装后云同步只恢复账号元数据，token 是本机数据，会得到一条 requires_login 空令牌行。
    // 这正是"未登录"报错的成因，必须报告成 requires_login 而不是静默无 token。
    it('reports_requires_login_for_a_cloud_restored_tokenless_row', 0, (): void => {
      const restored: RustDeskProAccountState[] = [
        proAccount('rdpro_a', 'relay-1', '', 'requires_login')
      ];
      const resolved = resolveRustDeskProSession(restored, 'rdpro_a', '', 'relay-1', false);
      expect(resolved.token).assertEqual('');
      expect(resolved.state).assertEqual('requires_login');
    });

    // 过期账号送出去只会把"未登录"变成更难懂的凭证被拒错误。
    it('never_sends_an_expired_token', 0, (): void => {
      const expired: RustDeskProAccountState[] = [
        proAccount('rdpro_a', 'relay-1', 'stale-token', 'expired')
      ];
      const resolved = resolveRustDeskProSession(expired, 'rdpro_a', '', 'relay-1', false);
      expect(resolved.token).assertEqual('');
      expect(resolved.state).assertEqual('requires_login');
    });

    // 直连不经过 rendezvous，账号 token 在那里没有意义，也不该外发。
    it('never_sends_a_token_on_direct_connections', 0, (): void => {
      const accounts: RustDeskProAccountState[] = [proAccount('rdpro_a', 'relay-1', 'token-a')];
      expect(resolveRustDeskProSession(accounts, 'rdpro_a', '', 'relay-1', true).token)
        .assertEqual('');
    });

    // 纯 OSS 中继本来就没有 Pro 账号，不能被当成"需要重新登录"。
    it('reports_not_configured_when_no_account_is_bound', 0, (): void => {
      expect(resolveRustDeskProSession([], 'rdpro_a', '', 'relay-1', false).state)
        .assertEqual('not_configured');
      const other: RustDeskProAccountState[] = [proAccount('rdpro_a', 'relay-2', 'token-a')];
      const resolved = resolveRustDeskProSession(other, '', '', 'relay-1', false);
      expect(resolved.token).assertEqual('');
      expect(resolved.state).assertEqual('not_configured');
    });

    // 服务器的账号访问控制报错必须变成可操作的指引。
    it('maps_the_account_control_rejection_to_an_actionable_hint', 0, (): void => {
      const serverError = 'connect pipeline failed: state=RequestingRelay, error=The connection ' +
        'is not allowed. You have not logged in or your login session has expired.';
      expect(rustDeskProLoginHint(serverError, 'requires_login').length > 0).assertTrue();
      expect(rustDeskProLoginHint(serverError, 'requires_login').indexOf('登录 Server Pro') >= 0)
        .assertTrue();
      expect(rustDeskProLoginHint(serverError, 'not_configured').length > 0).assertTrue();
      expect(rustDeskProLoginHint(serverError, 'ready').indexOf('已被服务器拒绝') >= 0).assertTrue();
    });

    // 其他失败必须保留自己的报错，不能被登录指引覆盖。
    it('leaves_unrelated_failures_untouched', 0, (): void => {
      expect(rustDeskProLoginHint('punch hole refused: OFFLINE', 'requires_login')).assertEqual('');
      expect(rustDeskProLoginHint('remote approval timed out', 'ready')).assertEqual('');
      expect(rustDeskProLoginHint('', 'requires_login')).assertEqual('');
    });
  });
}
