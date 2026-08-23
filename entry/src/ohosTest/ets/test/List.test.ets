import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { describe, it, expect } from '@ohos/hypium';
import abilityTest from './Ability.test';
import componentTest from './Component.test';
import cloudSyncTest from './CloudSync.test';
import dataCryptoTest from './DataCrypto.test';
import fileTransferProgressModelTest from './FileTransferProgressModel.test';
import remoteSessionStateTest from './RemoteSessionState.test';
import nativeSessionHandlesTest from './NativeSessionHandles.test';
import activeRemoteSessionRegistryTest from './ActiveRemoteSessionRegistry.test';
import remoteDesktopBackgroundLifecyclePolicyTest from './RemoteDesktopBackgroundLifecyclePolicy.test';
import remoteSessionLiveViewPolicyTest from './RemoteSessionLiveViewPolicy.test';
import remoteSessionPipLifecyclePolicyTest from './RemoteSessionPipLifecyclePolicy.test';
import hostListFilterServiceTest from './HostListFilterService.test';
import hostSyncServiceTest from './HostSyncService.test';
import remoteRestoreFrameRefreshPolicyTest from './RemoteRestoreFrameRefreshPolicy.test';
import safeLoggerTest from './SafeLogger.test';
import rustDeskHostConfigPolicyTest from './RustDeskHostConfigPolicy.test';
import rustDeskRelayHealthPolicyTest from './RustDeskRelayHealthPolicy.test';
import backgroundVideoPrewarmPolicyTest from './BackgroundVideoPrewarmPolicy.test';
import remoteImeSessionPolicyTest from './RemoteImeSessionPolicy.test';
import remoteImeCommandQueueTest from './RemoteImeCommandQueue.test';
import remoteImmersivePolicyTest from './RemoteImmersivePolicy.test';
import rdpCertificateProbeLifecyclePolicyTest from './RdpCertificateProbeLifecyclePolicy.test';
import rustDeskProConnectionPreflightPolicyTest from './RustDeskProConnectionPreflightPolicy.test';
import rustDeskProCredentialPolicyTest from './RustDeskProCredentialPolicy.test';
import remoteHostDataBoundaryPolicyTest from './RemoteHostDataBoundaryPolicy.test';
import hostWorkspacePolicyTest from './HostWorkspacePolicy.test';
import guideContentRegistryTest from './GuideContentRegistry.test';
import sshKeyImportServiceTest from './SshKeyImportService.test';
import rustDeskLanDiscoveryServiceTest from './RustDeskLanDiscoveryService.test';
import hostAddModePolicyTest from './HostAddModePolicy.test';
import legacyRustDeskAccountCloudAdapterTest from './LegacyRustDeskAccountCloudAdapter.test';
import hostAddDraftTest from './HostAddDraft.test';
import rustDeskCardBadgePolicyTest from './RustDeskCardBadgePolicy.test';
import rustDeskDiagnosticsPolicyTest from './RustDeskDiagnosticsPolicy.test';
import remotePhysicalKeyboardPolicyTest from './RemotePhysicalKeyboardPolicy.test';
import touchpadPointerCurvePolicyTest from './TouchpadPointerCurvePolicy.test';
import remotePhysicalTouchpadPolicyTest from '../../../test/RemotePhysicalTouchpadPolicy.test';
import remoteSurfaceTransformPolicyTest from './RemoteSurfaceTransformPolicy.test';
import remoteCursorStylePolicyTest from './RemoteCursorStylePolicy.test';
import remoteHostSheetLifecyclePolicyTest from './RemoteHostSheetLifecyclePolicy.test';
import vncSessionGeometryPolicyTest from './VncSessionGeometryPolicy.test';
import remoteFloatingPanelPlacementPolicyTest from './RemoteFloatingPanelPlacementPolicy.test';
import vncSessionSettingsPolicyTest from './VncSessionSettingsPolicy.test';
import vncSessionUiPolicyTest from '../../../test/VncSessionUiPolicy.test';
import remoteWheelPolicyTest from './RemoteWheelPolicy.test';
import vncCertificateDecisionHandoffTest from '../../../test/VncCertificateDecisionHandoff.test';
import vncCertificateSheetPolicyTest from '../../../test/VncCertificateSheetPolicy.test';
import vncCertificatePreflightPolicyTest from '../../../test/VncCertificatePreflightPolicy.test';
import vncCertificateProbeLifecyclePolicyTest from '../../../test/VncCertificateProbeLifecyclePolicy.test';
import vncTrustServiceTest from '../../../test/VncTrustService.test';
import vncTrustEndpointDirectoryTest from '../../../test/VncTrustEndpointDirectory.test';
import vncTlsEndpointPolicyTest from '../../../test/VncTlsEndpointPolicy.test';
import vncTrustInvalidationPolicyTest from '../../../test/VncTrustInvalidationPolicy.test';
import vncHostDefaultsPolicyTest from '../../../test/VncHostDefaultsPolicy.test';
import vncGatewayHealthPolicyTest from '../../../test/VncGatewayHealthPolicy.test';
import vncRendererSurfacePolicyTest from '../../../test/VncRendererSurfacePolicy.test';
import vncPhysicalKeyboardPolicyTest from '../../../test/VncPhysicalKeyboardPolicy.test';
import localBackupPolicyTest from '../../../test/LocalBackupPolicy.test';
// Reuse the same source-of-truth unit suites in the on-device runner.  These
// imports intentionally avoid a second copy that could drift from entry/src/test.
import remoteOverlayViewportPolicyTest from '../../../test/RemoteOverlayViewportPolicy.test';
import remoteShortcutPolicyTest from '../../../test/RemoteShortcutPolicy.test';
import remoteKeyDispatcherTest from '../../../test/RemoteKeyDispatcher.test';
import remoteCanvasInteractionPolicyTest from '../../../test/RemoteCanvasInteractionPolicy.test';
import remoteKeyboardLayoutSelectionPolicyTest from '../../../test/RemoteKeyboardLayoutSelectionPolicy.test';
import remoteModifierStateControllerTest from '../../../test/RemoteModifierStateController.test';
import remoteSessionTopBarPolicyTest from '../../../test/RemoteSessionTopBarPolicy.test';
import remoteSessionSidebarLayoutPolicyTest from '../../../test/RemoteSessionSidebarLayoutPolicy.test';
import remotePointerFocusPolicyTest from '../../../test/RemotePointerFocusPolicy.test';
import totpBrandServiceTest from '../../../test/TotpBrandService.test';
import rustDeskProAddressBookTest from '../../../test/RustDeskProAddressBook.test';
import rustDeskProAddressBookApiServiceTest from '../../../test/RustDeskProAddressBookApiService.test';
import rustDeskProAddressBookSyncServiceTest from '../../../test/RustDeskProAddressBookSyncService.test';
import rustDeskProAddressBookUiPolicyTest from '../../../test/RustDeskProAddressBookUiPolicy.test';
import totpBrandResourceIntegrationTest from './TotpBrandResourceIntegration.test';
import nativeCallbackEntryIntegrationTest from './NativeCallbackEntryIntegration.test';
import moonlightSunshineInteropIntegrationTest from './MoonlightSunshineInteropIntegration.test';
import moonlightModelsTest from '../../../test/MoonlightModels.test';
import moonlightRecordTest from '../../../test/MoonlightRecord.test';
import moonlightRecordPolicyTest from '../../../test/MoonlightRecordPolicy.test';
import moonlightCapabilityPolicyTest from '../../../test/MoonlightCapabilityPolicy.test';
import moonlightSettingsPolicyTest from '../../../test/MoonlightSettingsPolicy.test';
import moonlightRecordConflictPolicyTest from '../../../test/MoonlightRecordConflictPolicy.test';
import moonlightSessionStateTest from '../../../test/MoonlightSessionState.test';
import moonlightStoragePolicyTest from '../../../test/MoonlightStoragePolicy.test';
import moonlightCloudTableAdapterTest from '../../../test/MoonlightCloudTableAdapter.test';
import moonlightRepositoryTest from '../../../test/MoonlightRepository.test';
import moonlightAppCacheServiceTest from '../../../test/MoonlightAppCacheService.test';
import moonlightSensitiveTransferPolicyTest from '../../../test/MoonlightSensitiveTransferPolicy.test';
import moonlightCloudSyncSelectionPolicyTest from '../../../test/MoonlightCloudSyncSelectionPolicy.test';
import moonlightCloudSyncServiceTest from '../../../test/MoonlightCloudSyncService.test';
import moonlightDataLifecycleBarrierTest from '../../../test/MoonlightDataLifecycleBarrier.test';
import moonlightDeletionPolicyTest from '../../../test/MoonlightDeletionPolicy.test';
import moonlightCloudDeletionPolicyTest from '../../../test/MoonlightCloudDeletionPolicy.test';
import moonlightDeletionCommandServiceTest from '../../../test/MoonlightDeletionCommandService.test';
import moonlightCloudStatusPolicyTest from '../../../test/MoonlightCloudStatusPolicy.test';
import moonlightBackupPolicyTest from '../../../test/MoonlightBackupPolicy.test';
import moonlightReconnectPolicyTest from '../../../test/MoonlightReconnectPolicy.test';
import moonlightRuntimeContextFactoryTest from '../../../test/MoonlightRuntimeContextFactory.test';
import remoteSessionWindowPolicyTest from '../../../test/RemoteSessionWindowPolicy.test';
import remoteSessionServiceLeasePolicyTest from '../../../test/RemoteSessionServiceLeasePolicy.test';
import moonlightNetworkHandlePolicyTest from '../../../test/MoonlightNetworkHandlePolicy.test';
import { FOCUSED_TEST_REGISTRATION_AUDIT } from '../../../main/ets/services/FocusedTestRegistrationAudit';

