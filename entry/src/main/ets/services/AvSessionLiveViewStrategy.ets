/**
 * AvSessionLiveViewStrategy — 使用 AVSession video 类型提供系统媒体身份
 *
 * 原理:
 * - 创建 video 类型的 AVSession → 系统获得媒体播放身份和播控入口
 * - 设置 AVMetadata (连接名/地址) 和 AVPlaybackState (PLAY)
 * - 注册 play/pause 控制命令, 避免播控中心因无控制命令而不展示
 * - activate() 后系统可在支持的设备上展示媒体控制/胶囊
 * - deactivate() 移除媒体会话
 *
 * AVSession 不承载远程桌面视频帧；实际画面由 RemoteSessionPipService 的
 * PiPWindow/XComponent 输出。正式 Live View Kit 是另一套需要场景准入的能力。
 *
 * 为什么统一用 'video':
 * - 远程桌面主语义是视频画面, audio/video 切换时只更新元数据和状态
 * - 避免 audio/video 类型切换导致销毁重建 AVSession 的时序风险
 *
 * 约束:
 * - 每个应用进程只能有 1 个 AVSession
 * - 是否显示系统媒体胶囊由系统版本、设备能力和用户开关决定
 */
import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveViewConnectionInfo, LiveViewStrategy } from './LiveViewTypes';
import {
  avSessionTypeForRemoteMediaKind,
  RemoteSessionMediaKind
} from './RemoteSessionMediaStatePolicy';

const TAG = 'AvSessionLiveView';
const DOMAIN = 0x0015;
const SESSION_TAG = 'RemoteDesktopLiveView';

export class AvSessionLiveViewStrategy implements LiveViewStrategy {
  private session: avSession.AVSession | null = null;
  private active: boolean = false;
  private muted: boolean = false;
  private muteCallback: ((mute: boolean) => void) | null = null;
  private logoPixelMap: image.PixelMap | null = null;

  /**
   * 从外部注入静音控制回调。
   * 由 RemoteDesktop 提供实际的原生音频静音实现。
   */
  setMuteCommandHandler(callback: (mute: boolean) => void): void {
    this.muteCallback = callback;
  }

