/**
 * RustDeskConnectionStrategyPolicy — connection path contract shared by
 * host-list preflight, RemoteDesktop and the native adapter.
 *
 * AUTO is intentionally unavailable in the 1.0.10 P0 line. A real AUTO
 * implementation requires NAT testing, TCP hole punching, candidate racing
 * and relay fallback; renaming the current force-relay boolean would be a
 * false capability claim.
 */

export type RustDeskConnectionStrategy =
  | 'force_relay'
  | 'direct_ip'
  | 'auto';

export type RustDeskConnectionStrategyCode =
  | 'ready'
  | 'auto_unavailable'
  | 'invalid_strategy';

export interface RustDeskConnectionStrategyAvailability {
  strategy: RustDeskConnectionStrategy
  supported: boolean
  code: RustDeskConnectionStrategyCode
  message: string
}

export function rustDeskConnectionStrategyForHost(
  directEnabled: boolean
): RustDeskConnectionStrategy {
  return directEnabled ? 'direct_ip' : 'force_relay';
}

export function resolveRustDeskConnectionStrategy(
  value: string,
  directEnabled: boolean
): RustDeskConnectionStrategyAvailability {
  const expected: RustDeskConnectionStrategy =
    rustDeskConnectionStrategyForHost(directEnabled);
  if (value === '') {
    return { strategy: expected, supported: true, code: 'ready', message: '' };
  }
  if (value !== 'force_relay' && value !== 'direct_ip' && value !== 'auto') {
    return {
      strategy: expected,
      supported: false,
      code: 'invalid_strategy',
      message: 'RustDesk 连接策略无效，请重新选择连接方式。'
    };
  }
  if (value === 'auto') {
    return {
      strategy: 'auto',
      supported: false,
      code: 'auto_unavailable',
      message: '自动直连尚未完成真实 NAT 探测与中继回退验证，当前版本不会冒充可用。'
    };
  }
  if (value !== expected) {
    return {
      strategy: value,
      supported: false,
      code: 'invalid_strategy',
      message: 'RustDesk 连接策略与当前主机模式不一致，请重新保存主机。'
    };
  }
  return { strategy: value, supported: true, code: 'ready', message: '' };
}

export function rustDeskConnectionStrategyDiagnostic(
  value: RustDeskConnectionStrategyAvailability
): string {
  return 'strategy=' + value.strategy + ', code=' + value.code +
    ', supported=' + (value.supported ? 'yes' : 'no');
}
