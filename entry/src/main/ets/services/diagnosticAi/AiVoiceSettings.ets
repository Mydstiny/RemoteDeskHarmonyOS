import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiagnosticAiSecretStore } from './DiagnosticAiSecretStore';

/** AppStorage mirror of AI 语音 (Beta) being on, so the chat can show its voice button without reading preferences. */
export const AI_VOICE_ENABLED: string = 'aiVoice.enabled';
/** AppStorage mirror of 按住 AI 按钮说话. */
export const AI_VOICE_HOLD: string = 'aiVoice.holdToTalk';

/** One speech engine the user can pick in AI 语音. */
export class AiTtsProvider {
  id: string;
  name: string;
  detail: string;
  /** Models to offer (the first is the default; any other name can be typed). */
  models: string[];
  /** [voice id, label] to offer (the first is the default). */
  voices: string[][];
  /** [base URL, label] presets (OpenAI 兼容 only). */
  baseUrls: string[][];
  needsKey: boolean;

  constructor(id: string, name: string, detail: string, models: string[], voices: string[][], baseUrls: string[][],
    needsKey: boolean) {
    this.id = id;
    this.name = name;
    this.detail = detail;
    this.models = models;
    this.voices = voices;
    this.baseUrls = baseUrls;
    this.needsKey = needsKey;
  }
}

export const AI_TTS_PROVIDERS: AiTtsProvider[] = [
  new AiTtsProvider('system', '系统', '鸿蒙本机语音，离线、免费，文字不离开手机', [],
    [['13', '聆小珊 · 女声'], ['21', '凌飞哲 · 男声（首次使用需下载）']], [], false),
  new AiTtsProvider('dashscope', '阿里云百炼', 'Qwen-TTS：自然的中文，也会说方言', ['qwen3-tts-flash', 'qwen-tts'],
    [['Cherry', '芊悦 · 女声'], ['Ethan', '晨煦 · 男声'], ['Serena', '苏瑶 · 女声'], ['Chelsie', '千雪 · 女声'],
      ['Dylan', '北京话 · 男声'], ['Jada', '上海话 · 女声'], ['Sunny', '四川话 · 女声']], [], true),
  new AiTtsProvider('minimax', 'MiniMax', 'Speech-02：情感丰富的拟人音色', ['speech-02-turbo', 'speech-02-hd'],
    [['female-shaonv', '少女'], ['female-yujie', '御姐'], ['female-chengshu', '成熟女性'], ['male-qn-qingse', '青涩青年'],
      ['male-qn-jingying', '精英青年'], ['presenter_female', '女主持人'], ['presenter_male', '男主持人']], [], true),
  new AiTtsProvider('openai', 'OpenAI 兼容', 'OpenAI、硅基流动等提供 /audio/speech 的服务',
    ['gpt-4o-mini-tts', 'tts-1', 'FunAudioLLM/CosyVoice2-0.5B'],
    [['alloy', 'alloy'], ['nova', 'nova'], ['shimmer', 'shimmer'], ['onyx', 'onyx'],
      ['FunAudioLLM/CosyVoice2-0.5B:anna', 'CosyVoice · anna'], ['FunAudioLLM/CosyVoice2-0.5B:alex', 'CosyVoice · alex']],
    [['https://api.openai.com/v1', 'OpenAI'], ['https://api.siliconflow.cn/v1', '硅基流动']], true)
];

export function aiTtsProvider(id: string): AiTtsProvider {
  return AI_TTS_PROVIDERS.find((provider: AiTtsProvider): boolean => provider.id === id) ?? AI_TTS_PROVIDERS[0];
}

/** 语速 → the engines' speed factor. */
export function aiVoiceSpeed(rate: string): number {
  return rate === 'slow' ? 0.85 : rate === 'fast' ? 1.2 : 1;
}

/** Everything AI 语音 needs to speak, read once (the key stays in the secret store until a request needs it). */
export class AiVoiceConfig {
  enabled: boolean = false;
  provider: string = 'system';
  rate: string = 'normal';
  model: string = '';
  voice: string = '';
  baseUrl: string = '';
  groupId: string = '';
  continuous: boolean = true;
  holdToTalk: boolean = true;
  /** A cloud engine is chosen and has a key; otherwise speech falls back to the system voice. */
  hasKey: boolean = false;
}