function requestedClassScope(): string {
  try {
    const args: abilityDelegatorRegistry.AbilityDelegatorArgs =
      abilityDelegatorRegistry.getArguments();
    return args.parameters['-s class'] || args.testCaseNames || '';
  } catch (_e) {
    return '';
  }
}

/** Exact focused suites and their source-of-truth test counts. */
function registerFocusedRepairSuite(scope: string): number {
  const expectedDescribeNames: string[] = focusedDescribeNames(scope);
  if (expectedDescribeNames.length === 0) { return 0; }
  FOCUSED_TEST_REGISTRATION_AUDIT.begin(scope, expectedDescribeNames);
  if (scope === 'TotpBrandService') {
    totpBrandServiceTest();
  } else if (scope === 'TotpBrandResourceIntegration') {
    totpBrandResourceIntegrationTest();
  } else if (scope === 'NativeCallbackEntryIntegration') {
    nativeCallbackEntryIntegrationTest();
  } else if (scope === 'MoonlightSunshineInteropIntegration') {
    moonlightSunshineInteropIntegrationTest();
  } else if (scope === 'RustDeskProAddressBookPolicy') {
    rustDeskProAddressBookTest();
  } else if (scope === 'RustDeskProAddressBookApiService') {
    rustDeskProAddressBookApiServiceTest();
  } else if (scope === 'RustDeskProAddressBookSyncService') {
    rustDeskProAddressBookSyncServiceTest();
  } else if (scope === 'RustDeskProAddressBookUiPolicy') {
    rustDeskProAddressBookUiPolicyTest();
  } else if (scope === 'RemoteOverlayViewportPolicy_contract') {
    remoteOverlayViewportPolicyTest('viewport');
  } else if (scope === 'RemoteOverlayRegistry_generation_and_cleanup') {
    remoteOverlayViewportPolicyTest('registry');
  } else if (scope === 'RemoteShortcutCatalog_protocol_matrix') {
    remoteShortcutPolicyTest();
  } else if (scope === 'RemoteKeyDispatcher_semantic_atomicity') {
    remoteKeyDispatcherTest();
  } else if (scope === 'RemoteCanvasInteractionPolicy_real_surface_contract') {
    remoteCanvasInteractionPolicyTest();
  } else if (scope === 'RemoteKeyboardLayoutSelection_owner_session_generation') {
    remoteKeyboardLayoutSelectionPolicyTest();
  } else if (scope === 'RemoteModifierStateController_lifecycle_mirror') {
    remoteModifierStateControllerTest();
  } else if (scope === 'RemoteSessionTopBarPolicy') {
    remoteSessionTopBarPolicyTest();
  } else if (scope === 'MoonlightDomainPolicy') {
    moonlightModelsTest();
    moonlightRecordTest();
    moonlightRecordPolicyTest();
    moonlightCapabilityPolicyTest();
    moonlightSettingsPolicyTest();
    moonlightRecordConflictPolicyTest();
    moonlightSessionStateTest();
    moonlightStoragePolicyTest();
    moonlightCloudTableAdapterTest();
    moonlightRepositoryTest();
    moonlightAppCacheServiceTest();
    moonlightSensitiveTransferPolicyTest();
    moonlightCloudSyncSelectionPolicyTest();
    moonlightCloudSyncServiceTest();
    moonlightDataLifecycleBarrierTest();
    moonlightDeletionPolicyTest();
    moonlightCloudDeletionPolicyTest();
    moonlightDeletionCommandServiceTest();
    moonlightCloudStatusPolicyTest();
    moonlightBackupPolicyTest();
    moonlightReconnectPolicyTest();
    moonlightRuntimeContextFactoryTest();
    remoteSessionServiceLeasePolicyTest();
    moonlightNetworkHandlePolicyTest();
  } else {
    return 0;
  }
  const report = FOCUSED_TEST_REGISTRATION_AUDIT.end();
  if (report.errors.length > 0) {
    console.error('focused registration audit failed: ' + report.errors.join(' || '));
    return -1;
  }
  console.info('focused registration audit scope=' + scope +
    ' describeCount=' + report.describeNames.length.toString() +
    ' testCount=' + report.registeredCount.toString());
  return report.registeredCount;
}

