import { ProAccess, ProEnvironment, ProVerifiedGrant, proFeatureAccess } from './ProAccessPolicy';

export interface ProOrderVerifier {
  verify(records: string[], owner: string, environment: ProEnvironment): Promise<ProVerifiedGrant | null>;
}
export class ProEntitlementService {
  private owner: string = '';
  private environment: ProEnvironment = 'production';
  private generation: number = 0;
  private grant: ProVerifiedGrant | null = null;
  private listeners: Array<() => void> = [];

  constructor(private verifier: ProOrderVerifier) {}

  bindAccount(owner: string, environment: ProEnvironment): void {
    this.generation++;
    this.owner = owner;
    this.environment = environment;
    this.grant = null;
    this.publish();
  }

  access(featureId: string): ProAccess {
    return proFeatureAccess(featureId, this.grant, this.owner, this.environment, Date.now());
  }

  async reconcile(records: string[]): Promise<boolean> {
    if (this.owner.length === 0) { return false; }
    const generation = ++this.generation;
    const owner = this.owner;
    const environment = this.environment;
    const verified = await this.verifier.verify(records.slice(), owner, environment);
    if (generation !== this.generation) { return false; }
    if (verified !== null && (verified.owner !== owner || verified.environment !== environment)) { return false; }
    this.grant = verified === null ? null : {
      owner: verified.owner, environment: verified.environment, productId: verified.productId,
      active: verified.active, validUntil: verified.validUntil, featureIds: verified.featureIds.slice()
    };
    this.publish();
    return this.grant !== null && this.grant.active;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }

  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => { listener(); });
  }
}
