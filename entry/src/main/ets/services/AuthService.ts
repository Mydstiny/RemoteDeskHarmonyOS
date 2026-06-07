import { BusinessError } from '@kit.BasicServicesKit';

export interface AuthUser {
  unionId: string;
  displayName: string;
  avatarUri: string;
  idToken: string;
}

export class AuthService {
  private static instance: AuthService;
  private currentUser: AuthUser | null = null;
  private isLoggedIn: boolean = false;

  static getInstance(): AuthService {
    if (!this.instance) {
      this.instance = new AuthService();
    }
    return this.instance;
  }

  async login(): Promise<AuthUser> {
    try {
      const { authentication } = await import('@hms.core.hwid');
      const authParams = new authentication.HuaweiIdAuthParamsHelper()
        .setProfile()
        .setIdToken()
        .setAuthorizationCode()
        .createParams();
      const service = await authentication.HuaweiIdAuthManager
        .getService(getContext(), authParams);
      const result = await service.signIn();
      this.currentUser = {
        unionId: result.getUnionId(),
        displayName: result.getDisplayName() ?? '',
        avatarUri: result.getAvatarUri() ?? '',
        idToken: result.getIdToken() ?? ''
      };
      this.isLoggedIn = true;
      console.info('AuthService login success: ' + this.currentUser.displayName);
      return this.currentUser;
    } catch (err) {
      console.error('AuthService login failed: ' + err);
      throw err;
    }
  }

  async logout(): Promise<void> {
    try {
      const { authentication } = await import('@hms.core.hwid');
      const service = await authentication.HuaweiIdAuthManager
        .getService(getContext(), undefined);
      await service.signOut();
      this.currentUser = null;
      this.isLoggedIn = false;
      console.info('AuthService logout success');
    } catch (err) {
      console.error('AuthService logout failed: ' + err);
      throw err;
    }
  }

  async silentLogin(): Promise<AuthUser | null> {
    try {
      const { authentication } = await import('@hms.core.hwid');
      const authParams = new authentication.HuaweiIdAuthParamsHelper()
        .setProfile().setIdToken().createParams();
      const service = await authentication.HuaweiIdAuthManager
        .getService(getContext(), authParams);
      const result = await service.silentSignIn();
      this.currentUser = {
        unionId: result.getUnionId(),
        displayName: result.getDisplayName() ?? '',
        avatarUri: result.getAvatarUri() ?? '',
        idToken: result.getIdToken() ?? ''
      };
      this.isLoggedIn = true;
      return this.currentUser;
    } catch (err) {
      console.info('Silent login not available, user may need to sign in');
      return null;
    }
  }

  getUser(): AuthUser | null {
    return this.currentUser;
  }

  isLoggedInStatus(): boolean {
    return this.isLoggedIn;
  }
}
