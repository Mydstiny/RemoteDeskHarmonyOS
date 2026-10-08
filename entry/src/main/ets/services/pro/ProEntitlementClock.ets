import { systemDateTime } from '@kit.BasicServicesKit';

// STARTUP includes deep sleep. A stalled wall clock cannot extend a signed
// lifetime while the process lives; a backward clock requires fresh service
// verification. Persisted observations cover ordinary app restarts.
export class ProEntitlementClock {
  private wall: () => number;
  private uptime: () => number;
  private originWall: number = 0;
  private originUptime: number = 0;
  private previousWall: number = 0;
  private previousUptime: number = 0;
  private blocked: boolean = false;
  constructor(wall: () => number = (): number => Date.now(), uptime: () => number = (): number =>
    systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false)) {
    this.wall = wall; this.uptime = uptime;
    this.resetAfterOnlineVerification();
  }
  wallNow(): number { return this.wall(); }
  now(): number {
    const wall = this.wall();
    let uptime: number;
    try { uptime = this.uptime(); } catch (_error) { this.blocked = true; return Number.NaN; }
    if (!Number.isSafeInteger(wall) || !Number.isSafeInteger(uptime) || wall <= 0 || uptime < 0 ||
      wall < this.previousWall || uptime < this.previousUptime) { this.blocked = true; }
    if (this.blocked) { return Number.NaN; }
    this.previousWall = wall; this.previousUptime = uptime;
    const now = Math.max(wall, this.originWall + uptime - this.originUptime);
    if (!Number.isSafeInteger(now)) { this.blocked = true; return Number.NaN; }
    return now;
  }
  resetAfterOnlineVerification(): void {
    this.originWall = this.wall();
    try { this.originUptime = this.uptime(); } catch (_error) { this.originUptime = Number.NaN; }
    this.previousWall = this.originWall; this.previousUptime = this.originUptime;
    this.blocked = !Number.isSafeInteger(this.originWall) || this.originWall <= 0 ||
      !Number.isSafeInteger(this.originUptime) || this.originUptime < 0;
  }
}
