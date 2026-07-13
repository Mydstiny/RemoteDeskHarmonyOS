/**
 * AuthService.ets — 华为账号认证服务
 * 封装 HMS Account Kit 登录状态管理
 */
import { UserAccount } from '../model/UserAccount';

export class AuthService {
  private static instance: AuthService;
  private currentUser: UserAccount = new UserAccount();

  static getInstance(): AuthService {
    if (!AuthService.instance) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  isLoggedIn(): boolean {
    return this.currentUser.isLoggedIn;
  }

  getCurrentUser(): UserAccount {
    return this.currentUser;
  }

  getUnionId(): string {
    return this.currentUser.unionId;
  }

  getDisplayName(): string {
    return this.currentUser.displayName;
  }

  getAccessToken(): string {
    return this.currentUser.authToken;
  }

  getAvatarUrl(): string {
    return this.currentUser.avatarUrl;
  }

  /**
   * 记录 HMS 登录成功
   */
  setLoginResult(unionId: string, displayName: string, avatarUrl: string, token: string): void {
    this.currentUser.setLoggedIn(unionId, displayName, avatarUrl, token);
  }

  async logout(): Promise<void> {
    this.currentUser.setLoggedOut();
  }
}