function focusedDescribeNames(scope: string): string[] {
  if (scope === 'RemoteOverlayViewportPolicy_contract') {
    return ['RemoteOverlayViewportPolicy_contract'];
  }
  if (scope === 'MoonlightDomainPolicy') {
    return ['MoonlightModels', 'MoonlightRecord', 'MoonlightRecordPolicy',
      'MoonlightCapabilityPolicy', 'MoonlightSettingsPolicy', 'MoonlightRecordConflictPolicy',
      'MoonlightSessionState', 'MoonlightStoragePolicy', 'MoonlightCloudTableAdapter',
      'MoonlightRepository', 'MoonlightAppCacheService',
      'MoonlightSensitiveTransferPolicy', 'MoonlightCloudSyncSelectionPolicy',
      'MoonlightCloudSyncService', 'MoonlightDataLifecycleBarrier',
      'MoonlightDeletionPolicy', 'MoonlightCloudDeletionPolicy',
      'MoonlightDeletionCommandService',
      'MoonlightCloudStatusPolicy',
      'MoonlightBackupPolicy', 'MoonlightReconnectPolicy',
      'MoonlightRuntimeContextFactory', 'RemoteSessionServiceLeasePolicy',
      'MoonlightNetworkHandlePolicy'];
  }
  if (scope === 'RustDeskProAddressBookPolicy') {
    return ['RustDeskProAddressBookPolicy'];
  }
  if (scope === 'RustDeskProAddressBookApiService') {
    return ['RustDeskProAddressBookApiService'];
  }
  if (scope === 'RustDeskProAddressBookSyncService') {
    return ['RustDeskProAddressBookSyncService'];
  }
  if (scope === 'RustDeskProAddressBookUiPolicy') {
    return ['RustDeskProAddressBookUiPolicy'];
  }
  if (scope === 'TotpBrandResourceIntegration') {
    return ['TotpBrandResourceIntegration'];
  }
  if (scope === 'NativeCallbackEntryIntegration') {
    return ['NativeCallbackEntryIntegration'];
  }
  if (scope === 'MoonlightSunshineInteropIntegration') {
    return ['MoonlightSunshineInteropIntegration'];
  }
  if (scope === 'RemoteOverlayRegistry_generation_and_cleanup') {
    return ['RemoteOverlayRegistry_generation_and_cleanup'];
  }
  if (scope === 'RemoteShortcutCatalog_protocol_matrix') {
    return ['RemoteShortcutCatalog_protocol_matrix'];
  }
  if (scope === 'RemoteKeyDispatcher_semantic_atomicity') {
    return ['RemoteKeyDispatcher_semantic_atomicity'];
  }
  if (scope === 'RemoteCanvasInteractionPolicy_real_surface_contract') {
    return ['RemoteCanvasInteractionPolicy_real_surface_contract'];
  }
  if (scope === 'RemoteKeyboardLayoutSelection_owner_session_generation') {
    return ['RemoteKeyboardLayoutSelection_owner_session_generation'];
  }
  if (scope === 'RemoteModifierStateController_lifecycle_mirror') {
    return ['RemoteModifierStateController_lifecycle_mirror'];
  }
  if (scope === 'RemoteSessionTopBarPolicy') {
    return [
      'RemoteSessionTopBarPolicy',
      'RemoteSessionTopBarPolicy_visibility',
      'RemoteSessionTopBarPolicy_layout',
      'RemoteSessionTopBarPolicy_edgeRail',
      'RemoteSessionTopBarPolicy_actions',
      'RemoteSessionTopBarPolicy_autoCollapse',
      'RemoteSessionTopBarPolicy_preferences'
    ];
  }
  if (scope === 'TotpBrandService') {
    return [
      'TotpBrandService',
      'TotpBrandResolver_exact_matching',
      'TotpBrandAvatar_fallback_and_privacy',
      'TotpBrandCache_bounded_pixelmap_ownership',
      'TotpBrandManifest_provenance',
      'TotpBrandTicker_page_scope'
    ];
  }
  return [];
}

