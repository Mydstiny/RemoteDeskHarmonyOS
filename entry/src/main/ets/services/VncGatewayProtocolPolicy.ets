/**
 * Runtime gate for VNC gateway transports.
 *
 * UltraVNC Repeater has a pinned byte-level pairing path in native code. The
 * other gateway transports need a server-side contract that is not present in
 * this repository, so they remain explicitly unavailable until that contract
 * is deployed and independently verified.
 */
export interface VncGatewayAvailability {
  enabled: boolean;
  code: string;
  message: string;
}

export const VNC_GATEWAY_PROTOCOL_VERSION: string = 'v1-draft';

export function vncGatewayAvailability(transport: string, tls: boolean,
  tokenConfigured: boolean, repeaterMode: string = 'mode12'): VncGatewayAvailability {
  if (transport === 'ultravnc_repeater') {
    if (repeaterMode !== 'mode12') {
      return {
        enabled: false,
        code: 'E-VNC-REPEATER-MODE2-ROLE',
        message: 'UltraVNC Repeater mode2 是中继服务端监听角色，当前 HarmonyOS 客户端仅支持 Viewer mode12'
      };
    }
    return {
      enabled: true,
      code: '',
      message: ''
    };
  }
  if (transport === 'websocket_gateway') {
    const security: string = tls ? '' : '；当前草案只允许 wss 或可信局域网 ws';
    const token: string = tokenConfigured ? '' : '；如服务端启用认证，还需配置网关令牌';
    return {
      enabled: false,
      code: 'E-VNC-GATEWAY-CONTRACT-DRAFT',
      message: 'VNC WebSocket 网关协议尚未部署或确认（' + VNC_GATEWAY_PROTOCOL_VERSION + '）' +
        security + token
    };
  }
  if (transport === 'public_relay') {
    return {
      enabled: false,
      code: 'E-VNC-PUBLIC-RELAY-CONTRACT',
      message: 'VNC 公网中继需要版本化 endpoint、目标分配和认证契约，当前不可用'
    };
  }
  if (transport === 'ssh_tunnel') {
    return {
      enabled: false,
      code: 'E-VNC-SSH-TUNNEL-CONTRACT',
      message: 'VNC SSH 隧道需要独立的 SSH tunnel owner、host-key trust 和服务端契约，当前不可用'
    };
  }
  return {
    enabled: transport === 'direct_tcp',
    code: transport === 'direct_tcp' ? '' : 'E-VNC-TRANSPORT-UNSUPPORTED',
    message: transport === 'direct_tcp' ? '' : 'VNC 传输类型未实现'
  };
}
