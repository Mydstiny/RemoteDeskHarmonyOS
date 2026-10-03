import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { aiEnsurePermission } from './AiSystemTools';
import { aiSpeechText } from './AiMarkdownPolicy';
import { AiVoiceConfig, AiVoiceSettings, aiVoiceSpeed } from './AiVoiceSettings';

/** 16 kHz, mono, 16-bit: what the recognizer takes, in the 1280-byte (40 ms) pieces it accepts. */
const ASR_CHUNK_BYTES: number = 1280;
/** After speech, this much quiet ends the sentence; with no speech at all, the session gives up after NO_SPEECH_MS. */
const ASR_TRAILING_QUIET_MS: number = 1400;
const ASR_NO_SPEECH_MS: number = 6000;
const ASR_MAX_MS: number = 58000;
/** Level (0…1) above which the microphone counts as hearing speech. */
const ASR_SPEECH_LEVEL: number = 0.36;
/** A cloud request is cut into pieces of about this many characters at sentence ends, so speaking starts early. */
const TTS_PIECE_CHARS: number = 220;
const TTS_TIMEOUT_MS: number = 30000;

/** Microphone loudness of one PCM buffer as 0…1 (about −55 dBFS → 0, −15 dBFS → 1). */
export function aiPcmLevel(buffer: ArrayBuffer): number {
  const samples: Int16Array = new Int16Array(buffer, 0, Math.floor(buffer.byteLength / 2));
  if (samples.length === 0) { return 0; }
  let sum: number = 0;
  for (let i = 0; i < samples.length; i++) { sum += samples[i] * samples[i]; }
  const rms: number = Math.sqrt(sum / samples.length);
  if (rms <= 0) { return 0; }
  const db: number = 20 * Math.log10(rms / 32768);
  return Math.min(1, Math.max(0, (db + 55) / 40));
}

/** Cuts spoken text into pieces of at most `limit` characters, at sentence ends where it can. */
export function aiSpeechPieces(text: string, limit: number): string[] {
  const sentences: string[] = [];
  let sentence: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    sentence += ch;
    if ('。！？!?；;\n'.indexOf(ch) >= 0) {
      if (sentence.trim() !== '') { sentences.push(sentence.trim()); }
      sentence = '';
    }
  }
  if (sentence.trim() !== '') { sentences.push(sentence.trim()); }
  const pieces: string[] = [];
  let current: string = '';
  sentences.forEach((one: string): void => {
    let rest: string = one;
    while (rest.length > limit) {
      if (current !== '') { pieces.push(current); current = ''; }
      const comma: number = Math.max(rest.lastIndexOf('，', limit), rest.lastIndexOf(',', limit));
      const cut: number = comma > limit * 0.4 ? comma + 1 : limit;
      pieces.push(rest.slice(0, cut));
      rest = rest.slice(cut);
    }
    if (current !== '' && current.length + rest.length > limit) { pieces.push(current); current = ''; }
    current += rest;
  });
  if (current !== '') { pieces.push(current); }
  return pieces;
}

/**
 * Dictation for the AI chat and voice mode, on the device (Chinese). The app records the microphone itself and feeds
 * the recognizer, so it knows how loud the user is (onLevel drives the voice animation) and when they stopped
 * talking. If the microphone cannot be opened that way, the recognizer records on its own (no levels).
 */
export class AiVoiceInput {
  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static sessionId: string = '';
  private static capturer: audio.AudioCapturer | null = null;
  private static finishing: boolean = false;

  static available(): boolean { return canIUse('SystemCapability.AI.SpeechRecognizer'); }