function expectedFocusedCount(scope: string): number {
  if (scope === 'MoonlightDomainPolicy') { return 200; }
  if (scope === 'RustDeskProAddressBookPolicy') { return 8; }
  if (scope === 'RustDeskProAddressBookApiService') { return 4; }
  if (scope === 'RustDeskProAddressBookSyncService') { return 7; }
  if (scope === 'RustDeskProAddressBookUiPolicy') { return 3; }
  if (scope === 'TotpBrandResourceIntegration') { return 2; }
  if (scope === 'NativeCallbackEntryIntegration') { return 1; }
  if (scope === 'MoonlightSunshineInteropIntegration') { return 1; }
  if (scope === 'RemoteOverlayViewportPolicy_contract') { return 7; }
  if (scope === 'RemoteOverlayRegistry_generation_and_cleanup') { return 4; }
  if (scope === 'RemoteShortcutCatalog_protocol_matrix') { return 12; }
  if (scope === 'RemoteKeyDispatcher_semantic_atomicity') { return 11; }
  if (scope === 'RemoteCanvasInteractionPolicy_real_surface_contract') { return 3; }
  if (scope === 'RemoteKeyboardLayoutSelection_owner_session_generation') { return 3; }
  if (scope === 'RemoteModifierStateController_lifecycle_mirror') { return 1; }
  if (scope === 'RemoteSessionTopBarPolicy') { return 23; }
  if (scope === 'TotpBrandService') { return 23; }
  return 0;
}

