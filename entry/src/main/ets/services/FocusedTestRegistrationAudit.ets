import { describe as hypiumDescribe, it as hypiumIt } from '@ohos/hypium';

export interface FocusedRegistrationReport {
  scope: string;
  registeredCount: number;
  describeNames: string[];
  errors: string[];
}

/**
 * Runtime instrumentation for the focused on-device suites.
 *
 * The runner still owns the exact allowlist and expected contract, but the
 * count comes from the same `it` calls that are handed to Hypium.  A changed
 * nested describe tree or duplicate test name is a hard registration error,
 * rather than a silently accepted 0/0 or a hand-maintained counter.
 */
export class FocusedTestRegistrationAudit {
  private activeScope: string = '';
  private expectedDescribeNames: string[] = [];
  private testNames: string[] = [];
  private describeNames: string[] = [];
  private errors: string[] = [];

  begin(scope: string, expectedDescribeNames: string[]): void {
    this.activeScope = scope;
    this.expectedDescribeNames = expectedDescribeNames.slice(0);
    this.testNames = [];
    this.describeNames = [];
    this.errors = [];
  }

  recordDescribe(name: string): void {
    if (this.activeScope === '') { return; }
    this.describeNames.push(name);
  }

  recordTest(name: string): void {
    if (this.activeScope === '') { return; }
    if (this.testNames.indexOf(name) >= 0) {
      this.errors.push('duplicate focused test: ' + name);
    }
    this.testNames.push(name);
  }

  end(): FocusedRegistrationReport {
    if (this.activeScope !== '' && !sameStrings(this.describeNames, this.expectedDescribeNames)) {
      this.errors.push('focused describe tree drift: expected=' +
        this.expectedDescribeNames.join('|') + ' actual=' + this.describeNames.join('|'));
    }
    const report: FocusedRegistrationReport = {
      scope: this.activeScope,
      registeredCount: this.testNames.length,
      describeNames: this.describeNames.slice(0),
      errors: this.errors.slice(0)
    };
    this.activeScope = '';
    this.expectedDescribeNames = [];
    this.testNames = [];
    this.describeNames = [];
    this.errors = [];
    return report;
  }
}

function sameStrings(actual: string[], expected: string[]): boolean {
  if (actual.length !== expected.length) { return false; }
  for (let index = 0; index < expected.length; index++) {
    if (actual[index] !== expected[index]) { return false; }
  }
  return true;
}

export const FOCUSED_TEST_REGISTRATION_AUDIT: FocusedTestRegistrationAudit =
  new FocusedTestRegistrationAudit();

export function auditedDescribe(name: string, body: () => void): void {
  FOCUSED_TEST_REGISTRATION_AUDIT.recordDescribe(name);
  hypiumDescribe(name, body);
}

export function auditedIt(name: string, timeout: number, body: () => void): void {
  FOCUSED_TEST_REGISTRATION_AUDIT.recordTest(name);
  hypiumIt(name, timeout, body);
}
