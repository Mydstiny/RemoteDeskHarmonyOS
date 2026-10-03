import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AI_DEFAULT_SKILLS, AI_SKILL_LIBRARY, AI_TOOLS, AiSkill, AiToolSpec } from './AiSkillCatalog';

function scopeKey(owner: string): string {
  const normalized: string = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function skillFrom(item: Object): AiSkill | null {
  if (item === null || typeof item !== 'object') { return null; }
  const row = item as Record<string, Object>;
  const field = (key: string): string => typeof row[key] === 'string' ? row[key] as string : '';
  const keywords: string[] = Array.isArray(row['keywords']) ?
    (row['keywords'] as Object[]).map((word: Object): string => String(word)).slice(0, 12) : [];
  if (field('id') === '' || field('name') === '' || field('instructions') === '') { return null; }
  return new AiSkill(field('id'), field('name').slice(0, 20), field('description').slice(0, 80),
    field('instructions').slice(0, 4000), field('starter').slice(0, 200), keywords,
    field('source') === 'file' ? 'file' : 'custom', row['needsDocument'] === true);
}

/**
 * Which tools are on and which skills are installed, per account, on this device only. Until the user changes
 * anything, every tool is on as declared and the default skills are installed.
 */
export class AiSkillStore {
  private context: common.Context | null = null;
  private prefsName: string = '';

  init(context: common.Context, owner: string): void {
    this.context = context;
    this.prefsName = 'RemoteDeskAiSkills-' + scopeKey(owner);
  }

  private prefs(): preferences.Preferences | null {
    if (this.context === null) { return null; }
    try { return preferences.getPreferencesSync(this.context, { name: this.prefsName }); } catch (_error) { return null; }
  }

  private read(key: string, fallback: string): string {
    const store = this.prefs();
    if (store === null) { return fallback; }
    try { return store.getSync(key, fallback) as string; } catch (_error) { return fallback; }
  }

  private write(key: string, value: string): boolean {
    const store = this.prefs();
    if (store === null) { return false; }
    try { store.putSync(key, value); store.flushSync(); return true; } catch (_error) { return false; }
  }

  // ------------------------------------------------------------------ tools

  private toolOverrides(): Record<string, boolean> {
    try {
      const parsed: Object = JSON.parse(this.read('tools', '{}')) as Object;
      return parsed !== null && typeof parsed === 'object' ? parsed as Record<string, boolean> :
        JSON.parse('{}') as Record<string, boolean>;
    } catch (_error) { return JSON.parse('{}') as Record<string, boolean>; }
  }

  toolEnabled(id: string): boolean {
    const value: boolean | undefined = this.toolOverrides()[id];
    if (typeof value === 'boolean') { return value; }
    const tool: AiToolSpec | undefined = AI_TOOLS.find((t: AiToolSpec): boolean => t.id === id);
    return tool !== undefined && tool.defaultOn;
  }

  setToolEnabled(id: string, enabled: boolean): boolean {
    const overrides: Record<string, boolean> = this.toolOverrides();
    overrides[id] = enabled;
    return this.write('tools', JSON.stringify(overrides));
  }

  enabledTools(): AiToolSpec[] {
    return AI_TOOLS.filter((tool: AiToolSpec): boolean => this.toolEnabled(tool.id));
  }

  // ------------------------------------------------------------------ skills

  private installedIds(): string[] {
    try {
      const parsed: Object = JSON.parse(this.read('installed', JSON.stringify(AI_DEFAULT_SKILLS))) as Object;
      return Array.isArray(parsed) ? (parsed as Object[]).map((id: Object): string => String(id)).slice(0, 64) : AI_DEFAULT_SKILLS.slice();
    } catch (_error) { return AI_DEFAULT_SKILLS.slice(); }
  }

  customSkills(): AiSkill[] {
    try {
      const parsed: Object = JSON.parse(this.read('custom', '[]')) as Object;
      if (!Array.isArray(parsed)) { return []; }
      return (parsed as Object[]).map((item: Object): AiSkill | null => skillFrom(item))
        .filter((skill: AiSkill | null): boolean => skill !== null).map((skill: AiSkill | null): AiSkill => skill as AiSkill)
        .slice(0, 32);
    } catch (_error) { return []; }
  }

  /** Installed skills: the library's in library order, then the user's own, newest last. */
  installedSkills(): AiSkill[] {
    const ids: string[] = this.installedIds();
    return AI_SKILL_LIBRARY.filter((skill: AiSkill): boolean => ids.indexOf(skill.id) >= 0).concat(this.customSkills());
  }

  /** Library skills not installed yet. */
  availableSkills(): AiSkill[] {
    const ids: string[] = this.installedIds();
    return AI_SKILL_LIBRARY.filter((skill: AiSkill): boolean => ids.indexOf(skill.id) < 0);
  }

  install(id: string): boolean {
    const ids: string[] = this.installedIds().filter((value: string): boolean => value !== id);
    ids.push(id);
    return this.write('installed', JSON.stringify(ids));
  }

  uninstall(id: string): boolean {
    if (id.startsWith('custom-') || id.startsWith('file-')) {
      return this.write('custom', JSON.stringify(this.customSkills().filter((skill: AiSkill): boolean => skill.id !== id)));
    }
    return this.write('installed', JSON.stringify(this.installedIds().filter((value: string): boolean => value !== id)));
  }

  /** Add or replace one of the user's own skills. */
  saveCustom(skill: AiSkill): boolean {
    const rows: AiSkill[] = this.customSkills().filter((item: AiSkill): boolean => item.id !== skill.id);
    rows.push(skill);
    return this.write('custom', JSON.stringify(rows.slice(-32)));
  }
}
