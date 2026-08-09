import rustDeskProAddressBookTest from '../../../test/RustDeskProAddressBook.test';
import rustDeskProAddressBookApiServiceTest from '../../../test/RustDeskProAddressBookApiService.test';
import rustDeskProAddressBookSyncServiceTest from '../../../test/RustDeskProAddressBookSyncService.test';
import rustDeskProAddressBookUiPolicyTest from '../../../test/RustDeskProAddressBookUiPolicy.test';

/**
 * Compile-only bridge for Phase 12A while the shared test List is owned by
 * another workflow.  It intentionally does not invoke or register suites;
 * the later aggregate registration can reuse the same source-of-truth files.
 */
export function rustDeskProAddressBookPhase12ASuitesForRegistration(): Array<() => void> {
  return [
    rustDeskProAddressBookTest,
    rustDeskProAddressBookApiServiceTest,
    rustDeskProAddressBookSyncServiceTest,
    rustDeskProAddressBookUiPolicyTest
  ];
}

export default function rustDeskProAddressBookPhase12ACompileProbe(): void {
  // Import resolution is the purpose of this file; execution stays deferred.
}
