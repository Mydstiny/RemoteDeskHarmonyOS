/**
 * UserAccount.ets — 华为账号用户模型
 * ArkTS strict mode: toJSON 构建 step-by-step
 */

export interface UserAccountJSON {
  unionId: string
  displayName: string
  avatarUrl: string
  isLoggedIn: boolean
  // authToken: 存储在应用沙箱内 (Preferences), HarmonyOS 文件级隔离提供基础保护。
  // 未来版本可考虑 HUKS 加密存储以提供硬件级安全性。
  authToken: string
  loginTime: number
}

export class UserAccount {
  unionId: string = '';
  displayName: string = '';
  avatarUrl: string = '';
  isLoggedIn: boolean = false;
  authToken: string = '';
  loginTime: number = 0;

  setLoggedIn(unionId: string, displayName: string, avatarUrl: string, token: string): void {
    this.unionId = unionId;
    this.displayName = displayName;
    this.avatarUrl = avatarUrl;
    this.authToken = token;
    this.isLoggedIn = true;
    this.loginTime = Date.now();
  }

  setLoggedOut(): void {
    this.isLoggedIn = false;
    this.authToken = '';
  }

  toJSON(): UserAccountJSON {
    return {
      unionId: this.unionId,
      displayName: this.displayName,
      avatarUrl: this.avatarUrl,
      isLoggedIn: this.isLoggedIn,
      authToken: this.authToken,
      loginTime: this.loginTime
    };
  }

  static fromJSON(json: UserAccountJSON): UserAccount {
    const acc: UserAccount = new UserAccount();
    if (json.unionId) { acc.unionId = json.unionId; }
    if (json.displayName) { acc.displayName = json.displayName; }
    if (json.avatarUrl) { acc.avatarUrl = json.avatarUrl; }
    if (json.isLoggedIn !== undefined) { acc.isLoggedIn = json.isLoggedIn; }
    if (json.authToken) { acc.authToken = json.authToken; }
    if (json.loginTime) { acc.loginTime = json.loginTime; }
    return acc;
  }
}
