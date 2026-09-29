import { ProAccessDecision } from './ProAccessPolicy';
import { ProFeature } from './ProFeatureCatalog';

export type ProFeatureStatusTone = 'ready' | 'locked' | 'experimental' | 'planned' | 'unsupported';
export interface ProFeatureStatus { label: string; detail: string; tone: ProFeatureStatusTone; }

function deviceName(device: string): string {
  if (device === 'phone') { return '手机'; }
  if (device === 'tablet') { return '平板'; }
  if (device === 'pc') { return 'PC'; }
  return device;
}

/** Where a feature applies, for the management list. */
export function proFeatureScope(feature: ProFeature): string {
  const parts: string[] = [];
  if (feature.devices.length > 0) { parts.push(feature.devices.map(deviceName).join('/')); }
  if (feature.protocols.length > 0) {
    parts.push(feature.protocols.map((protocol: string): string =>
      protocol === 'ai' ? '远程 AI' : protocol.toUpperCase()).join('/'));
  }
  if (feature.minApiVersion > 0) { parts.push('API ' + feature.minApiVersion.toString() + '+'); }
  return parts.join(' · ');
}

/** Explains the current entitlement decision of one feature; display choice is shown separately. */
export function proFeatureStatus(feature: ProFeature, decision: ProAccessDecision, debug: boolean): ProFeatureStatus {
  if (decision.executable) { return { label: '可用', detail: '当前账号和设备可以使用', tone: 'ready' }; }
  const reason = decision.reason;
  if (reason === 'planned') {
    if (feature.availability === 'experimental') {
      return { label: '实验中', tone: 'experimental',
        detail: debug ? '仅在 Debug 切到“模拟 Pro”后可测试' : '正式版暂未开放' };
    }
    return { label: '规划中', detail: '尚未交付', tone: 'planned' };
  }
  if (reason === 'purchaseRequired') { return { label: '需要 Pro', detail: '开通 Pro 后可用', tone: 'locked' }; }
  if (reason === 'verificationRequired') {
    return { label: '等待验证', detail: '联网刷新 Pro 状态后可用', tone: 'locked' };
  }
  if (reason === 'versionUnsupported') {
    return { label: '版本不支持', detail: '需要 API ' + feature.minApiVersion.toString() + ' 或更新版本', tone: 'unsupported' };
  }
  if (reason === 'deviceUnsupported') {
    return { label: '设备不支持', detail: '支持：' + feature.devices.map(deviceName).join('/'), tone: 'unsupported' };
  }
  if (reason === 'capabilityUnsupported') { return { label: '系统能力不支持', detail: '当前系统缺少所需能力', tone: 'unsupported' }; }
  if (reason === 'protocolUnsupported') { return { label: '协议不支持', detail: '仅在对应协议会话中可用', tone: 'unsupported' }; }
  if (reason === 'permissionRequired') { return { label: '需要授权', detail: '首次使用时会请求系统权限', tone: 'ready' }; }
  if (reason === 'permissionDenied') { return { label: '权限被拒绝', detail: '请在系统设置中允许相关权限', tone: 'locked' }; }
  if (reason === 'serverAuthorizationRequired') { return { label: '需服务端授权', detail: '每次使用由服务端确认', tone: 'ready' }; }
  return { label: '未知', detail: '目录中没有此功能', tone: 'unsupported' };
}
