import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { ownerScopeIdForUnionId } from '../AccountScopePolicy';

interface ProSessionReply { sessionToken: string; owner: string; expiresAt: number; challenge: string; }
type ProSessionRequest = (body: string, isCurrent: () => boolean) => Promise<string>;

// Memory-only request authentication. This object never stores vendor tokens,
// changes the application's login, or supplies a local Pro entitlement.
export class ProAccountSession {
  private context: common.Context;
  private request: ProSessionRequest;
  private epoch: number = 0;
  private token: string = '';
  private key: string = '';
  private expiresAt: number = 0;
  private elapsedUntil: number = 0;
  private lastWall: number = 0;
  private lastElapsed: number = 0;
  private pending: Promise<string> | null = null;
  private pendingKey: string = '';
  constructor(context: common.Context, request: ProSessionRequest) { this.context = context; this.request = request; }
  private elapsed(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false); }
  clear(): void {
    this.epoch++; this.token = ''; this.key = ''; this.pending = null; this.pendingKey = '';
    this.expiresAt = 0; this.elapsedUntil = 0; this.lastWall = 0; this.lastElapsed = 0;
  }
  invalidate(token: string): void { if (this.token === token) { this.token = ''; } }
  async get(owner: string, generation: number, isCurrent: () => boolean): Promise<string> {
    if (!/^owner-[a-f0-9]{64}$/.test(owner) || !Number.isSafeInteger(generation) || !isCurrent()) {
      throw new Error('Pro account login required');
    }
    const key = owner + ':' + generation.toString();
    const wall = Date.now(); const elapsed = this.elapsed();
    if (this.key === key && this.token.length > 0 && Number.isSafeInteger(wall) && Number.isSafeInteger(elapsed) &&
      wall >= this.lastWall && elapsed >= this.lastElapsed && wall < this.expiresAt && elapsed < this.elapsedUntil) {
      this.lastWall = wall; this.lastElapsed = elapsed; return this.token;
    }
    if (this.pending !== null && this.pendingKey === key) {
      const token = await this.pending;
      if (!isCurrent() || this.key !== key || this.token !== token) { throw new Error('Pro account changed'); }
      return token;
    }
    this.clear();
    const epoch = this.epoch; this.pendingKey = key;
    const pending = this.authorize(owner, key, epoch, isCurrent);
    this.pending = pending;
    try { return await pending; }
    finally { if (this.pending === pending) { this.pending = null; this.pendingKey = ''; } }
  }
  private async authorize(owner: string, key: string, epoch: number, isCurrent: () => boolean): Promise<string> {
    const current = (): boolean => epoch === this.epoch && isCurrent();
    const random = await cryptoFramework.createRandom().generateRandom(32);
    const challenge = new util.Base64Helper().encodeToStringSync(random.data)
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    if (!current()) { throw new Error('Pro account changed'); }
    const request = new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
    request.forceAuthorization = false; request.scopes = ['openid']; request.permissions = ['serviceauthcode'];
    request.state = challenge;
    const controller = new authentication.AuthenticationController(this.context);
    let timer: number = -1;
    let response: authentication.AuthorizationWithHuaweiIDResponse | null = null;
    try {
      response = await Promise.race([
        controller.executeRequest(request),
        new Promise<null>((resolve: (value: null) => void): void => {
          timer = setTimeout((): void => { resolve(null); }, 10000);
        })
      ]) as authentication.AuthorizationWithHuaweiIDResponse | null;
    } finally { if (timer !== -1) { clearTimeout(timer); } }
    if (!current() || response === null || response.state !== challenge || !response.data ||
      ownerScopeIdForUnionId(response.data.unionID ?? '') !== owner) { throw new Error('Pro account changed'); }
    const code = response.data.authorizationCode ?? '';
    if (typeof code !== 'string' || code.length === 0 || new util.TextEncoder().encodeInto(code).length > 8192 ||
      /[\u0000-\u001f\u007f]/.test(code)) { throw new Error('Pro account login required'); }
    const text = await this.request(JSON.stringify({ authorizationCode: code, challenge }), current);
    if (!current() || typeof text !== 'string' || text.length > 8192) { throw new Error('Pro account changed'); }
    const reply = JSON.parse(text) as ProSessionReply;
    const wall = Date.now(); const elapsed = this.elapsed();
    if (!reply || Object.keys(reply).length !== 4 || reply.owner !== owner || reply.challenge !== challenge ||
      typeof reply.sessionToken !== 'string' || reply.sessionToken.length > 4096 ||
      !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(reply.sessionToken) ||
      !Number.isSafeInteger(reply.expiresAt) || !Number.isSafeInteger(wall) || wall <= 0 ||
      !Number.isSafeInteger(elapsed) || elapsed < 0 || reply.expiresAt <= wall + 30000 || reply.expiresAt - wall > 660000) {
      throw new Error('Invalid Pro account session');
    }
    const lifetime = Math.min(reply.expiresAt - wall, 600000) - 30000;
    if (!Number.isSafeInteger(elapsed + lifetime)) { throw new Error('Invalid Pro account clock'); }
    this.key = key; this.token = reply.sessionToken; this.expiresAt = wall + lifetime;
    this.elapsedUntil = elapsed + lifetime; this.lastWall = wall; this.lastElapsed = elapsed;
    return this.token;
  }
}