function scopeKey(owner: string): string {
  const normalized: string = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function secretRef(provider: string): string {
  return 'tts-' + provider;
}

/**
 * 设置 › AI 语音 (Beta), per account on this device. Off until the user turns it on; the speech engine is the system
 * voice until another one is chosen and given a key. API keys live in the same AssetStore-backed secret store as the
 * AI service keys; only their fingerprints are kept here.
 */
export class AiVoiceSettings {
  private context: common.Context | null = null;
  private prefsName: string = '';

  init(context: common.Context, owner: string): void {
    this.context = context;
    this.prefsName = 'RemoteDeskAiVoice-' + scopeKey(owner);
  }

  private prefs(): preferences.Preferences | null {
    if (this.context === null) { return null; }
    try { return preferences.getPreferencesSync(this.context, { name: this.prefsName }); } catch (_error) { return null; }
  }

  private text(key: string, fallback: string): string {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return fallback; }
    try {
      const value: preferences.ValueType = prefs.getSync(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (_error) { return fallback; }
  }

  private flag(key: string, fallback: boolean): boolean {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return fallback; }
    try {
      const value: preferences.ValueType = prefs.getSync(key, fallback);
      return typeof value === 'boolean' ? value : fallback;
    } catch (_error) { return fallback; }
  }

  private put(key: string, value: preferences.ValueType): void {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) { return; }
    try { prefs.putSync(key, value); prefs.flush(); } catch (_error) { /* kept for this run only */ }
  }

  read(): AiVoiceConfig {
    const config: AiVoiceConfig = new AiVoiceConfig();
    config.enabled = this.flag('enabled', false);
    config.provider = aiTtsProvider(this.text('provider', 'system')).id;
    config.rate = this.text('rate', 'normal');
    const provider: AiTtsProvider = aiTtsProvider(config.provider);
    config.model = this.text(config.provider + '.model', provider.models.length > 0 ? provider.models[0] : '');
    config.voice = this.text(config.provider + '.voice', provider.voices.length > 0 ? provider.voices[0][0] : '');
    config.baseUrl = this.text(config.provider + '.baseUrl', provider.baseUrls.length > 0 ? provider.baseUrls[0][0] : '');
    config.groupId = this.text(config.provider + '.groupId', '');
    config.continuous = this.flag('continuous', true);
    config.holdToTalk = this.flag('holdToTalk', true);
    config.hasKey = provider.needsKey && this.keyFingerprint(config.provider) !== '';
    AppStorage.setOrCreate(AI_VOICE_ENABLED, config.enabled);
    AppStorage.setOrCreate(AI_VOICE_HOLD, config.enabled && config.holdToTalk);
    return config;
  }

  setEnabled(on: boolean): void { this.put('enabled', on); this.read(); }
  setProvider(id: string): void { this.put('provider', aiTtsProvider(id).id); }
  setRate(rate: string): void { this.put('rate', rate === 'slow' || rate === 'fast' ? rate : 'normal'); }
  setContinuous(on: boolean): void { this.put('continuous', on); }
  setHoldToTalk(on: boolean): void { this.put('holdToTalk', on); this.read(); }
  setModel(provider: string, model: string): void { this.put(provider + '.model', model.trim().slice(0, 120)); }
  setVoice(provider: string, voice: string): void { this.put(provider + '.voice', voice.trim().slice(0, 120)); }
  setBaseUrl(provider: string, url: string): void { this.put(provider + '.baseUrl', url.trim().replace(/\/+$/, '').slice(0, 300)); }
  setGroupId(provider: string, groupId: string): void { this.put(provider + '.groupId', groupId.trim().slice(0, 64)); }

  /** Saves a key; '' keeps the one already saved. False when the secret store refused it. */
  saveKey(provider: string, key: string): boolean {
    const value: string = key.trim();
    if (value === '') { return true; }
    const store: DiagnosticAiSecretStore = DiagnosticAiSecretStore.getInstance();
    return store.put(secretRef(provider), value) !== null && store.get(secretRef(provider)) === value;
  }

  removeKey(provider: string): void { DiagnosticAiSecretStore.getInstance().remove(secretRef(provider)); }

  /** The saved key's short fingerprint ('' none), for 已保存 ••••. */
  keyFingerprint(provider: string): string {
    const meta = DiagnosticAiSecretStore.getInstance().metadataFor(secretRef(provider));
    return meta !== null ? meta.fingerprint : '';
  }

  /** The key itself, only when a request is about to be sent. */
  key(provider: string): string { return DiagnosticAiSecretStore.getInstance().get(secretRef(provider)); }
}
