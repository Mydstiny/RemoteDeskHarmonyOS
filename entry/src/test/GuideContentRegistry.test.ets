import { describe, it, expect } from '@ohos/hypium';
import {
  firstInstallGuidePages,
  guideDeviceFor,
  GuideContentPage,
  GuideDevice,
  GuideLesson,
  guideLessonsFor,
  GuideProtocol,
  GuideProtocolOption,
  guideProtocolOptions,
  handsOnUsageGuidePages,
  settingsUsageGuidePages
} from '../main/ets/services/GuideContentRegistry';

function containsPage(pages: GuideContentPage[], id: string): boolean {
  return pages.some((page: GuideContentPage): boolean => page.id === id);
}

function containsLesson(lessons: GuideLesson[], id: string): boolean {
  return lessons.some((lesson: GuideLesson): boolean => lesson.id === id);
}

function containsProtocol(options: GuideProtocolOption[], id: GuideProtocol): boolean {
  return options.some((option: GuideProtocolOption): boolean => option.id === id);
}

export default function guideContentRegistryTest(): void {
  describe('GuideContentRegistry', (): void => {
    it('keeps_first_install_short_and_device_adaptive', 0, (): void => {
      const phone: GuideContentPage[] = firstInstallGuidePages('phone');
      const desktop: GuideContentPage[] = firstInstallGuidePages('desktop');
      const settings: GuideContentPage[] = settingsUsageGuidePages('phone');
      expect(phone.length).assertEqual(7);
      expect(settings.length).assertEqual(phone.length);
      expect(containsPage(phone, 'device-path-phone')).assertTrue();
      expect(containsPage(desktop, 'device-path-desktop')).assertTrue();
      expect(phone[phone.length - 1].id).assertEqual('start-first-host');
      expect(settings[settings.length - 1].id).assertEqual('revisit');
    });

    it('detects_physical_device_before_window_breakpoint', 0, (): void => {
      expect(guideDeviceFor(true, false, 'sm')).assertEqual('desktop');
      expect(guideDeviceFor(false, true, 'sm')).assertEqual('tablet');
      expect(guideDeviceFor(false, false, 'md')).assertEqual('phone');
      expect(guideDeviceFor(false, false, 'lg')).assertEqual('tablet');
    });

    it('covers_all_five_user_facing_protocols', 0, (): void => {
      const pages: GuideContentPage[] = firstInstallGuidePages('tablet');
      expect(containsPage(pages, 'five-protocol-workspace')).assertTrue();
      const options: GuideProtocolOption[] = guideProtocolOptions();
      expect(options.length).assertEqual(6);
      expect(containsProtocol(options, 'rdp')).assertTrue();
      expect(containsProtocol(options, 'rustdesk')).assertTrue();
      expect(containsProtocol(options, 'ssh')).assertTrue();
      expect(containsProtocol(options, 'vnc')).assertTrue();
      expect(containsProtocol(options, 'moonlight')).assertTrue();
    });

    it('filters_detailed_lessons_by_protocol_and_device', 0, (): void => {
      const phoneRdp: GuideLesson[] = guideLessonsFor('phone', 'rdp');
      const desktopMoonlight: GuideLesson[] = guideLessonsFor('desktop', 'moonlight');
      expect(phoneRdp[0].id).assertEqual('rdp-prepare');
      expect(containsLesson(phoneRdp, 'common-phone-controls')).assertFalse();
      expect(containsLesson(phoneRdp, 'rdp-prepare')).assertTrue();
      expect(containsLesson(phoneRdp, 'ssh-sftp')).assertFalse();
      expect(desktopMoonlight[0].id).assertEqual('moonlight-prepare');
      expect(containsLesson(desktopMoonlight, 'common-desktop-controls')).assertFalse();
      expect(containsLesson(desktopMoonlight, 'moonlight-desktop-control')).assertTrue();
      expect(containsLesson(desktopMoonlight, 'moonlight-lifecycle')).assertTrue();
      expect(containsLesson(desktopMoonlight, 'moonlight-control')).assertFalse();
      const desktopSsh: GuideLesson[] = guideLessonsFor('desktop', 'ssh');
      expect(containsLesson(desktopSsh, 'ssh-workspace')).assertTrue();
      expect(containsLesson(desktopSsh, 'ssh-productivity')).assertTrue();
    });

    it('provides_complete_non_empty_steps_for_every_path', 0, (): void => {
      const devices: GuideDevice[] = ['phone', 'tablet', 'desktop'];
      const protocols: GuideProtocol[] = ['all', 'rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
      devices.forEach((device: GuideDevice): void => {
        protocols.forEach((protocol: GuideProtocol): void => {
          const lessons: GuideLesson[] = guideLessonsFor(device, protocol);
          expect(lessons.length >= 4).assertTrue();
          const ids = new Set<string>();
          lessons.forEach((lesson: GuideLesson): void => {
            expect(lesson.title.length > 0).assertTrue();
            expect(lesson.summary.length > 0).assertTrue();
            expect(lesson.steps.length >= 4).assertTrue();
            expect(ids.has(lesson.id)).assertFalse();
            ids.add(lesson.id);
          });
        });
      });
    });

    it('keeps_legacy_operation_pages_available', 0, (): void => {
      const pages: GuideContentPage[] = handsOnUsageGuidePages();
      expect(pages.length >= 20).assertTrue();
      expect(containsPage(pages, 'rdp-files')).assertTrue();
      expect(containsPage(pages, 'ssh-sftp')).assertTrue();
      expect(containsPage(pages, 'vnc-gateway')).assertTrue();
      expect(containsPage(pages, 'moonlight-quality')).assertTrue();
    });
  });
}
