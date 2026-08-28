import {
  abilityAccessCtrl,
  common,
  PermissionRequestResult,
  Permissions
} from '@kit.AbilityKit';
import { distributedAccount } from '@kit.BasicServicesKit';
import {
  PlatformCloudIdentityProof,
  PlatformCloudPermissionRequestDecision,
  platformCloudIdentityProofFromApi23,
  platformCloudPermissionRequestDecision,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DISTRIBUTED_DATA_PERMISSION: Permissions =
  'ohos.permission.DISTRIBUTED_DATASYNC' as Permissions;

/**
 * Reads an identity from the platform account service independently from
 * Account Kit. Failure to obtain the user-granted permission, a logged-in
 * distributed account, or a stable platform id always fails closed.
 */
export class PlatformCloudIdentityService {
  private static instance: PlatformCloudIdentityService;

  static getInstance(): PlatformCloudIdentityService {
    if (!PlatformCloudIdentityService.instance) {
      PlatformCloudIdentityService.instance =
        new PlatformCloudIdentityService();
    }
    return PlatformCloudIdentityService.instance;
  }

  async proveCurrentCloudAccount(
    context: common.Context,
    accountKitUnionId: string
  ): Promise<PlatformCloudIdentityProof> {
    const uiContext: common.UIAbilityContext =
      context as common.UIAbilityContext;
    try {
      const manager: abilityAccessCtrl.AtManager =
        abilityAccessCtrl.createAtManager();
      const tokenId: number =
        uiContext.applicationInfo.accessTokenId;
      if (!tokenId) {
        return unavailablePlatformCloudIdentityProof(
          'identity_unavailable');
      }
      const current: abilityAccessCtrl.GrantStatus =
        manager.checkAccessTokenSync(
          tokenId, DISTRIBUTED_DATA_PERMISSION);
      if (current !==
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        const requested: PermissionRequestResult =
          await manager.requestPermissionsFromUser(
            uiContext, [DISTRIBUTED_DATA_PERMISSION]);
        const authResult: number =
          requested.authResults &&
          requested.authResults.length === 1
            ? requested.authResults[0] : -1;
        const dialogShown: boolean | null =
          requested.dialogShownResults &&
          requested.dialogShownResults.length === 1
            ? requested.dialogShownResults[0] : null;
        const errorReason: number | null =
          requested.errorReasons &&
          requested.errorReasons.length === 1
            ? requested.errorReasons[0] : null;
        const decision: PlatformCloudPermissionRequestDecision =
          platformCloudPermissionRequestDecision(
          authResult, dialogShown, errorReason);
        if (decision === 'retryable' ||
            decision === 'retryable_dialog') {
          hilog.warn(0x0001, 'PlatformCloudIdentity',
            '分布式数据权限暂不可请求，将在前台稳定后重试' +
            ' auth=' + authResult.toString() +
            ' dialog=' + (dialogShown === null
              ? 'unknown' : dialogShown.toString()) +
            ' reason=' + (errorReason === null
              ? 'unknown' : errorReason.toString()));
          return unavailablePlatformCloudIdentityProof(
            decision === 'retryable_dialog'
              ? 'permission_dialog_blocked'
              : 'permission_unavailable');
        }
        if (decision !== 'granted') {
          return unavailablePlatformCloudIdentityProof(
            'permission_denied');
        }
      }
      const info: distributedAccount.DistributedInfo =
        await distributedAccount.getDistributedAccountAbility()
          .getOsAccountDistributedInfo();
      if (!info.id || info.id.trim() === '') {
        return unavailablePlatformCloudIdentityProof(
          'identity_unavailable');
      }
      return platformCloudIdentityProofFromApi23(
        info.id,
        info.status ===
          distributedAccount.DistributedAccountStatus.LOGGED_IN);
    } catch (_error) {
      return unavailablePlatformCloudIdentityProof(
        'platform_error');
    }
  }
}