  /**
   * Listen until the speaker stops (or stop() is called). onText gets the words so far (final once isFinal); onEnd
   * comes once, with '' or what went wrong; onLevel gets the microphone level about every 20 ms (0 at the end).
   */
  static async start(context: common.UIAbilityContext, onText: (text: string, final: boolean) => void,
    onEnd: (problem: string) => void, onLevel: (level: number) => void = (_level: number): void => {}): Promise<void> {
    if (!AiVoiceInput.available()) { onEnd('当前设备不支持语音输入'); return; }
    if (!(await aiEnsurePermission(context, 'ohos.permission.MICROPHONE'))) { onEnd('没有麦克风权限'); return; }
    try {
      if (AiVoiceInput.engine === null) {
        AiVoiceInput.engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
      }
      const engine: speechRecognizer.SpeechRecognitionEngine = AiVoiceInput.engine;
      if (engine.isBusy()) {
        engine.cancel(AiVoiceInput.sessionId);
        // The cancel finishes in the speech service: a session started at once can end before it hears anything.
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 180); });
      }
      await AiVoiceInput.closeCapturer();
      const sessionId: string = 'rd-asr-' + Date.now().toString();
      AiVoiceInput.sessionId = sessionId;
      AiVoiceInput.finishing = false;
      let ended: boolean = false;
      const end = (problem: string): void => {
        if (ended) { return; }
        ended = true;
        void AiVoiceInput.closeCapturer();
        onLevel(0);
        onEnd(problem);
      };
      engine.setListener({
        onStart: (_id: string, _message: string): void => { /* listening */ },
        onEvent: (_id: string, _code: number, _message: string): void => { /* speech began / ended */ },
        onResult: (id: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (id === sessionId) { onText(result.result, result.isFinal); }
        },
        onComplete: (id: string, _message: string): void => { if (id === sessionId) { end(''); } },
        onError: (id: string, code: number, message: string): void => {
          hilog.warn(0x0000, 'AiChat', 'asr error %{public}s %{public}s', code.toString(), message);
          if (id === sessionId) { end('没有听清，请再说一次'); }
        }
      });
      const capturer: audio.AudioCapturer | null = await AiVoiceInput.openCapturer();
      const extra: Record<string, Object> = {};
      extra['maxAudioDuration'] = 60000;
      if (capturer === null) {
        // 0: the engine records from the microphone itself; a pause of 2 s ends the sentence.
        extra['recognitionMode'] = 0;
        extra['vadBegin'] = 2500;
        extra['vadEnd'] = 2000;
        engine.startListening({ sessionId: sessionId,
          audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }, extraParams: extra });
        return;
      }
      // 1: the app writes the audio; it also decides when the user has finished.
      extra['recognitionMode'] = 1;
      extra['vadBegin'] = 10000;
      extra['vadEnd'] = 3000;
      engine.startListening({ sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }, extraParams: extra });
      const startedAt: number = Date.now();
      let heardAt: number = 0;
      let lastVoiceAt: number = 0;
      let pending: Uint8Array = new Uint8Array(0);
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        if (ended || AiVoiceInput.finishing || sessionId !== AiVoiceInput.sessionId) { return; }
        const level: number = aiPcmLevel(buffer);
        onLevel(level);
        const now: number = Date.now();
        if (level >= ASR_SPEECH_LEVEL) {
          if (heardAt === 0) { heardAt = now; }
          lastVoiceAt = now;
        }
        const joined: Uint8Array = new Uint8Array(pending.length + buffer.byteLength);
        joined.set(pending, 0);
        joined.set(new Uint8Array(buffer), pending.length);
        let offset: number = 0;
        try {
          while (joined.length - offset >= ASR_CHUNK_BYTES) {
            engine.writeAudio(sessionId, joined.slice(offset, offset + ASR_CHUNK_BYTES));
            offset += ASR_CHUNK_BYTES;
          }
        } catch (error) {
          hilog.warn(0x0000, 'AiChat', 'asr write failed %{public}s', String((error as BusinessError).code));
          end('语音输入中断了');
          return;
        }
        pending = joined.slice(offset);
        const quietAfterSpeech: boolean = heardAt > 0 && now - lastVoiceAt > ASR_TRAILING_QUIET_MS;
        const nothingSaid: boolean = heardAt === 0 && now - startedAt > ASR_NO_SPEECH_MS;
        if (quietAfterSpeech || nothingSaid || now - startedAt > ASR_MAX_MS) { AiVoiceInput.stop(); }
      });
      await capturer.start();
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'asr start failed %{public}s', String((error as BusinessError).code));
      await AiVoiceInput.closeCapturer();
      onLevel(0);
      onEnd('语音输入启动失败');
    }
  }

  private static async openCapturer(): Promise<audio.AudioCapturer | null> {
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 }
      };
      const capturer: audio.AudioCapturer = await audio.createAudioCapturer(options);
      AiVoiceInput.capturer = capturer;
      return capturer;
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'capturer unavailable %{public}s', String((error as BusinessError).code));
      return null;
    }
  }

  private static async closeCapturer(): Promise<void> {
    const capturer: audio.AudioCapturer | null = AiVoiceInput.capturer;
    AiVoiceInput.capturer = null;
    if (capturer === null) { return; }
    try { capturer.off('readData'); } catch (_error) { /* not listening */ }
    try { await capturer.stop(); } catch (_error) { /* not started */ }
    try { await capturer.release(); } catch (_error) { /* already released */ }
  }

  /** The user is done: recognize what was said so far. */
  static stop(): void {
    if (AiVoiceInput.finishing) { return; }
    AiVoiceInput.finishing = true;
    void AiVoiceInput.closeCapturer();
    if (AiVoiceInput.engine !== null && AiVoiceInput.sessionId !== '') {
      try { AiVoiceInput.engine.finish(AiVoiceInput.sessionId); } catch (_error) { /* already done */ }
    }
  }

  /** Drop the session without a result. */
  static cancel(): void {
    AiVoiceInput.finishing = true;
    void AiVoiceInput.closeCapturer();
    if (AiVoiceInput.engine !== null && AiVoiceInput.sessionId !== '') {
      try { AiVoiceInput.engine.cancel(AiVoiceInput.sessionId); } catch (_error) { /* already done */ }
    }
  }
}

