/**
 * FeedbackCommunityService.ets — 获取云端畅联群聊二维码清单和图片。
 */
import { http } from '@kit.NetworkKit';
import {
  FEEDBACK_COMMUNITY_MANIFEST_URL,
  FeedbackCommunityManifest,
  validateFeedbackCommunityManifest
} from './FeedbackCommunityPolicy';

const HTTP_CONNECT_TIMEOUT_MS: number = 10000;
const HTTP_READ_TIMEOUT_MS: number = 15000;

function responseCodeIsSuccess(code: number): boolean {
  return code >= 200 && code < 300;
}

export class FeedbackCommunityService {
  async fetchManifest(): Promise<FeedbackCommunityManifest> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const separator: string = FEEDBACK_COMMUNITY_MANIFEST_URL.indexOf('?') >= 0 ? '&' : '?';
      const url: string = FEEDBACK_COMMUNITY_MANIFEST_URL + separator + 't=' + Date.now().toString();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: HTTP_READ_TIMEOUT_MS,
        header: { 'Accept': 'application/json' }
      });
      if (!responseCodeIsSuccess(response.responseCode as number)) {
        throw new Error('云端清单请求失败: HTTP ' + (response.responseCode as number).toString());
      }
      const payload: Object = JSON.parse(response.result as string) as Object;
      const validation = validateFeedbackCommunityManifest(payload, Date.now());
      if (!validation.ok || validation.manifest === null) {
        throw new Error(validation.message || '云端二维码清单无效');
      }
      return validation.manifest;
    } finally {
      request.destroy();
    }
  }

  async downloadQrImage(url: string): Promise<ArrayBuffer> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: HTTP_READ_TIMEOUT_MS,
        header: { 'Accept': 'image/png,image/jpeg,image/*' }
      });
      if (!responseCodeIsSuccess(response.responseCode as number)) {
        throw new Error('二维码下载失败: HTTP ' + (response.responseCode as number).toString());
      }
      if (!(response.result instanceof ArrayBuffer) || response.result.byteLength === 0) {
        throw new Error('云端二维码内容为空');
      }
      return response.result as ArrayBuffer;
    } finally {
      request.destroy();
    }
  }
}
