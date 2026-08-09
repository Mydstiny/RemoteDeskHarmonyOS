/**
 * Runs the production callback-entry suite from the ohosTest HAP process.
 * The native addon is test-only and is not part of the production HAP.
 */
import { expect } from '@ohos/hypium';
import nativeCallbackEntry from 'libnative_callback_entry_integration.so';
import { auditedDescribe, auditedIt } from '../../../main/ets/services/FocusedTestRegistrationAudit';

interface CallbackEntrySummary {
  suite: string;
  registered: number;
  passed: number;
  failed: number;
  applicationNamespace: string;
  cases: CallbackEntryCase[];
}

interface CallbackEntryCase {
  name: string;
  passed: boolean;
  failure: string;
}

export default function nativeCallbackEntryIntegrationTest(): void {
  auditedDescribe('NativeCallbackEntryIntegration', (): void => {
    auditedIt('runs_nine_production_callback_entries_in_ohostest_namespace', 0, (): void => {
      const summary: CallbackEntrySummary =
        nativeCallbackEntry.runProductionCallbackEntries() as CallbackEntrySummary;
      expect(summary.suite).assertEqual('NativeCallbackEntryIntegration');
      expect(summary.applicationNamespace).assertEqual('ohosTest');
      expect(summary.registered).assertEqual(9);
      expect(summary.passed).assertEqual(9);
      expect(summary.failed).assertEqual(0);
      expect(summary.cases.length).assertEqual(9);
      for (const callbackCase of summary.cases) {
        expect(callbackCase.passed).assertTrue();
        expect(callbackCase.failure).assertEqual('');
      }
    });
  });
}
