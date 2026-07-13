import { describe, it, expect } from '@ohos/hypium';
import {
  SETTINGS_SECTION_ABOUT,
  SETTINGS_SECTION_APPEARANCE,
  SETTINGS_SECTION_CONNECTION_LIVE,
  SETTINGS_SECTION_FEEDBACK,
  SETTINGS_SECTION_NONE,
  SETTINGS_SECTION_RATING,
  SETTINGS_SECTION_TUTORIAL,
  SETTINGS_RATING_SUBTITLE,
  SETTINGS_SUPPORT_EMAIL,
  SETTINGS_SUPPORT_SUBJECT,
  SETTINGS_APP_BUNDLE_NAME,
  SETTINGS_APPGALLERY_REVIEW_ACTION,
  SETTINGS_BROWSER_VIEW_ACTION,
  SETTINGS_EMAIL_PANEL_TYPE,
  SETTINGS_EMAIL_SEND_TO_ACTION,
  settingsSectionIsAction,
  settingsNextExpandedSection,
  settingsActionKind,
  settingsFeedbackBody,
  settingsFeedbackFallbackWantSpecs,
  settingsFeedbackLaunchAttempts,
  settingsFeedbackMailPanelParams,
  settingsFeedbackMailtoUri,
  settingsRatingUriCandidates,
  settingsRatingWantAction
} from '../main/ets/services/SettingsAccordionPolicy';

export default function settingsAccordionPolicyTest() {
  describe('SettingsAccordionPolicy', (): void => {
    it('settings_page_starts_with_all_accordion_sections_collapsed', 0, (): void => {
      expect(SETTINGS_SECTION_NONE).assertEqual('');
    });

    it('accordion_sections_expand_one_at_a_time_and_collapse_when_reselected', 0, (): void => {
      expect(settingsNextExpandedSection(SETTINGS_SECTION_NONE, SETTINGS_SECTION_APPEARANCE))
        .assertEqual(SETTINGS_SECTION_APPEARANCE);
      expect(settingsNextExpandedSection(SETTINGS_SECTION_APPEARANCE, SETTINGS_SECTION_CONNECTION_LIVE))
        .assertEqual(SETTINGS_SECTION_CONNECTION_LIVE);
      expect(settingsNextExpandedSection(SETTINGS_SECTION_CONNECTION_LIVE, SETTINGS_SECTION_TUTORIAL))
        .assertEqual(SETTINGS_SECTION_TUTORIAL);
      expect(settingsNextExpandedSection(SETTINGS_SECTION_CONNECTION_LIVE, SETTINGS_SECTION_CONNECTION_LIVE))
        .assertEqual('');
    });

    it('feedback_and_rating_are_direct_action_rows_not_expandable_sections', 0, (): void => {
      expect(settingsSectionIsAction(SETTINGS_SECTION_FEEDBACK)).assertTrue();
      expect(settingsSectionIsAction(SETTINGS_SECTION_RATING)).assertTrue();
      expect(settingsSectionIsAction(SETTINGS_SECTION_TUTORIAL)).assertFalse();
      expect(settingsSectionIsAction(SETTINGS_SECTION_ABOUT)).assertFalse();
      expect(settingsNextExpandedSection(SETTINGS_SECTION_APPEARANCE, SETTINGS_SECTION_FEEDBACK))
        .assertEqual(SETTINGS_SECTION_APPEARANCE);
      expect(settingsActionKind(SETTINGS_SECTION_FEEDBACK)).assertEqual('feedback');
      expect(settingsActionKind(SETTINGS_SECTION_RATING)).assertEqual('rating');
    });

    it('feedback_mail_metadata_uses_project_support_address_and_bundle', 0, (): void => {
      const body: string = settingsFeedbackBody('1.0.3', 'xl', true);
      expect(SETTINGS_SUPPORT_EMAIL).assertEqual('lijiong1219@petalmail.com');
      expect(SETTINGS_SUPPORT_SUBJECT).assertEqual('RemoteDesktop 用户反馈');
      expect(SETTINGS_APP_BUNDLE_NAME).assertEqual('com.example.remotedesktop');
      expect(body.indexOf('com.example.remotedesktop') >= 0).assertTrue();
      expect(body.indexOf('1.0.3') >= 0).assertTrue();
      expect(body.indexOf('xl') >= 0).assertTrue();
    });

    it('feedback_prefers_mailto_resolver_before_mail_type_panel', 0, (): void => {
      const params: Record<string, Object> = settingsFeedbackMailPanelParams('1.0.5', 'md', false);
      const mailto: string = settingsFeedbackMailtoUri('1.0.5', 'md', false);
      const fallback = settingsFeedbackFallbackWantSpecs('1.0.5', 'md', false);
      const attempts = settingsFeedbackLaunchAttempts('1.0.5', 'md', false);
      expect(SETTINGS_EMAIL_PANEL_TYPE).assertEqual('mail');
      expect(params['sceneType'] as number).assertEqual(1);
      expect((params['email'] as string[])[0]).assertEqual(encodeURI(SETTINGS_SUPPORT_EMAIL));
      expect(params['subject'] as string).assertEqual(encodeURI(SETTINGS_SUPPORT_SUBJECT));
      expect((params['body'] as string).indexOf('1.0.5') >= 0).assertTrue();
      expect(mailto.indexOf('mailto:' + SETTINGS_SUPPORT_EMAIL) === 0).assertTrue();
      expect(fallback.length).assertEqual(2);
      expect(fallback[0].action).assertEqual(SETTINGS_EMAIL_SEND_TO_ACTION);
      expect(fallback[0].uri).assertEqual(mailto);
      expect(fallback[0].entities.length).assertEqual(0);
      expect(fallback[1].action).assertEqual(SETTINGS_BROWSER_VIEW_ACTION);
      expect(fallback[1].entities[0]).assertEqual('entity.system.browsable');
      expect(attempts.length).assertEqual(3);
      expect(attempts[0].kind).assertEqual('want');
      expect(attempts[0].action).assertEqual(SETTINGS_EMAIL_SEND_TO_ACTION);
      expect(attempts[0].uri).assertEqual(mailto);
      expect(attempts[1].kind).assertEqual('mailPanel');
      expect(attempts[1].action).assertEqual(SETTINGS_EMAIL_PANEL_TYPE);
      expect(attempts[2].kind).assertEqual('want');
      expect(attempts[2].action).assertEqual(SETTINGS_BROWSER_VIEW_ACTION);
    });

    it('rating_candidates_try_score_before_detail_with_current_bundle', 0, (): void => {
      const candidates: string[] = settingsRatingUriCandidates();
      expect(SETTINGS_RATING_SUBTITLE).assertEqual('前往应用市场为 RemoteDesktop 评分');
      expect(candidates.length >= 2).assertTrue();
      expect(candidates[0].indexOf('com.example.remotedesktop') >= 0).assertTrue();
      expect(candidates[1].indexOf('com.example.remotedesktop') >= 0).assertTrue();
      expect(candidates[0].indexOf('store://appgallery.huawei.com/app/detail') === 0).assertTrue();
      expect(candidates[0].indexOf('action=write-review') >= 0).assertTrue();
      expect(candidates[1].indexOf('comment') >= 0 || candidates[1].indexOf('score') >= 0 ||
        candidates[1].indexOf('rate') >= 0).assertTrue();
      expect(settingsRatingWantAction(candidates[0])).assertEqual(SETTINGS_APPGALLERY_REVIEW_ACTION);
      expect(settingsRatingWantAction(candidates[1])).assertEqual(SETTINGS_BROWSER_VIEW_ACTION);
    });
  });
}