/**
 * Reading answers aloud with the engine chosen in 设置 › AI 语音: the system voice (offline), or a cloud engine
 * (阿里云百炼, MiniMax, OpenAI 兼容) once AI 语音 is on and it has a key. Markdown never reaches an engine
 * (aiSpeechText). A cloud answer is cut at sentence ends and spoken piece by piece, the next piece fetched while the
 * current one plays; if the cloud fails, the rest is read by the system voice and the reason is returned.
 */
export class AiReadAloud {
  /** The message being read ('' none). */
  static speakingId: string = '';
  private static onChange: (id: string) => void = (_id: string): void => {};
  /** Bumped by every speak and stop: anything still running for an older one gives up. */
  private static generation: number = 0;
  private static engine: textToSpeech.TextToSpeechEngine | null = null;
  private static enginePerson: number = -1;
  private static waiters: Map<string, () => void> = new Map<string, () => void>();
  private static player: media.AVPlayer | null = null;

  static available(): boolean { return canIUse('SystemCapability.AI.TextToSpeech'); }

  /**
   * Read a message aloud; onChange gets its id, then '' when done or stopped. Resolves when reading ends, with ''
   * or a note to show (the cloud voice failed and the system voice took over, the male voice is not downloaded…).
   */
  static async speak(context: common.Context, owner: string, id: string, text: string,
    onChange: (id: string) => void): Promise<string> {
    AiReadAloud.stop();
    const generation: number = ++AiReadAloud.generation;
    AiReadAloud.onChange = onChange;
    AiReadAloud.speakingId = id;
    onChange(id);
    const settings: AiVoiceSettings = new AiVoiceSettings();
    settings.init(context, owner);
    const config: AiVoiceConfig = settings.read();
    const spoken: string = aiSpeechText(text).slice(0, 9000);
    let note: string = '';
    try {
      if (config.enabled && config.provider !== 'system' && config.hasKey) {
        note = await AiReadAloud.speakCloud(context, settings, config, spoken, generation);
      } else {
        note = await AiReadAloud.speakSystem(config.provider === 'system' ? config : new AiVoiceConfig(), spoken, generation);
      }
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'tts failed %{public}s', String((error as BusinessError).code));
      note = '朗读失败，请稍后再试';
    }
    if (generation === AiReadAloud.generation) {
      AiReadAloud.speakingId = '';
      onChange('');
    }
    return note;
  }

  static stop(): void {
    AiReadAloud.generation++;
    if (AiReadAloud.engine !== null) {
      try { AiReadAloud.engine.stop(); } catch (_error) { /* nothing playing */ }
    }
    AiReadAloud.waiters.forEach((resolve: () => void): void => { resolve(); });
    AiReadAloud.waiters.clear();
    if (AiReadAloud.player !== null) {
      try { void AiReadAloud.player.stop(); } catch (_error) { /* not playing */ }
    }
    if (AiReadAloud.speakingId !== '') {
      AiReadAloud.speakingId = '';
      AiReadAloud.onChange('');
    }
  }

  // ------------------------------------------------------------------ system voice

  private static async systemEngine(person: number): Promise<textToSpeech.TextToSpeechEngine> {
    if (AiReadAloud.engine !== null && AiReadAloud.enginePerson === person) { return AiReadAloud.engine; }
    if (AiReadAloud.engine !== null) {
      try { AiReadAloud.engine.shutdown(); } catch (_error) { /* already gone */ }
      AiReadAloud.engine = null;
    }
    const extra: Record<string, Object> = {};
    extra['style'] = 'interaction-broadcast';
    extra['locate'] = 'CN';
    extra['name'] = 'RemoteDeskAiReadAloud';
    const engine: textToSpeech.TextToSpeechEngine =
      await textToSpeech.createEngine({ language: 'zh-CN', person: person, online: 1, extraParams: extra });
    engine.setListener({
      onStart: (_r: string, _response: textToSpeech.StartResponse): void => { /* playing */ },
      // type 0 is synthesis done (long before the voice stops); 1 is playback done.
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        if (response.type === 1) { AiReadAloud.wake(requestId); }
      },
      onStop: (requestId: string, _response: textToSpeech.StopResponse): void => { AiReadAloud.wake(requestId); },
      onError: (requestId: string, code: number, message: string): void => {
        hilog.warn(0x0000, 'AiChat', 'tts error %{public}s %{public}s', code.toString(), message);
        AiReadAloud.wake(requestId);
      }
    });
    AiReadAloud.engine = engine;
    AiReadAloud.enginePerson = person;
    return engine;
  }

  private static wake(requestId: string): void {
    const resolve: (() => void) | undefined = AiReadAloud.waiters.get(requestId);
    if (resolve !== undefined) { AiReadAloud.waiters.delete(requestId); resolve(); }
  }

  private static async speakSystem(config: AiVoiceConfig, spoken: string, generation: number): Promise<string> {
    if (spoken === '' || generation !== AiReadAloud.generation) { return ''; }
    let note: string = '';
    let person: number = parseInt(config.voice, 10) || 13;
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await AiReadAloud.systemEngine(person);
    } catch (error) {
      if (person === 13) { throw error as Error; }
      // The male voice needs a one-time download (设置 › AI 语音); read with the female voice meanwhile.
      person = 13;
      note = '男声还没有下载，先用女声朗读；可以在 设置 › AI 语音 里下载';
      engine = await AiReadAloud.systemEngine(person);
    }
    if (generation !== AiReadAloud.generation) { return note; }
    const requestId: string = 'rd-tts-' + generation.toString() + '-' + Date.now().toString(36);
    const extra: Record<string, Object> = {};
    extra['speed'] = aiVoiceSpeed(config.rate);
    extra['volume'] = 2;
    extra['pitch'] = 1;
    extra['languageContext'] = 'zh-CN';
    extra['audioType'] = 'pcm';
    extra['soundChannel'] = 3;
    extra['playType'] = 1;
    await new Promise<void>((resolve: () => void): void => {
      AiReadAloud.waiters.set(requestId, resolve);
      try {
        engine.speak(spoken, { requestId: requestId, extraParams: extra });
      } catch (error) {
        hilog.warn(0x0000, 'AiChat', 'tts speak failed %{public}s', String((error as BusinessError).code));
        AiReadAloud.wake(requestId);
      }
    });
    return note;
  }

  /** Whether the system voice `person` is on the device (the female voice always is). */
  static async systemVoiceReady(person: number): Promise<boolean> {
    if (person === 13 || person === 0) { return true; }
    try {
      const voices: textToSpeech.VoiceInfo[] =
        await textToSpeech.listVoices({ requestId: 'rd-voices-' + Date.now().toString(), online: 1 });
      return voices.some((voice: textToSpeech.VoiceInfo): boolean => voice.person === person && voice.status === 'INSTALLED');
    } catch (_error) { return false; }
  }

  /** Downloads a system voice (the male voice), when the user asks for it in AI 语音. Resolves with '' or the reason. */
  static downloadSystemVoice(person: number): Promise<string> {
    return new Promise<string>((resolve: (problem: string) => void): void => {
      try {
        textToSpeech.downloadVoice({ requestId: 'rd-voice-' + Date.now().toString(), language: 'zh-CN', person: person,
          style: 'interaction-broadcast' },
          (error: BusinessError, _response: textToSpeech.DownloadResponse): void => {
            if (error && error.code !== 1002300010) {
              hilog.warn(0x0000, 'AiChat', 'voice download failed %{public}s', String(error.code));
              resolve('下载失败（' + String(error.code) + '），请检查网络后重试');
            } else {
              if (AiReadAloud.enginePerson === person) { AiReadAloud.enginePerson = -1; }
              resolve('');
            }
          });
      } catch (error) {
        resolve('下载失败（' + String((error as BusinessError).code) + '）');
      }
    });
  }

  // ------------------------------------------------------------------ cloud voices

  private static async speakCloud(context: common.Context, settings: AiVoiceSettings, config: AiVoiceConfig,
    spoken: string, generation: number): Promise<string> {
    const key: string = settings.key(config.provider);
    const pieces: string[] = aiSpeechPieces(spoken, TTS_PIECE_CHARS);
    if (pieces.length === 0) { return ''; }
    let next: Promise<string> = AiReadAloud.synthesize(context, config, key, pieces[0], generation, 0);
    for (let i = 0; i < pieces.length; i++) {
      let source: string = '';
      try {
        source = await next;
      } catch (error) {
        const why: string = error instanceof Error ? error.message : '网络不可用';
        hilog.warn(0x0000, 'AiChat', 'cloud tts failed %{public}s', why);
        if (generation !== AiReadAloud.generation) { return ''; }
        // The cloud voice failed: the system voice reads the rest, and the user learns why.
        await AiReadAloud.speakSystem(new AiVoiceConfig(), pieces.slice(i).join(''), generation);
        return '云端语音不可用（' + why + '），已改用系统语音';
      }
      if (generation !== AiReadAloud.generation) { return ''; }
      if (i + 1 < pieces.length) {
        next = AiReadAloud.synthesize(context, config, key, pieces[i + 1], generation, i + 1);
        next.catch((_error: Error): string => '');
      }
      try {
        await AiReadAloud.play(source, config.provider === 'dashscope' ? aiVoiceSpeed(config.rate) : 1, generation);
      } finally {
        if (source.startsWith('/')) {
          try { fileIo.unlinkSync(source); } catch (_error) { /* already gone */ }
        }
      }
      if (generation !== AiReadAloud.generation) { return ''; }
    }
    return '';
  }

  /** One piece synthesized: a URL to stream (阿里云百炼) or a cached audio file path. */
  private static async synthesize(context: common.Context, config: AiVoiceConfig, key: string, text: string,
    generation: number, index: number): Promise<string> {
    if (config.provider === 'dashscope') {
      const input: Record<string, Object> = {};
      input['text'] = text;
      input['voice'] = config.voice;
      if (config.model.startsWith('qwen3')) { input['language_type'] = 'Chinese'; }
      const body: Record<string, Object> = {};
      body['model'] = config.model;
      body['input'] = input;
      const reply: Record<string, Object> = await AiReadAloud.postJson(
        'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation', key, body);
      const output: Record<string, Object> | undefined = reply['output'] as Record<string, Object> | undefined;
      const audioInfo: Record<string, Object> | undefined = output !== undefined ?
        output['audio'] as Record<string, Object> | undefined : undefined;
      const url: string = audioInfo !== undefined && typeof audioInfo['url'] === 'string' ? audioInfo['url'] as string : '';
      if (!url.startsWith('http')) {
        throw new Error(typeof reply['message'] === 'string' ? (reply['message'] as string).slice(0, 60) : '没有返回音频');
      }
      return url;
    }
    if (config.provider === 'minimax') {
      const voice: Record<string, Object> = {};
      voice['voice_id'] = config.voice;
      voice['speed'] = aiVoiceSpeed(config.rate);
      voice['vol'] = 1;
      voice['pitch'] = 0;
      const audioSetting: Record<string, Object> = {};
      audioSetting['sample_rate'] = 32000;
      audioSetting['bitrate'] = 128000;
      audioSetting['format'] = 'mp3';
      audioSetting['channel'] = 1;
      const body: Record<string, Object> = {};
      body['model'] = config.model;
      body['text'] = text;
      body['stream'] = false;
      body['voice_setting'] = voice;
      body['audio_setting'] = audioSetting;
      body['output_format'] = 'hex';
      const url: string = 'https://api.minimaxi.com/v1/t2a_v2' +
        (config.groupId !== '' ? '?GroupId=' + encodeURIComponent(config.groupId) : '');
      const reply: Record<string, Object> = await AiReadAloud.postJson(url, key, body);
      const base: Record<string, Object> | undefined = reply['base_resp'] as Record<string, Object> | undefined;
      if (base !== undefined && typeof base['status_code'] === 'number' && (base['status_code'] as number) !== 0) {
        throw new Error(typeof base['status_msg'] === 'string' ? (base['status_msg'] as string).slice(0, 60) : '服务返回错误');
      }
      const data: Record<string, Object> | undefined = reply['data'] as Record<string, Object> | undefined;
      const hex: string = data !== undefined && typeof data['audio'] === 'string' ? data['audio'] as string : '';
      if (hex.length < 2) { throw new Error('没有返回音频'); }
      const bytes: Uint8Array = new Uint8Array(Math.floor(hex.length / 2));
      for (let i = 0; i < bytes.length; i++) { bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16); }
      return AiReadAloud.cache(context, bytes.buffer as ArrayBuffer, generation, index, 'mp3');
    }
    // OpenAI 兼容: POST {base}/audio/speech returns the audio itself.
    const body: Record<string, Object> = {};
    body['model'] = config.model;
    body['input'] = text;
    body['voice'] = config.voice;
    body['response_format'] = 'mp3';
    body['speed'] = aiVoiceSpeed(config.rate);
    const base: string = config.baseUrl !== '' ? config.baseUrl : 'https://api.openai.com/v1';
    if (!base.startsWith('https://')) { throw new Error('服务地址需要以 https:// 开头'); }
    const audioBytes: ArrayBuffer = await AiReadAloud.postAudio(base + '/audio/speech', key, body);
    return AiReadAloud.cache(context, audioBytes, generation, index, 'mp3');
  }

  private static headers(key: string): Record<string, string> {
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/json';
    header['Authorization'] = 'Bearer ' + key;
    return header;
  }

  private static httpProblem(code: number): string {
    if (code === 401 || code === 403) { return '密钥无效或没有权限'; }
    if (code === 429) { return '请求太频繁或额度不足'; }
    if (code === 400 || code === 404) { return '模型或音色不可用'; }
    return 'HTTP ' + code.toString();
  }

  private static async postJson(url: string, key: string, body: Record<string, Object>): Promise<Record<string, Object>> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.POST, header: AiReadAloud.headers(key), extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING, usingCache: false, connectTimeout: 10000, readTimeout: TTS_TIMEOUT_MS
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(AiReadAloud.httpProblem(response.responseCode));
      }
      const parsed: Object = JSON.parse(String(response.result)) as Object;
      if (parsed === null || typeof parsed !== 'object') { throw new Error('返回内容无法识别'); }
      return parsed as Record<string, Object>;
    } catch (error) {
      if (error instanceof Error) { throw error; }
      throw new Error('网络不可用');
    } finally { client.destroy(); }
  }

  private static async postAudio(url: string, key: string, body: Record<string, Object>): Promise<ArrayBuffer> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.POST, header: AiReadAloud.headers(key), extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false, connectTimeout: 10000, readTimeout: TTS_TIMEOUT_MS
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(AiReadAloud.httpProblem(response.responseCode));
      }
      const data: ArrayBuffer = response.result as ArrayBuffer;
      if (data.byteLength < 64) { throw new Error('没有返回音频'); }
      return data;
    } catch (error) {
      if (error instanceof Error) { throw error; }
      throw new Error('网络不可用');
    } finally { client.destroy(); }
  }

  private static cache(context: common.Context, data: ArrayBuffer, generation: number, index: number, ext: string): string {
    const path: string = context.cacheDir + '/ai-tts-' + generation.toString() + '-' + index.toString() + '.' + ext;
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    try { fileIo.writeSync(file.fd, data); } finally { fileIo.closeSync(file); }
    return path;
  }

  /** Plays a URL or a cached file to the end (or until stop()). */
  private static play(source: string, speed: number, generation: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      media.createAVPlayer().then((player: media.AVPlayer): void => {
        AiReadAloud.player = player;
        let file: fileIo.File | null = null;
        let done: boolean = false;
        const finish = (problem: string): void => {
          if (done) { return; }
          done = true;
          try { player.off('stateChange'); player.off('error'); } catch (_error) { /* not listening */ }
          player.release().catch((_error: Error): void => {});
          if (file !== null) { try { fileIo.closeSync(file); } catch (_error) { /* closed */ } }
          if (AiReadAloud.player === player) { AiReadAloud.player = null; }
          if (problem === '') { resolve(); } else { reject(new Error(problem)); }
        };
        player.on('error', (error: BusinessError): void => {
          hilog.warn(0x0000, 'AiChat', 'player error %{public}s', String(error.code));
          finish('播放失败');
        });
        player.on('stateChange', (state: string): void => {
          if (generation !== AiReadAloud.generation) { finish(''); return; }
          if (state === 'initialized') { player.prepare().catch((_error: Error): void => { finish('播放失败'); }); }
          else if (state === 'prepared') {
            if (speed > 1.1) { player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_25_X); }
            else if (speed < 0.9) { player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_0_75_X); }
            player.play().catch((_error: Error): void => { finish('播放失败'); });
          } else if (state === 'completed' || state === 'stopped' || state === 'idle') { finish(''); }
        });
        if (source.startsWith('/')) {
          file = fileIo.openSync(source, fileIo.OpenMode.READ_ONLY);
          player.fdSrc = { fd: file.fd };
        } else {
          player.url = source;
        }
      }).catch((_error: Error): void => { reject(new Error('播放器不可用')); });
    });
  }
}
