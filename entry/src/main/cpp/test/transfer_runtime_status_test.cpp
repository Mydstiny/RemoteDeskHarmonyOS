// Typed per-session transfer truth contract.
#include "test_runner.h"
#include "extensions/transfer_runtime_status.h"

RDP_TEST_CASE(transfer_runtime_status_reports_rdp_mount_only_after_success) {
    TransferRuntimeStatus status;
    status.markRdpDriveUnavailable("drive_unavailable");
    RDP_ASSERT(!status.snapshot().rdpDriveMounted);

    status.markRdpDriveMounted();
    RDP_ASSERT(status.snapshot().rdpDriveMounted);
}

RDP_TEST_CASE(transfer_runtime_status_tracks_rustdesk_progress_and_terminal_results) {
    TransferRuntimeStatus status;
    status.markRustDeskProgress(42, 4096, 8192);
    SessionTransferStatus progress = status.snapshot();
    RDP_ASSERT_EQ(progress.transferId, 42ULL);
    RDP_ASSERT_EQ(progress.transferredBytes, 4096ULL);
    RDP_ASSERT_EQ(progress.totalBytes, 8192ULL);
    RDP_ASSERT_EQ(progress.rustdeskTransfer, TransferRuntimeState::TRANSFERRING);

    status.markRustDeskConfirmed(42, 8192);
    RDP_ASSERT_EQ(status.snapshot().rustdeskTransfer, TransferRuntimeState::CONFIRMED);

    status.markRustDeskFailed(42, "remote_rejected");
    SessionTransferStatus failed = status.snapshot();
    RDP_ASSERT_EQ(failed.rustdeskTransfer, TransferRuntimeState::FAILED);
    RDP_ASSERT(failed.diagnosticCode == "remote_rejected");
}