function registerFocusedScopeGuard(scope: string): void {
  console.error('focused scope rejected by exact allowlist: ' + scope);
  // Hypium applies -s class after registration.  Register the hard-failure
  // guard under the exact rejected class name; a fixed guard name would be
  // filtered out and silently turn invalid input back into 0/0.
  describe(scope, (): void => {
    it('unknown_scope_is_a_hard_failure', 0, (): void => {
      // An invalid, prefixed, or otherwise malicious scope must never fall
      // through to the full suite or report a misleading 0/0 success.
      expect(false).assertTrue();
    });
  });
}

export default function testsuite() {
  const scope: string = requestedClassScope();
  if (scope !== '') {
    const expectedCount: number = expectedFocusedCount(scope);
    const registeredCount: number = registerFocusedRepairSuite(scope);
    if (expectedCount > 0 && registeredCount === expectedCount && registeredCount > 0) {
      console.info('focused_scope_allowlist=exact scope=' + scope +
        ' expectedCount=' + expectedCount.toString() +
        ' registeredCount=' + registeredCount.toString() + ' exactCount=required');
      return;
    }
    registerFocusedScopeGuard(scope);
    return;
  }
  abilityTest();
  componentTest();
  cloudSyncTest();
  dataCryptoTest();
  fileTransferProgressModelTest();
  remoteSessionStateTest();
  nativeSessionHandlesTest();
  activeRemoteSessionRegistryTest();
  remoteDesktopBackgroundLifecyclePolicyTest();
  remoteSessionLiveViewPolicyTest();
  remoteSessionPipLifecyclePolicyTest();
  remoteRestoreFrameRefreshPolicyTest();
  hostListFilterServiceTest();
  hostSyncServiceTest();
  safeLoggerTest();
  rustDeskHostConfigPolicyTest();
  rustDeskRelayHealthPolicyTest();
  backgroundVideoPrewarmPolicyTest();
  remoteImeSessionPolicyTest();
  remoteImeCommandQueueTest();
  remoteImmersivePolicyTest();
  rdpCertificateProbeLifecyclePolicyTest();
  rustDeskProConnectionPreflightPolicyTest();
  rustDeskProCredentialPolicyTest();
  remoteHostDataBoundaryPolicyTest();
  hostWorkspacePolicyTest();
  guideContentRegistryTest();
  sshKeyImportServiceTest();
  rustDeskLanDiscoveryServiceTest();
  hostAddModePolicyTest();
  legacyRustDeskAccountCloudAdapterTest();
  hostAddDraftTest();
  rustDeskCardBadgePolicyTest();
  rustDeskDiagnosticsPolicyTest();
  remotePhysicalKeyboardPolicyTest();
  vncPhysicalKeyboardPolicyTest();
  touchpadPointerCurvePolicyTest();
  remotePhysicalTouchpadPolicyTest();
  remoteSurfaceTransformPolicyTest();
  remoteCursorStylePolicyTest();
  remoteHostSheetLifecyclePolicyTest();
  vncSessionGeometryPolicyTest();
  remoteFloatingPanelPlacementPolicyTest();
  vncSessionSettingsPolicyTest();
  vncSessionUiPolicyTest();
  remoteWheelPolicyTest();
  vncCertificateDecisionHandoffTest();
  vncCertificateSheetPolicyTest();
  vncCertificatePreflightPolicyTest();
  vncCertificateProbeLifecyclePolicyTest();
  vncTrustServiceTest();
  vncTrustEndpointDirectoryTest();
  vncTlsEndpointPolicyTest();
  vncTrustInvalidationPolicyTest();
  vncHostDefaultsPolicyTest();
  vncGatewayHealthPolicyTest();
  vncRendererSurfacePolicyTest();
  localBackupPolicyTest();
  rustDeskProAddressBookTest();
  rustDeskProAddressBookApiServiceTest();
  rustDeskProAddressBookSyncServiceTest();
  rustDeskProAddressBookUiPolicyTest();
  remoteOverlayViewportPolicyTest();
  remoteShortcutPolicyTest();
  remoteKeyDispatcherTest();
  remoteCanvasInteractionPolicyTest();
  remoteKeyboardLayoutSelectionPolicyTest();
  remoteModifierStateControllerTest();
  remoteSessionTopBarPolicyTest();
  remoteSessionSidebarLayoutPolicyTest();
  remotePointerFocusPolicyTest();
  totpBrandServiceTest();
  totpBrandResourceIntegrationTest();
  nativeCallbackEntryIntegrationTest();
  moonlightModelsTest();
  moonlightRecordTest();
  moonlightRecordPolicyTest();
  moonlightCapabilityPolicyTest();
  moonlightSettingsPolicyTest();
  moonlightRecordConflictPolicyTest();
  moonlightSessionStateTest();
  moonlightStoragePolicyTest();
  moonlightCloudTableAdapterTest();
  moonlightRepositoryTest();
  moonlightAppCacheServiceTest();
  moonlightSensitiveTransferPolicyTest();
  moonlightCloudSyncSelectionPolicyTest();
  moonlightCloudSyncServiceTest();
  moonlightDataLifecycleBarrierTest();
  moonlightDeletionPolicyTest();
  moonlightCloudDeletionPolicyTest();
  moonlightDeletionCommandServiceTest();
  moonlightCloudStatusPolicyTest();
  moonlightBackupPolicyTest();
  moonlightReconnectPolicyTest();
  moonlightRuntimeContextFactoryTest();
  remoteSessionWindowPolicyTest();
  remoteSessionServiceLeasePolicyTest();
  moonlightNetworkHandlePolicyTest();
}
