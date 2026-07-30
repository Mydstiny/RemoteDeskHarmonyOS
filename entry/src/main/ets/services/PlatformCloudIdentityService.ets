import {
  abilityAccessCtrl,
  common,
  PermissionRequestResult,
  Permissions
} from '@kit.AbilityKit';
import { distributedAccount } from '@kit.BasicServicesKit';
import {
  PlatformCloudIdentityProof,
  platformCloudIdentityProofFromApi23,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';

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
        if (!requested.authResults ||
          requested.authResults.length !== 1 ||
          requested.authResults[0] !== 0) {
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
