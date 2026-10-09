import { describe, it, expect } from '@ohos/hypium';
import {
  SESSION_SCREENSHOT_TEXT_LIMIT,
  SessionEvidenceFacts,
  sessionEvidenceFileName,
  sessionEvidenceSummary,
  sessionScreenshotQuestion
} from '../main/ets/services/pro/evidence/SessionEvidencePolicy';

export default function sessionEvidencePolicyTest() {
  describe('SessionEvidencePolicy', () => {
    it('summary_states_known_facts_only', 0, () => {
      const facts: SessionEvidenceFacts = {
        protocol: 'rustdesk', hostLabel: '书房电脑', capturedAt: new Date(2026, 9, 9, 14, 20, 5).getTime(),
        remoteWidth: 2560, remoteHeight: 1440, viewportWidth: 0, viewportHeight: 0, codec: 'H.264',
        decoder: 'hardware', fps: 59.6, route: 'relay', lastError: '', appVersion: '', deviceType: '平板'
      };
      const summary: string = sessionEvidenceSummary(facts);
      expect(summary.includes('协议：RustDesk（书房电脑）')).assertTrue();
      expect(summary.includes('编解码：H.264（硬件解码）')).assertTrue();
      expect(summary.includes('帧率：60 fps')).assertTrue();
      expect(summary.includes('最近错误：无')).assertTrue();
      expect(summary.includes('本机显示区域')).assertFalse();
      expect(summary.includes('应用版本')).assertFalse();
    });
    it('question_cuts_long_text', 0, () => {
      const long: string = 'a'.repeat(SESSION_SCREENSHOT_TEXT_LIMIT + 10);
      const question: string = sessionScreenshotQuestion(long, 'rdp');
      expect(question.includes('RDP')).assertTrue();
      expect(question.includes('只截取了前')).assertTrue();
      expect(question.endsWith('a'.repeat(SESSION_SCREENSHOT_TEXT_LIMIT))).assertTrue();
    });
    it('file_names_are_ascii', 0, () => {
      const at: number = new Date(2026, 9, 9, 8, 5, 7).getTime();
      expect(sessionEvidenceFileName('screenshot', at)).assertEqual('RemoteDesk-screenshot-20261009-080507.png');
      expect(sessionEvidenceFileName('summary', at)).assertEqual('RemoteDesk-session-20261009-080507.txt');
    });
  });
}
