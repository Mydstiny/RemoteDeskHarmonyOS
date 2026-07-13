/**
 * LiveViewTypes.ets — 实况窗共享类型定义
 *
 * 从 RemoteSessionLiveViewService 抽离, 打破 AvSessionLiveViewStrategy
 * 与 RemoteSessionLiveViewService 之间的循环导入。
 */
import { common } from '@kit.AbilityKit';

/** 实况窗模式枚举 */
export enum LiveViewMode {
  OFF = 0,
  AVSESSION = 1,
  NOTIFICATION = 2
}

export function resolveLiveViewMode(preferredMode: number, hasAudio: boolean,
  hasVideo: boolean = false): LiveViewMode {
  if (preferredMode === LiveViewMode.OFF) {
    return LiveViewMode.OFF;
  }
  if (preferredMode === LiveViewMode.NOTIFICATION) {
    return LiveViewMode.NOTIFICATION;
  }
  if (preferredMode === LiveViewMode.AVSESSION) {
    return (hasAudio || hasVideo) ? LiveViewMode.AVSESSION : LiveViewMode.NOTIFICATION;
  }
  return (hasAudio || hasVideo) ? LiveViewMode.AVSESSION : LiveViewMode.NOTIFICATION;
}

/** 传递给实况窗服务的连接信息 */
export interface LiveViewConnectionInfo {
  hostId: string;
  sessionId: number;
  protocolLabel: string;   // 'RDP' | 'RustDesk'
  hostAddress: string;     // '192.168.1.100:3389'
  hasAudio: boolean;
  hasVideo?: boolean;
  mediaKind?: number;
  /** 连接开始时间 (ms since epoch), 用于计时展示 */
  connectedAtMs: number;
}

/** 实况窗策略接口 */
export interface LiveViewStrategy {
  /** 启动实况窗展示 */
  start(context: common.UIAbilityContext, info: LiveViewConnectionInfo): Promise<void>;
  /** 更新实况窗内容 (如音频状态变化) */
  update(info: LiveViewConnectionInfo): Promise<void>;
  /** 停止实况窗展示 */
  stop(context: common.UIAbilityContext): Promise<void>;
}
