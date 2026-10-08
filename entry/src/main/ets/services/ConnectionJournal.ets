import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME: string = 'RemoteDeskConnectionJournal-v1';
const STORE_KEY: string = 'entries';
const KEEP: number = 600;
const KEEP_MS: number = 45 * 24 * 3600 * 1000;
/** A reconnect to the same host within this window is the same visit. */
const SAME_VISIT_MS: number = 10 * 60 * 1000;

/** One connection: when, to which host (its name only), how, and whether it worked. */
export class ConnectionJournalEntry {
  at: number;
  owner: string;
  hostId: string;
  label: string;
  protocol: string;
  /** connected · failed */
  outcome: string;
  /** For a failure: what kind, in words ("网络或端口不通"). */
  detail: string;

  constructor(at: number, owner: string, hostId: string, label: string, protocol: string, outcome: string, detail: string) {
    this.at = at;
    this.owner = owner;
    this.hostId = hostId;
    this.label = label;
    this.protocol = protocol;
    this.outcome = outcome;
    this.detail = detail;
  }
}

/** The signed-in account's scope (set at start-up, so this file needs no account services). */
let ownerProvider: () => string = (): string => 'device-local';

function currentOwner(): string {
  try { return ownerProvider(); } catch (_error) { return 'device-local'; }
}

/**
 * 连接记录: the connections made from this device, kept only here (45 days) and per account — host names, protocols,
 * times and outcomes, never addresses or credentials. The AI chat reads it, when its tool is on, to write weekly
 * reports and host summaries.
 */
export class ConnectionJournal {
  private static context: common.Context | null = null;
  private static entries: ConnectionJournalEntry[] = [];
  private static loaded: boolean = false;

  static init(context: common.Context, owner: () => string): void {
    ConnectionJournal.context = context;
    ownerProvider = owner;
    ConnectionJournal.load();
  }

  static connected(hostId: string, label: string, protocol: string): void {
    const now: number = Date.now();
    const owner: string = currentOwner();
    const last: ConnectionJournalEntry | undefined = ConnectionJournal.entries.length > 0 ?
      ConnectionJournal.entries[ConnectionJournal.entries.length - 1] : undefined;
    if (last !== undefined && last.hostId === hostId && last.outcome === 'connected' && now - last.at < SAME_VISIT_MS) {
      return;
    }
    ConnectionJournal.add(new ConnectionJournalEntry(now, owner, hostId, label.slice(0, 80), protocol, 'connected', ''));
  }

  static failed(protocol: string, detail: string): void {
    ConnectionJournal.add(new ConnectionJournalEntry(Date.now(), currentOwner(), '', '', protocol, 'failed', detail.slice(0, 40)));
  }

  /** The current account's entries of the last `days` days, oldest first. */
  static recent(days: number): ConnectionJournalEntry[] {
    ConnectionJournal.load();
    const since: number = Date.now() - Math.max(1, Math.min(45, days)) * 24 * 3600 * 1000;
    const owner: string = currentOwner();
    return ConnectionJournal.entries.filter((entry: ConnectionJournalEntry): boolean => entry.owner === owner && entry.at >= since);
  }

  private static add(entry: ConnectionJournalEntry): void {
    ConnectionJournal.load();
    const cutoff: number = Date.now() - KEEP_MS;
    ConnectionJournal.entries = ConnectionJournal.entries.filter((item: ConnectionJournalEntry): boolean => item.at >= cutoff)
      .concat([entry]).slice(-KEEP);
    ConnectionJournal.save();
  }

  private static load(): void {
    if (ConnectionJournal.loaded || ConnectionJournal.context === null) { return; }
    ConnectionJournal.loaded = true;
    try {
      const prefs = preferences.getPreferencesSync(ConnectionJournal.context, { name: STORE_NAME });
      const parsed: Object = JSON.parse(prefs.getSync(STORE_KEY, '[]') as string) as Object;
      if (!Array.isArray(parsed)) { return; }
      ConnectionJournal.entries = (parsed as Object[]).map((item: Object): ConnectionJournalEntry => {
        const row = item as Record<string, Object>;
        const text = (key: string): string => typeof row[key] === 'string' ? row[key] as string : '';
        return new ConnectionJournalEntry(typeof row['at'] === 'number' ? row['at'] as number : 0, text('owner'), text('hostId'),
          text('label'), text('protocol'), text('outcome'), text('detail'));
      }).filter((entry: ConnectionJournalEntry): boolean => entry.at > 0).slice(-KEEP);
    } catch (_error) { ConnectionJournal.entries = []; }
  }

  private static save(): void {
    if (ConnectionJournal.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(ConnectionJournal.context, { name: STORE_NAME });
      prefs.putSync(STORE_KEY, JSON.stringify(ConnectionJournal.entries));
      prefs.flush();
    } catch (_error) { /* kept in memory for this run */ }
  }
}