  async start(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<void> {
    try {
      // 每个进程只能有 1 个 session, 如果之前创建过需要先销毁
      if (this.session !== null) {
        await this.destroySession();
      }

      const mediaKind: number = this.resolveMediaKind(info);
      const sessionType: string = avSessionTypeForRemoteMediaKind(mediaKind);
      if (sessionType.length === 0) {
        throw new Error('[AVSESSION-START] no active remote media');
      }
      this.session = await avSession.createAVSession(context, SESSION_TAG, sessionType as avSession.AVSessionType);
      hilog.info(DOMAIN, TAG, 'AVSession created sessionId=' + this.session.sessionId);

      // 设置媒体元数据: 标题=协议+地址, 艺术家=连接时长
      const title: string = info.protocolLabel + ' 远程连接';
      const artist: string = info.hostAddress;
      const stateText: string = mediaKind === RemoteSessionMediaKind.VIDEO ?
        '远端视频播放中' : '远端音频播放中';
      const logo: image.PixelMap | null = await this.ensureLogoPixelMap(context);
      const metadata: avSession.AVMetadata = {
        assetId: info.sessionId.toString(),
        title: title,
        artist: artist,
        album: 'Live',
        duration: 0,
        author: info.protocolLabel,
        description: stateText,
        mediaImage: logo === null ? undefined : logo
      };
      await this.session.setAVMetadata(metadata);

      // 设置播放状态: 正在播放 (远端音频持续传输)
      await this.session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        speed: 1.0,
        position: {
          elapsedTime: 0,
          updateTime: Date.now()
        }
      });

      // 注册播控中心命令监听: 播放→取消静音, 暂停→静音。
      // video-only 会话没有音频回调时仅更新播放状态。
      this.session.on('play', this.handlePlayCommand);
      this.session.on('pause', this.handlePauseCommand);

      // 激活会话 → 系统获得媒体控制身份；实际视频画面由 PIP 输出
      await this.session.activate();
      this.active = true;
      this.muted = false;

      hilog.info(DOMAIN, TAG, 'AVSession media identity activated kind=' +
        mediaKind.toString() + ' protocol=' + info.protocolLabel +
        ' host=' + info.hostAddress);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      const code: string = be.code === undefined ? 'unknown' : be.code.toString();
      const message: string = be.message === undefined ? JSON.stringify(err) : be.message;
      hilog.warn(DOMAIN, TAG, '[AVSESSION-START] failed code=' +
        code + ' message=' + message);
      await this.destroySession();
      throw new Error('[AVSESSION-START] code=' + code + ' message=' + message);
    }
  }

  async update(info: LiveViewConnectionInfo): Promise<void> {
    if (this.session === null || !this.active) {
      return;
    }
    try {
      const title: string = info.protocolLabel + ' 远程连接';
      const artist: string = info.hostAddress;
      await this.session.setAVMetadata({
        assetId: info.sessionId.toString(),
        title: title,
        artist: artist,
        album: 'Live',
        duration: 0,
        author: info.protocolLabel,
        description: this.resolveMediaKind(info) === RemoteSessionMediaKind.VIDEO ?
          '远端视频播放中' : '远端音频播放中',
        mediaImage: this.logoPixelMap === null ? undefined : this.logoPixelMap
      });
      await this.refreshPlaybackState();

      hilog.info(DOMAIN, TAG, 'AVSession metadata updated audio=' +
        (info.hasAudio ? 'on' : 'off') + ' video=' +
        (info.hasVideo === true ? 'on' : 'off'));
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[AVSESSION-UPDATE] failed code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
    }
  }

  async stop(_context: common.UIAbilityContext): Promise<void> {
    if (this.session === null) {
      return;
    }
    // 取消播控命令监听
    try {
      this.session.off('play', this.handlePlayCommand);
      this.session.off('pause', this.handlePauseCommand);
    } catch (_e) {
      // 取消监听失败不影响清理
    }
    await this.destroySession();
    hilog.info(DOMAIN, TAG, 'AVSession media identity stopped');
  }

  /**
   * 播控中心点击"播放" → 取消静音, 远端音频恢复。
   */
  private handlePlayCommand = (): void => {
    hilog.info(DOMAIN, TAG, 'AVSession play command → unmute');
    this.muted = false;
    if (this.session !== null) {
      this.refreshPlaybackState().catch((_e: Error): void => {
        // 状态更新失败不阻断
      });
    }
    if (this.muteCallback !== null) {
      this.muteCallback(false);
    }
  };

  /**
   * 播控中心点击"暂停" → 静音, 远端音频静音。
   */
  private handlePauseCommand = (): void => {
    hilog.info(DOMAIN, TAG, 'AVSession pause command → mute');
    this.muted = true;
    if (this.session !== null) {
      this.refreshPlaybackState().catch((_e: Error): void => {
        // 状态更新失败不阻断
      });
    }
    if (this.muteCallback !== null) {
      this.muteCallback(true);
    }
  };

  private async ensureLogoPixelMap(context: common.UIAbilityContext): Promise<image.PixelMap | null> {
    if (this.logoPixelMap !== null) {
      return this.logoPixelMap;
    }
    try {
      const content: Uint8Array =
        await context.resourceManager.getMediaContent($r('app.media.startIcon').id);
      const buffer: ArrayBuffer =
        content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
      const source: image.ImageSource = image.createImageSource(buffer);
      this.logoPixelMap = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      source.release();
      return this.logoPixelMap;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[AVSESSION-LOGO] load app logo failed: ' + JSON.stringify(err));
      return null;
    }
  }

  private resolveMediaKind(info: LiveViewConnectionInfo): number {
    if (info.hasVideo === true) {
      return RemoteSessionMediaKind.VIDEO;
    }
    if (info.mediaKind !== undefined) {
      return info.mediaKind;
    }
    if (info.hasAudio) {
      return RemoteSessionMediaKind.AUDIO;
    }
    return RemoteSessionMediaKind.NONE;
  }

  private async refreshPlaybackState(): Promise<void> {
    if (this.session === null) {
      return;
    }
    await this.session.setAVPlaybackState({
      state: this.muted ? avSession.PlaybackState.PLAYBACK_STATE_PAUSE :
        avSession.PlaybackState.PLAYBACK_STATE_PLAY,
      speed: 1.0,
      position: {
        elapsedTime: 0,
        updateTime: Date.now()
      }
    });
  }

  private async destroySession(): Promise<void> {
    if (this.session === null) {
      return;
    }
    try {
      if (this.active) {
        await this.session.deactivate();
        this.active = false;
      }
      await this.session.destroy();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[AVSESSION-DESTROY] failed code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
    } finally {
      this.active = false;
      this.muted = false;
      this.session = null;
      this.muteCallback = null;
      if (this.logoPixelMap !== null) {
        try {
          this.logoPixelMap.release();
        } catch (_e) {
          // 释放失败不影响会话清理
        }
        this.logoPixelMap = null;
      }
    }
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
