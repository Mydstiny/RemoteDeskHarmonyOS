import { describe, it, expect } from '@ohos/hypium';
import {
  FEEDBACK_COMMUNITY_QR_MAX_AGE_MS,
  feedbackCommunityImageUrl,
  feedbackCommunityRemainingText,
  validateFeedbackCommunityManifest
} from '../main/ets/services/FeedbackCommunityPolicy';

export default function feedbackCommunityPolicyTest() {
  describe('FeedbackCommunityPolicy', (): void => {
    it('accepts_https_qr_with_a_maximum_seven_day_lifetime', 0, (): void => {
      const now: number = 1000000000;
      const payload: Record<string, Object> = {
        'version': '20260720-01',
        'issuedAt': now - 1000,
        'expiresAt': now - 1000 + FEEDBACK_COMMUNITY_QR_MAX_AGE_MS,
        'qrImageUrl': 'https://lijiong.online/feedback/chanlian-20260720-01.jpg?tenant=feedback',
        'joinUrl': 'https://example.com/join',
        'title': '群聊',
        'notice': '每周更新'
      };
      const result = validateFeedbackCommunityManifest(payload, now);
      expect(result.ok).assertTrue();
      expect(result.manifest !== null).assertTrue();
      if (result.manifest !== null) {
        expect(feedbackCommunityImageUrl(result.manifest).indexOf('&v=') >= 0).assertTrue();
        expect(feedbackCommunityImageUrl(result.manifest).indexOf('v=20260720-01') >= 0).assertTrue();
        expect(feedbackCommunityRemainingText(result.manifest.expiresAt, now)).assertEqual('将在约 7 天后更新');
      }
    });

    it('rejects_expired_or_overlong_qr_manifests', 0, (): void => {
      const now: number = 1000000000;
      const expired: Record<string, Object> = {
        'issuedAt': now - 10000,
        'expiresAt': now - 1,
        'qrImageUrl': 'https://cdn.example.com/qr.png'
      };
      const overlong: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + FEEDBACK_COMMUNITY_QR_MAX_AGE_MS + 1,
        'qrImageUrl': 'https://cdn.example.com/qr.png'
      };
      expect(validateFeedbackCommunityManifest(expired, now).ok).assertFalse();
      expect(validateFeedbackCommunityManifest(overlong, now).ok).assertFalse();
    });

    it('rejects_non_https_qr_and_join_links', 0, (): void => {
      const now: number = 1000000000;
      const insecureQr: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + 3600000,
        'qrImageUrl': 'http://cdn.example.com/qr.png'
      };
      const insecureJoin: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + 3600000,
        'qrImageUrl': 'https://lijiong.online/feedback/chanlian-current.jpg',
        'joinUrl': 'hwid://join'
      };
      expect(validateFeedbackCommunityManifest(insecureQr, now).ok).assertFalse();
      expect(validateFeedbackCommunityManifest(insecureJoin, now).ok).assertFalse();
    });

    it('rejects_qr_assets_outside_the_feedback_origin', 0, (): void => {
      const now: number = 1000000000;
      const foreignHttps: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + 3600000,
        'qrImageUrl': 'https://cdn.example.com/qr.png'
      };
      const lookalikeHost: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + 3600000,
        'qrImageUrl': 'https://lijiong.online.evil/feedback/qr.png'
      };
      expect(validateFeedbackCommunityManifest(foreignHttps, now).ok).assertFalse();
      expect(validateFeedbackCommunityManifest(lookalikeHost, now).ok).assertFalse();
    });

    it('uses_expiry_as_a_compatible_version_for_old_manifests', 0, (): void => {
      const now: number = 1000000000;
      const payload: Record<string, Object> = {
        'issuedAt': now,
        'expiresAt': now + 3600000,
        'qrImageUrl': 'https://lijiong.online/feedback/chanlian-current.jpg'
      };
      const result = validateFeedbackCommunityManifest(payload, now);
      expect(result.ok).assertTrue();
      if (result.manifest !== null) {
        expect(result.manifest.version).assertEqual((now + 3600000).toString());
      }
    });
  });
}
