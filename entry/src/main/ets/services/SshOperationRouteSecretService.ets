import { RemoteHost } from '../model/RemoteHost';
import { SshJumpHop, SshJumpHopHandoff, SshPrivateKeyInfo } from '../types/rdpnapi';
import { ExtensionLoader } from './ExtensionLoader';
import { KeyVaultService } from './KeyVaultService';
import { SshOperationRouteSecrets } from './SshOperationConfigPolicy';
import {
  SshProxyRuntimePlan,
  sshProxyRuntimeHasStrictJumpBindings
} from './SshProxyRuntimePolicy';

export class SshOperationRouteSecretResult {
  ok: boolean = false;
  code: string = 'E-SSH-OPERATION-ROUTE-SECRETS';
  message: string = 'SSH 连接路径凭据不可用';
  secrets: SshOperationRouteSecrets = { proxyPassword: '', jumpHandoffs: [] };
}

function failure(code: string, message: string): SshOperationRouteSecretResult {
  const result: SshOperationRouteSecretResult = new SshOperationRouteSecretResult();
  result.code = code;
  result.message = message;
  return result;
}

/** Resolve credentials that are already available in device-local memory. */
export class SshOperationRouteSecretService {
  private static instance: SshOperationRouteSecretService;
  private readonly loader: ExtensionLoader = ExtensionLoader.getInstance();
  private readonly keys: KeyVaultService = KeyVaultService.getInstance();

  static getInstance(): SshOperationRouteSecretService {
    if (!SshOperationRouteSecretService.instance) {
      SshOperationRouteSecretService.instance = new SshOperationRouteSecretService();
    }
    return SshOperationRouteSecretService.instance;
  }

  resolve(host: RemoteHost, plan: SshProxyRuntimePlan,
    legacyProxyPassphrase: string = ''): SshOperationRouteSecretResult {
    if (!plan.valid) {
      return failure(plan.code || 'E-SSH-OPERATION-ROUTE',
        plan.message || 'SSH 连接路径无效');
    }
    let proxyPassword: string = '';
    if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
      plan.proxyAuthRequired) {
      proxyPassword = plan.source === 'legacy' ? host.sshProxyPassword : '';
      if (proxyPassword.length === 0) {
        return failure('E-SSH-OPERATION-PROXY-PASSWORD',
          '该连接路径需要一次性代理密码');
      }
    }
    if (plan.route.type !== 'ssh_jump') {
      return this.success(proxyPassword, []);
    }
    if (!sshProxyRuntimeHasStrictJumpBindings(plan)) {
      return failure('E-SSH-OPERATION-JUMP-HOSTKEY',
        'ProxyJump 每一跳都必须先绑定主机指纹');
    }
    const handoffs: SshJumpHopHandoff[] = [];
    for (let index: number = 0; index < plan.route.hops.length; index++) {
      const hop: SshJumpHop = plan.route.hops[index];
      const prefix: string = '第 ' + (index + 1).toString() + ' 跳';
      if (hop.authMethod === 'password') {
        const password: string = plan.source === 'legacy' && index === 0 ?
          host.sshProxyPassword : '';
        if (password.length === 0) {
          return failure('E-SSH-OPERATION-HOP-PASSWORD', prefix + '需要一次性 SSH 密码');
        }
        handoffs.push({ password, privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: [] });
        continue;
      }
      if (hop.authMethod === 'kbd-interactive') {
        const response: string = plan.source === 'legacy' && index === 0 ?
          host.sshProxyPassword : '';
        if (response.length === 0) {
          return failure('E-SSH-OPERATION-HOP-INTERACTIVE',
            prefix + '需要一次性键盘交互响应');
        }
        handoffs.push({ password: '', privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: [response] });
        continue;
      }
      const keyId: string = index < plan.hopKeyIds.length ? plan.hopKeyIds[index] : '';
      const key = this.keys.getSshKey(keyId);
      if (key === undefined || key.privateKey.length === 0) {
        return failure('E-SSH-OPERATION-HOP-KEY', prefix + '私钥不可用');
      }
      let passphrase: string = plan.source === 'legacy' && index === 0 ?
        (legacyProxyPassphrase || host.sshProxyKeyPassphrase) : '';
      const info: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
        key.privateKey, passphrase);
      if (!info.ok) {
        return failure('E-SSH-OPERATION-HOP-PASSPHRASE',
          prefix + '私钥密码不可用');
      }
      if (!info.encrypted) { passphrase = ''; }
      handoffs.push({ password: '', privateKeyPem: key.privateKey,
        privateKeyPassphrase: passphrase, keyboardInteractiveResponses: [] });
    }
    return this.success(proxyPassword, handoffs);
  }

  private success(proxyPassword: string,
    jumpHandoffs: SshJumpHopHandoff[]): SshOperationRouteSecretResult {
    const result: SshOperationRouteSecretResult = new SshOperationRouteSecretResult();
    result.ok = true;
    result.code = '';
    result.message = '';
    result.secrets = { proxyPassword, jumpHandoffs };
    return result;
  }
}
