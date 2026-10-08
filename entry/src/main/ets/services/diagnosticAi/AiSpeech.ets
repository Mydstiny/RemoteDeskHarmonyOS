import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http, webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
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
/**
 * The same for the call-mode microphone (talking over an answer): it removes the room's noise (silence reads 0.00) and
 * turns speech down, so much less already counts.
 */
const ASR_SPEECH_LEVEL_CALL: number = 0.1;
/** Words still coming from the recognizer mean the user is still talking, however quiet the microphone reads. */
const ASR_TEXT_QUIET_MS: number = 1100;
/** Talking over an answer: what is kept from before the moment it was detected (1.6 s), the user's first syllables. */
const ASR_LEAD_BYTES: number = 51200;
/** Talking over an answer: the recognition microphone is opened this long after (the answer's player writes silence
 * from the moment it is stopped, so its echo has died away by then). */
const ASR_CLEAN_DELAY_MS: number = 100;
/**
 * The longest anything waits for a microphone or the answer's player to be let go (they are always let go in full,
 * step by step; this only keeps a device that never reports back from holding voice mode up).
 */
const ASR_RELEASE_WAIT_MS: number = 4000;
/** A microphone that delivers nothing for this long has stalled. */
const ASR_STALL_MS: number = 700;
/** After the user finished, the recognizer has this long to give its final result. */
const ASR_FINISH_WAIT_MS: number = 9000;
/** A cloud request is cut into pieces of about this many characters at sentence ends, so speaking starts early. */
const TTS_PIECE_CHARS: number = 220;
const TTS_TIMEOUT_MS: number = 30000;

/** Waits for `work`, but no longer than `ms` (an audio call that never reports back must not hold everything up). */
function aiBounded(work: Promise<void>, ms: number): Promise<void> {
  return Promise.race([
    work.catch((): void => { /* failed: carry on */ }),
    new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); })
  ]);
}

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

/** Where a session's audio goes: the system recognizer on the device, or a cloud one. */
interface AiAsrSink {
  write(chunk: Uint8Array): void;
  /** Everything was written: recognize the rest and end. */
  finish(): void;
  cancel(): void;
}

/** The system recognizer (CoreSpeechKit), fed by the app: offline, on the device. */
class AiSystemAsrSink implements AiAsrSink {
  private readonly engine: speechRecognizer.SpeechRecognitionEngine;
  private readonly sessionId: string;

  constructor(engine: speechRecognizer.SpeechRecognitionEngine, sessionId: string) {
    this.engine = engine;
    this.sessionId = sessionId;
  }

  write(chunk: Uint8Array): void { this.engine.writeAudio(this.sessionId, chunk); }
  finish(): void { try { this.engine.finish(this.sessionId); } catch (_error) { /* already done */ } }
  cancel(): void { try { this.engine.cancel(this.sessionId); } catch (_error) { /* already done */ } }
}

/** What a cloud session needs: the 阿里云百炼 key and the recognition model. */
export class AiCloudAsrConfig {
  key: string = '';
  model: string = '';
}

/** The cloud recognizer chosen in 设置 › AI 语音 for this account, or null (on the device). */
function aiCloudAsrConfig(context: common.Context, owner: string): AiCloudAsrConfig | null {
  if (owner.trim() === '') { return null; }
  try {
    const settings: AiVoiceSettings = new AiVoiceSettings();
    settings.init(context, owner);
    const config: AiVoiceConfig = settings.read();
    if (!config.enabled || config.asr !== 'dashscope' || !config.asrReady) { return null; }
    const key: string = settings.key('dashscope').trim();
    if (key === '') { return null; }
    const cloud: AiCloudAsrConfig = new AiCloudAsrConfig();
    cloud.key = key;
    cloud.model = config.asrModel !== '' ? config.asrModel : 'paraformer-realtime-v2';
    return cloud;
  } catch (_error) { return null; }
}

function aiRecord(value: Object | undefined | null): Record<string, Object> {
  if (value !== undefined && value !== null && typeof value === 'object') { return value as Record<string, Object>; }
  const empty: Record<string, Object> = {};
  return empty;
}

const DASHSCOPE_ASR_URL: string = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference';
/** The cloud must have accepted the task by then, or the device recognizes instead. */
const CLOUD_ASR_CONNECT_MS: number = 3500;

/**
 * 阿里云百炼 real-time recognition (Paraformer / Fun-ASR) over its WebSocket API: 16 kHz PCM in, sentences out as they
 * form. Until the first words come back (or once it failed) everything written is kept, so if the cloud cannot be
 * reached the session carries on with the system recognizer from the very first syllable.
 */
class AiCloudAsr implements AiAsrSink {
  private readonly config: AiCloudAsrConfig;
  private readonly onText: (text: string, final: boolean) => void;
  private readonly onDone: () => void;
  private readonly onFail: (why: string) => void;
  private readonly socket: webSocket.WebSocket = webSocket.createWebSocket();
  private readonly taskId: string = util.generateRandomUUID(false).replace(/-/g, '');
  private started: boolean = false;
  private finishWanted: boolean = false;
  private over: boolean = false;
  private queue: ArrayBuffer[] = [];
  private kept: Uint8Array[] = [];
  private keepAll: boolean = true;
  /** Sentences already final, and the one still forming. */
  private finals: string = '';
  private partial: string = '';
  private timer: number = -1;

  constructor(config: AiCloudAsrConfig, onText: (text: string, final: boolean) => void, onDone: () => void,
    onFail: (why: string) => void) {
    this.config = config;
    this.onText = onText;
    this.onDone = onDone;
    this.onFail = onFail;
  }

  open(): void {
    this.socket.on('open', (_error: BusinessError, _value: Object): void => {
      this.sendJson(this.command('run-task', true));
    });
    this.socket.on('message', (_error: BusinessError, value: string | ArrayBuffer): void => {
      if (typeof value === 'string') { this.onMessage(value); }
    });
    this.socket.on('error', (error: BusinessError): void => { this.fail('网络错误 ' + String(error.code)); });
    this.socket.on('close', (_error: BusinessError, _value: webSocket.CloseResult): void => {
      if (!this.over) { this.fail('连接断开'); }
    });
    this.timer = setTimeout((): void => { if (!this.started) { this.fail('连接超时'); } }, CLOUD_ASR_CONNECT_MS);
    const header: Record<string, string> = {};
    header['Authorization'] = 'bearer ' + this.config.key;
    header['X-DashScope-DataInspection'] = 'enable';
    this.socket.connect(DASHSCOPE_ASR_URL, { header: header }).catch((error: BusinessError): void => {
      this.fail('无法连接 ' + String(error.code));
    });
  }

  private command(action: string, withPayload: boolean): Record<string, Object> {
    const header: Record<string, Object> = {};
    header['action'] = action;
    header['task_id'] = this.taskId;
    header['streaming'] = 'duplex';
    const payload: Record<string, Object> = {};
    if (withPayload) {
      const parameters: Record<string, Object> = {};
      parameters['format'] = 'pcm';
      parameters['sample_rate'] = 16000;
      parameters['language_hints'] = ['zh', 'en'];
      payload['task_group'] = 'audio';
      payload['task'] = 'asr';
      payload['function'] = 'recognition';
      payload['model'] = this.config.model;
      payload['parameters'] = parameters;
    }
    const input: Record<string, Object> = {};
    payload['input'] = input;
    const message: Record<string, Object> = {};
    message['header'] = header;
    message['payload'] = payload;
    return message;
  }

  private sendJson(message: Record<string, Object>): void {
    this.socket.send(JSON.stringify(message)).catch((_error: BusinessError): void => { this.fail('发送失败'); });
  }

  private onMessage(text: string): void {
    let message: Record<string, Object>;
    try { message = JSON.parse(text) as Record<string, Object>; } catch (_error) { return; }
    const header: Record<string, Object> = aiRecord(message['header']);
    const event: string = String(header['event'] ?? '');
    if (event === 'task-started') {
      this.started = true;
      hilog.info(0x0000, 'AiChat', 'asr cloud started');
      this.queue.forEach((chunk: ArrayBuffer): void => { this.sendAudio(chunk); });
      this.queue = [];
      if (this.finishWanted) { this.sendJson(this.command('finish-task', false)); }
    } else if (event === 'result-generated') {
      const output: Record<string, Object> = aiRecord(aiRecord(message['payload'])['output']);
      if (output['sentence'] === undefined) { return; }
      const sentence: Record<string, Object> = aiRecord(output['sentence']);
      if (String(sentence['heartbeat']) === 'true') { return; }
      const words: string = String(sentence['text'] ?? '');
      if (String(sentence['sentence_end']) === 'true') { this.finals += words; this.partial = ''; } else { this.partial = words; }
      if (this.finals + this.partial !== '') {
        // Words came back: the cloud works, nothing more needs keeping for the device.
        this.keepAll = false;
        this.kept = [];
      }
      this.onText(this.finals + this.partial, false);
    } else if (event === 'task-finished') {
      this.close();
      this.onText(this.finals + this.partial, true);
      this.onDone();
    } else if (event === 'task-failed') {
      this.fail(String(header['error_code'] ?? '') + ' ' + String(header['error_message'] ?? '').slice(0, 80));
    }
  }

  private sendAudio(chunk: ArrayBuffer): void {
    this.socket.send(chunk).catch((_error: BusinessError): void => { this.fail('发送失败'); });
  }

  write(chunk: Uint8Array): void {
    if (this.keepAll) { this.kept.push(chunk); }
    if (this.over) { return; }
    const buffer: ArrayBuffer = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength);
    if (this.started) { this.sendAudio(buffer); } else { this.queue.push(buffer); }
  }

  finish(): void {
    if (this.over || this.finishWanted) { return; }
    this.finishWanted = true;
    if (this.started) { this.sendJson(this.command('finish-task', false)); }
  }

  cancel(): void { this.close(); }

  /** What was written so far, for the device to recognize instead (only kept until the first words came back). */
  takeKept(): Uint8Array {
    let size: number = 0;
    this.kept.forEach((chunk: Uint8Array): void => { size += chunk.length; });
    const all: Uint8Array = new Uint8Array(size);
    let offset: number = 0;
    this.kept.forEach((chunk: Uint8Array): void => { all.set(chunk, offset); offset += chunk.length; });
    this.kept = [];
    this.keepAll = false;
    return all;
  }

  /** The cloud gave up: with words already heard the session ends with them, otherwise the device takes over. */
  private fail(why: string): void {
    if (this.over) { return; }
    hilog.warn(0x0000, 'AiChat', 'asr cloud failed %{public}s', why);
    this.close();
    if (this.finals + this.partial !== '') {
      this.onText(this.finals + this.partial, true);
      this.onDone();
    } else {
      this.onFail(why);
    }
  }

  private close(): void {
    if (this.over) { return; }
    this.over = true;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    try {
      this.socket.close().catch((_error: BusinessError): void => { /* already closed */ });
    } catch (_error) { /* already closed */ }
  }
}

/**
 * Dictation for the AI chat and voice mode (Chinese). The app records the microphone itself and feeds the
 * recognizer — the system one on the device, or 阿里云百炼's in the cloud when chosen in 设置 › AI 语音 — so it
 * knows how loud the user is (onLevel drives the voice animation) and when they stopped talking. If the microphone
 * cannot be opened that way, the system recognizer records on its own (no levels).
 */
export class AiVoiceInput {
  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static sessionId: string = '';
  private static capturer: audio.AudioCapturer | null = null;
  private static finishing: boolean = false;
  /** Where the running session's audio goes. */
  private static sink: AiAsrSink | null = null;

  static available(): boolean { return canIUse('SystemCapability.AI.SpeechRecognizer'); }

  /**
   * Listen until the speaker stops (or stop() is called). onText gets the words so far (final once isFinal); onEnd
   * comes once, with '' or what went wrong; onLevel gets the microphone level about every 20 ms (0 at the end).
   * `adoptMonitor`: the user talked over an answer (claimMonitor): the recognizer takes over that microphone, with
   * everything it kept since the user began, so not a word is lost. `owner` picks the account's 语音识别 engine.
   */
  static async start(context: common.UIAbilityContext, onText: (text: string, final: boolean) => void,
    onEnd: (problem: string) => void, onLevel: (level: number) => void = (_level: number): void => {},
    adoptMonitor: boolean = false, owner: string = '', speaking: boolean = true): Promise<void> {
    const calledAt: number = Date.now();
    const cloud: AiCloudAsrConfig | null = aiCloudAsrConfig(context, owner);
    if (cloud === null && !AiVoiceInput.available()) { onEnd('当前设备不支持语音输入'); return; }
    if (!(await aiEnsurePermission(context, 'ohos.permission.MICROPHONE'))) { onEnd('没有麦克风权限'); return; }
    try {
      const previous: AiAsrSink | null = AiVoiceInput.sink;
      AiVoiceInput.sink = null;
      if (previous !== null) { previous.cancel(); }
      let busy: boolean = false;
      if (AiVoiceInput.engine !== null && AiVoiceInput.engine.isBusy()) {
        busy = true;
        try { AiVoiceInput.engine.cancel(AiVoiceInput.sessionId); } catch (_error) { /* already done */ }
        // The cancel finishes in the speech service: a session started at once can end before it hears anything.
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 180); });
      }
      await AiVoiceInput.closeCapturer();
      // Talking over the answer, the echo-cancelled microphone keeps running (and keeping what it hears) until the
      // recognizer takes it over below: not a word is lost in between.
      const adopting: boolean = adoptMonitor && AiVoiceInput.monitorCapturer !== null;
      hilog.info(0x0000, 'AiChat',
        'asr start adopt=%{public}s speaking=%{public}s monitor=%{public}s claimed=%{public}s busy=%{public}s cloud=%{public}s after=%{public}s ms',
        String(adoptMonitor), String(speaking), String(AiVoiceInput.monitorCapturer !== null), String(AiVoiceInput.claimed), String(busy),
        cloud !== null ? cloud.model : '-', (Date.now() - calledAt).toString());
      if (!adopting) { await AiVoiceInput.stopMonitor(); }
      const sessionId: string = 'rd-asr-' + Date.now().toString();
      AiVoiceInput.sessionId = sessionId;
      AiVoiceInput.finishing = false;
      let ended: boolean = false;
      let partials: number = 0;
      let lastText: string = '';
      let lastTextAt: number = 0;
      const end = (problem: string): void => {
        if (ended) { return; }
        ended = true;
        hilog.info(0x0000, 'AiChat', 'asr end problem=%{public}s results=%{public}s', problem === '' ? '-' : problem,
          partials.toString());
        AiVoiceInput.clearPump();
        AiVoiceInput.sink = null;
        void AiVoiceInput.closeCapturer();
        onLevel(0);
        onEnd(problem);
      };
      const result = (text: string, final: boolean): void => {
        if (ended || sessionId !== AiVoiceInput.sessionId) { return; }
        if (partials === 0) {
          hilog.info(0x0000, 'AiChat', 'asr first result after %{public}s ms', (Date.now() - calledAt).toString());
        }
        partials++;
        // Punctuation alone (a lone full stop for noise) is not a word.
        const words: string = text.replace(/[\s。，、！？!?,.…~～]/g, '');
        if (words !== '' && words !== lastText) { lastText = words; lastTextAt = Date.now(); }
        onText(text, final);
      };
      // The system recognizer for this session: fed by the app (mode 1), or recording by itself (mode 0).
      const listenOnDevice = async (mode: number): Promise<AiAsrSink> => {
        if (AiVoiceInput.engine === null) {
          AiVoiceInput.engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
        }
        const engine: speechRecognizer.SpeechRecognitionEngine = AiVoiceInput.engine;
        engine.setListener({
          onStart: (_id: string, _message: string): void => { /* listening */ },
          onEvent: (_id: string, _code: number, _message: string): void => { /* speech began / ended */ },
          onResult: (id: string, recognized: speechRecognizer.SpeechRecognitionResult): void => {
            if (id === sessionId) { result(recognized.result, recognized.isFinal); }
          },
          onComplete: (id: string, _message: string): void => { if (id === sessionId) { end(''); } },
          onError: (id: string, code: number, message: string): void => {
            hilog.warn(0x0000, 'AiChat', 'asr error %{public}s %{public}s', code.toString(), message);
            if (id === sessionId) { end('没有听清，请再说一次'); }
          }
        });
        const extra: Record<string, Object> = {};
        extra['maxAudioDuration'] = 60000;
        // 0: a pause of 2 s ends the sentence; 1: the app decides when the user has finished.
        extra['recognitionMode'] = mode;
        extra['vadBegin'] = mode === 0 ? 2500 : 10000;
        extra['vadEnd'] = mode === 0 ? 2000 : 3000;
        engine.startListening({ sessionId: sessionId,
          audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }, extraParams: extra });
        return new AiSystemAsrSink(engine, sessionId);
      };
      let capturer: audio.AudioCapturer | null = null;
      let backlog: Uint8Array = new Uint8Array(0);
      if (adopting && AiVoiceInput.monitorCapturer !== null) {
        // The monitor keeps on keeping (still claimed) until its buffers are routed to this session below, where what
        // it kept is taken in the same step: nothing falls between the two.
        capturer = AiVoiceInput.monitorCapturer;
        AiVoiceInput.monitorCapturer = null;
        AiVoiceInput.capturer = capturer;
      } else {
        capturer = await AiVoiceInput.openCapturer();
      }
      if (capturer === null) {
        hilog.warn(0x0000, 'AiChat', 'asr records by itself (no microphone of ours)');
        AiVoiceInput.sink = await listenOnDevice(0);
        return;
      }
      let finishedSink: AiAsrSink | null = null;
      let finishAt: number = 0;
      let sink: AiAsrSink;
      if (cloud !== null) {
        const asr: AiCloudAsr = new AiCloudAsr(cloud, result, (): void => { end(''); }, (_why: string): void => {
          if (ended || sessionId !== AiVoiceInput.sessionId) { return; }
          // No network, a refused key…: the device recognizes it all, from what the cloud was sent.
          void listenOnDevice(1).then((local: AiAsrSink): void => {
            if (ended || sessionId !== AiVoiceInput.sessionId) { local.cancel(); return; }
            const kept: Uint8Array = asr.takeKept();
            const joined: Uint8Array = new Uint8Array(kept.length + backlog.length);
            joined.set(kept, 0);
            joined.set(backlog, kept.length);
            backlog = joined;
            sink = local;
            AiVoiceInput.sink = local;
            finishedSink = null;
            finishAt = 0;
            hilog.info(0x0000, 'AiChat', 'asr on the device instead, replaying %{public}s ms',
              Math.round(kept.length / 32).toString());
          }).catch((_error: Error): void => { end('语音识别不可用'); });
        });
        asr.open();
        sink = asr;
      } else {
        sink = await listenOnDevice(1);
      }
      AiVoiceInput.sink = sink;
      const startedAt: number = Date.now();
      // Talking over the answer, the user is already speaking: the quiet that ends the sentence counts from now.
      // `speaking`: the user is already talking (over the answer); otherwise (the answer just ended) they may begin.
      let heardAt: number = adopting && speaking ? startedAt : 0;
      let lastVoiceAt: number = adopting && speaking ? startedAt : 0;
      let lastAudioAt: number = startedAt;
      let buffers: number = 0;
      let peak: number = 0;
      let loggedAt: number = startedAt;
      // The call-mode microphone removes the room's noise (it sits near 0): quieter speech already counts there.
      let speechLevel: number = adopting ? ASR_SPEECH_LEVEL_CALL : ASR_SPEECH_LEVEL;
      let switching: boolean = false;
      // Talking over the answer: the move to a recognition microphone is under way (no stall switch meanwhile).
      let cleanTrying: boolean = adopting;
      // Our own microphone opened again after it came up dead (at most twice), and when.
      let reopens: number = 0;
      let reopenedAt: number = 0;
      // Everything for the recognizer goes through one queue, written at a steady pace (the system recognizer takes
      // 40 ms pieces and drops a burst): what the microphone kept while the user talked over the answer first, then
      // the live audio.
      const take = (buffer: ArrayBuffer): void => {
        if (ended || AiVoiceInput.finishing || sessionId !== AiVoiceInput.sessionId) { return; }
        const now: number = Date.now();
        if (buffers === 0) {
          hilog.info(0x0000, 'AiChat', 'asr audio after %{public}s ms', (now - startedAt).toString());
        }
        buffers++;
        lastAudioAt = now;
        const level: number = aiPcmLevel(buffer);
        onLevel(level);
        peak = Math.max(peak, level);
        if (now - loggedAt >= 1000) {
          hilog.info(0x0000, 'AiChat', 'asr mic=%{public}s queued=%{public}s ms', peak.toFixed(2),
            Math.round(backlog.length / 32).toString());
          loggedAt = now;
          peak = 0;
        }
        if (level >= speechLevel) {
          if (heardAt === 0) { heardAt = now; }
          lastVoiceAt = now;
        }
        const joined: Uint8Array = new Uint8Array(backlog.length + buffer.byteLength);
        joined.set(backlog, 0);
        joined.set(new Uint8Array(buffer), backlog.length);
        backlog = joined;
      };
      // The call-mode microphone stopped delivering (the answer's player went away under it): carry on, in the same
      // session, with a microphone of our own.
      const switchMicrophone = async (): Promise<void> => {
        switching = true;
        hilog.warn(0x0000, 'AiChat', 'asr microphone stalled after %{public}s buffers, opening our own', buffers.toString());
        await AiVoiceInput.closeCapturer();
        const own: audio.AudioCapturer | null = await AiVoiceInput.openCapturer();
        if (own === null) { end('语音输入中断了'); return; }
        if (ended || sessionId !== AiVoiceInput.sessionId) { await AiVoiceInput.closeCapturer(); return; }
        speechLevel = ASR_SPEECH_LEVEL;
        lastAudioAt = Date.now();
        own.on('readData', take);
        try { await own.start(); } catch (_error) { end('语音输入中断了'); return; }
        switching = false;
      };
      // Talking over the answer, the call-mode microphone processes the voice for a call (turned down, noise and echo
      // removed — the recognizer hears it much worse) and can go quiet once the answer's player is gone. So once the
      // answer has stopped, a recognition microphone of our own takes over — opened while the call one still runs, and
      // switched to the moment it has started (each stretch of speech is heard once). Should the system refuse a
      // second microphone, or the new one stay silent, the call one simply stays.
      const cleanSwitch = async (): Promise<void> => {
        const monitor: audio.AudioCapturer | null = capturer;
        for (let attempt = 0; attempt < 6; attempt++) {
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, attempt === 0 ? ASR_CLEAN_DELAY_MS : 150); });
          if (ended || AiVoiceInput.finishing || sessionId !== AiVoiceInput.sessionId || AiVoiceInput.capturer !== monitor) {
            cleanTrying = false;
            return;
          }
          const own: audio.AudioCapturer | null = await AiVoiceInput.createRecognitionCapturer();
          if (own === null) { continue; }
          if (ended || AiVoiceInput.finishing || sessionId !== AiVoiceInput.sessionId || AiVoiceInput.capturer !== monitor) {
            await AiVoiceInput.releaseCapturer(own);
            cleanTrying = false;
            return;
          }
          // While it comes up, the call microphone's buffers are held back: the moment this one delivers, they are
          // sent up to then (all but the last two, about what this one has just recorded too) and this one carries
          // on — nothing heard twice, nothing lost while it was starting. Should it stay silent, they are sent after
          // all and the call microphone carries on.
          let delivered: boolean = false;
          let held: ArrayBuffer[] = [];
          own.on('readData', (buffer: ArrayBuffer): void => {
            if (AiVoiceInput.capturer !== own) { return; }
            if (!delivered) {
              delivered = true;
              if (monitor !== null && AiVoiceInput.sinkOwner === monitor) {
                AiVoiceInput.sinkOwner = null;
                AiVoiceInput.monitorSink = null;
              }
              const sent: number = Math.max(0, held.length - 2);
              for (let i = 0; i < sent; i++) { take(held[i]); }
              held = [];
              speechLevel = ASR_SPEECH_LEVEL;
              hilog.info(0x0000, 'AiChat', 'asr recognition microphone after %{public}s ms (try %{public}s, held %{public}s)',
                (Date.now() - startedAt).toString(), (attempt + 1).toString(), sent.toString());
            }
            take(buffer);
          });
          try {
            await own.start();
          } catch (error) {
            hilog.warn(0x0000, 'AiChat', 'asr recognition microphone refused %{public}s', String((error as BusinessError).code));
            await AiVoiceInput.releaseCapturer(own);
            continue;
          }
          if (ended || AiVoiceInput.finishing || sessionId !== AiVoiceInput.sessionId || AiVoiceInput.capturer !== monitor) {
            await AiVoiceInput.releaseCapturer(own);
            cleanTrying = false;
            return;
          }
          // Started: the session belongs to this microphone now; the call one's buffers wait until it delivers (they
          // still count as the user's voice meanwhile, so a pause is not misread).
          AiVoiceInput.capturer = own;
          if (monitor !== null && AiVoiceInput.sinkOwner === monitor) {
            AiVoiceInput.monitorSink = (buffer: ArrayBuffer): void => {
              if (delivered) { return; }
              held.push(buffer.slice(0));
              const now: number = Date.now();
              const level: number = aiPcmLevel(buffer);
              onLevel(level);
              lastAudioAt = now;
              if (level >= speechLevel) {
                if (heardAt === 0) { heardAt = now; }
                lastVoiceAt = now;
              }
            };
          }
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 1200); });
          if (delivered || AiVoiceInput.capturer !== own) {
            if (monitor !== null) { await AiVoiceInput.releaseCapturer(monitor); }
          } else {
            // Silent: back to the call microphone (still open) with all it heard meanwhile; this one goes.
            hilog.warn(0x0000, 'AiChat', 'asr recognition microphone silent, back to the call one (held %{public}s)',
              held.length.toString());
            AiVoiceInput.capturer = monitor;
            if (monitor !== null) {
              AiVoiceInput.sinkOwner = monitor;
              AiVoiceInput.monitorSink = take;
            }
            held.forEach((buffer: ArrayBuffer): void => { take(buffer); });
            held = [];
            speechLevel = ASR_SPEECH_LEVEL_CALL;
            await AiVoiceInput.releaseCapturer(own);
          }
          cleanTrying = false;
          return;
        }
        cleanTrying = false;
        hilog.info(0x0000, 'AiChat', 'asr keeps the call microphone');
      };
      AiVoiceInput.clearPump();
      AiVoiceInput.pumpTimer = setInterval((): void => {
        if (ended || sessionId !== AiVoiceInput.sessionId) { AiVoiceInput.clearPump(); return; }
        let written: number = 0;
        try {
          // Up to three pieces a tick: the kept audio catches up at three times real time.
          while (backlog.length >= ASR_CHUNK_BYTES && written < 3) {
            sink.write(backlog.slice(0, ASR_CHUNK_BYTES));
            backlog = backlog.slice(ASR_CHUNK_BYTES);
            written++;
          }
        } catch (error) {
          hilog.warn(0x0000, 'AiChat', 'asr write failed %{public}s', String((error as BusinessError).code));
          end('语音输入中断了');
          return;
        }
        const now: number = Date.now();
        // Done listening: the recognizer is told so only once it has everything that was said (and again, if the
        // device took over from the cloud meanwhile). It then ends the session; if it never does, give up.
        if (AiVoiceInput.finishing) {
          if (finishAt === 0) { finishAt = now; }
          if (backlog.length < ASR_CHUNK_BYTES && finishedSink !== sink) {
            finishedSink = sink;
            sink.finish();
          }
          if (now - finishAt > ASR_FINISH_WAIT_MS) {
            hilog.warn(0x0000, 'AiChat', 'asr gave no final result');
            end('');
          }
          return;
        }
        // The ends are judged here, on the clock, so a microphone that goes silent cannot leave the session hanging.
        // The user has finished once the microphone is quiet and the recognizer has stopped adding words.
        const spoke: boolean = heardAt > 0 || lastTextAt > 0;
        const quietAfterSpeech: boolean = spoke && now - lastVoiceAt > ASR_TRAILING_QUIET_MS &&
          now - lastTextAt > ASR_TEXT_QUIET_MS;
        const nothingSaid: boolean = !spoke && now - Math.max(startedAt, reopenedAt) > ASR_NO_SPEECH_MS;
        if (quietAfterSpeech || nothingSaid || now - startedAt > ASR_MAX_MS) {
          hilog.info(0x0000, 'AiChat', 'asr done (%{public}s) after %{public}s ms, sound %{public}s ms ago, words %{public}s ms ago',
            quietAfterSpeech ? 'quiet' : nothingSaid ? 'nothing said' : 'too long', (now - startedAt).toString(),
            lastVoiceAt > 0 ? (now - lastVoiceAt).toString() : '-', lastTextAt > 0 ? (now - lastTextAt).toString() : '-');
          AiVoiceInput.stop();
          return;
        }
        if (!switching && !cleanTrying && now - lastAudioAt > ASR_STALL_MS) {
          if (adopting) {
            // While we switch, the gap must not count as the user's pause.
            lastVoiceAt = now;
            void switchMicrophone();
          } else if (reopens < 2 && !spoke) {
            // A microphone opened just as the system left call mode can come up nearly dead (a buffer a second):
            // open it again rather than wait out the user's whole turn.
            reopens++;
            reopenedAt = now;
            void switchMicrophone();
          } else {
            hilog.warn(0x0000, 'AiChat', 'asr microphone silent for %{public}s ms', (now - lastAudioAt).toString());
            lastAudioAt = now;
          }
        }
      }, 40);
      if (adopting) {
        // What the monitor kept, then every buffer it hears from here on (its own handler stays subscribed and now
        // hands each buffer to this session: re-subscribing a running capturer can leave it silent).
        const kept: Uint8Array = AiVoiceInput.takeRing();
        AiVoiceInput.claimed = false;
        const joined: Uint8Array = new Uint8Array(kept.length + backlog.length);
        joined.set(kept, 0);
        joined.set(backlog, kept.length);
        backlog = joined;
        AiVoiceInput.monitorSink = take;
        hilog.info(0x0000, 'AiChat', 'asr takes over the mic, kept %{public}s ms', Math.round(kept.length / 32).toString());
        void cleanSwitch();
      } else {
        capturer.on('readData', take);
        await capturer.start();
      }
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'asr start failed %{public}s', String((error as BusinessError).code));
      await AiVoiceInput.closeCapturer();
      onLevel(0);
      onEnd('语音输入启动失败');
    }
  }

  private static async openCapturer(): Promise<audio.AudioCapturer | null> {
    await AiVoiceInput.releasing;
    for (let attempt = 0; attempt < 3; attempt++) {
      const capturer: audio.AudioCapturer | null = await AiVoiceInput.tryOpenCapturer();
      if (capturer !== null) { return capturer; }
      // Just after a call-mode microphone was released, the system may still refuse (6800301) for a moment.
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 250); });
    }
    return null;
  }

  private static async tryOpenCapturer(): Promise<audio.AudioCapturer | null> {
    const capturer: audio.AudioCapturer | null = await AiVoiceInput.createRecognitionCapturer();
    if (capturer !== null) { AiVoiceInput.capturer = capturer; }
    return capturer;
  }

  /** A recognition microphone (16 kHz mono), not yet the session's. */
  private static async createRecognitionCapturer(): Promise<audio.AudioCapturer | null> {
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 }
      };
      return await audio.createAudioCapturer(options);
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'capturer unavailable %{public}s', String((error as BusinessError).code));
      return null;
    }
  }

  /** Let one microphone go (a microphone opened next waits for it). */
  private static async releaseCapturer(capturer: audio.AudioCapturer): Promise<void> {
    const release = async (): Promise<void> => {
      try { capturer.off('readData'); } catch (_error) { /* not listening */ }
      // Strictly one after the other (a release while it is still stopping left the audio system half-switched, and
      // the next microphone delivered next to nothing). Only the waiting is bounded, below.
      try { await capturer.stop(); } catch (_error) { /* not started */ }
      try { await capturer.release(); } catch (_error) { /* already released */ }
    };
    const done: Promise<void> = aiBounded(release(), ASR_RELEASE_WAIT_MS);
    AiVoiceInput.releasing = done;
    await done;
  }

  private static async closeCapturer(): Promise<void> {
    const capturer: audio.AudioCapturer | null = AiVoiceInput.capturer;
    AiVoiceInput.capturer = null;
    if (capturer === null) { return; }
    // An adopted monitor: its handler goes quiet with it.
    if (capturer === AiVoiceInput.sinkOwner) { AiVoiceInput.monitorSink = null; AiVoiceInput.sinkOwner = null; }
    const release = async (): Promise<void> => {
      try { capturer.off('readData'); } catch (_error) { /* not listening */ }
      // Strictly one after the other (a release while it is still stopping left the audio system half-switched, and
      // the next microphone delivered next to nothing). Only the waiting is bounded, below.
      try { await capturer.stop(); } catch (_error) { /* not started */ }
      try { await capturer.release(); } catch (_error) { /* already released */ }
    };
    // A microphone opened next waits for this one to be let go (openCapturer awaits `releasing`).
    const done: Promise<void> = aiBounded(release(), ASR_RELEASE_WAIT_MS);
    AiVoiceInput.releasing = done;
    await done;
  }

  private static monitorCapturer: audio.AudioCapturer | null = null;
  /** The monitor whose buffers go to `monitorSink` once a session adopted it. */
  private static sinkOwner: audio.AudioCapturer | null = null;
  private static monitorSink: ((buffer: ArrayBuffer) => void) | null = null;
  private static monitorLevel: ((level: number) => void) | null = null;
  private static ring: Uint8Array[] = [];
  private static ringBytes: number = 0;
  /** The user began talking over the answer: the kept audio is theirs now, none of it may be dropped. */
  private static claimed: boolean = false;

  /**
   * While voice mode reads an answer: the microphone as a call hears it (SOURCE_TYPE_VOICE_COMMUNICATION — with the
   * answer playing through a voice-communication renderer, the system cancels its echo), its level for each buffer,
   * and the last seconds of it kept, so the start of what the user says over the answer is not lost.
   */
  static async startMonitor(context: common.UIAbilityContext, onLevel: (level: number) => void): Promise<boolean> {
    await AiVoiceInput.stopMonitor();
    if (!(await aiEnsurePermission(context, 'ohos.permission.MICROPHONE'))) { return false; }
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
      };
      const capturer: audio.AudioCapturer = await audio.createAudioCapturer(options);
      AiVoiceInput.monitorCapturer = capturer;
      AiVoiceInput.sinkOwner = capturer;
      AiVoiceInput.monitorSink = null;
      AiVoiceInput.monitorLevel = onLevel;
      AiVoiceInput.claimed = false;
      AiVoiceInput.ring = [];
      AiVoiceInput.ringBytes = 0;
      // One handler for the capturer's whole life: it keeps the audio (and reports levels) while the answer is read,
      // and once a session adopts the capturer it hands every buffer to that session instead.
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        if (AiVoiceInput.sinkOwner !== capturer) { return; }
        const sink: ((buffer: ArrayBuffer) => void) | null = AiVoiceInput.monitorSink;
        if (sink !== null) { sink(buffer); return; }
        const chunk: Uint8Array = new Uint8Array(buffer.slice(0));
        AiVoiceInput.ring.push(chunk);
        AiVoiceInput.ringBytes += chunk.length;
        // About 3 s while it only waits; once the user is talking over the answer, up to 20 s until a session takes it.
        const limit: number = AiVoiceInput.claimed ? 640000 : 96000;
        while (AiVoiceInput.ringBytes > limit && AiVoiceInput.ring.length > 1) {
          const dropped: Uint8Array | undefined = AiVoiceInput.ring.shift();
          AiVoiceInput.ringBytes -= dropped !== undefined ? dropped.length : 0;
        }
        const level: ((level: number) => void) | null = AiVoiceInput.monitorLevel;
        if (level !== null) { level(aiPcmLevel(buffer)); }
      });
      await capturer.start();
      hilog.info(0x0000, 'AiChat', 'monitor listening');
      return true;
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'monitor unavailable %{public}s', String((error as BusinessError).code));
      await AiVoiceInput.stopMonitor();
      return false;
    }
  }

  /**
   * The user is talking over the answer (called the moment it is detected, before anything is stopped): the
   * monitor stops reporting levels and keeps everything from just before they began, for the recognizer.
   */
  static claimMonitor(leadMs: number = ASR_LEAD_BYTES / 32): boolean {
    if (AiVoiceInput.monitorCapturer === null) {
      hilog.warn(0x0000, 'AiChat', 'asr claim: no monitor');
      return false;
    }
    AiVoiceInput.claimed = true;
    AiVoiceInput.monitorLevel = null;
    // Keep only from just before the user began (their first syllables), not seconds of the answer's echo, which the
    // recognizer would try to make words of.
    const keep: number = Math.max(9600, Math.min(ASR_LEAD_BYTES, Math.round(leadMs * 32)));
    while (AiVoiceInput.ringBytes > keep && AiVoiceInput.ring.length > 1) {
      const dropped: Uint8Array | undefined = AiVoiceInput.ring.shift();
      AiVoiceInput.ringBytes -= dropped !== undefined ? dropped.length : 0;
    }
    hilog.info(0x0000, 'AiChat', 'asr claim: kept %{public}s ms', Math.round(AiVoiceInput.ringBytes / 32).toString());
    return true;
  }

  /** The kept audio (oldest first), for the recognizer. */
  static takeRing(): Uint8Array {
    const all: Uint8Array = new Uint8Array(AiVoiceInput.ringBytes);
    let offset: number = 0;
    AiVoiceInput.ring.forEach((chunk: Uint8Array): void => {
      if (offset + chunk.length <= all.length) { all.set(chunk, offset); offset += chunk.length; }
    });
    AiVoiceInput.ring = [];
    AiVoiceInput.ringBytes = 0;
    return offset === all.length ? all : all.slice(0, offset);
  }

  /** The microphone that was let go is released only when this settles; a new one waits for it. */
  private static releasing: Promise<void> = Promise.resolve();

  static async stopMonitor(): Promise<void> {
    const capturer: audio.AudioCapturer | null = AiVoiceInput.monitorCapturer;
    AiVoiceInput.monitorCapturer = null;
    AiVoiceInput.claimed = false;
    AiVoiceInput.monitorLevel = null;
    if (capturer === null) { await AiVoiceInput.releasing; return; }
    if (AiVoiceInput.sinkOwner === capturer) { AiVoiceInput.sinkOwner = null; AiVoiceInput.monitorSink = null; }
    hilog.info(0x0000, 'AiChat', 'monitor stopped');
    const release = async (): Promise<void> => {
      try { capturer.off('readData'); } catch (_error) { /* not listening */ }
      // Strictly one after the other (a release while it is still stopping left the audio system half-switched, and
      // the next microphone delivered next to nothing). Only the waiting is bounded, below.
      try { await capturer.stop(); } catch (_error) { /* not started */ }
      try { await capturer.release(); } catch (_error) { /* already released */ }
    };
    AiVoiceInput.releasing = aiBounded(release(), ASR_RELEASE_WAIT_MS);
    await AiVoiceInput.releasing;
  }

  private static pumpTimer: number = -1;

  static clearPump(): void {
    if (AiVoiceInput.pumpTimer !== -1) { clearInterval(AiVoiceInput.pumpTimer); AiVoiceInput.pumpTimer = -1; }
  }

  /** The user is done: recognize what was said so far (the queue is written out first; the pump then finishes). */
  static stop(): void {
    if (AiVoiceInput.finishing) { return; }
    AiVoiceInput.finishing = true;
    void AiVoiceInput.closeCapturer();
    // With the app's own microphone the pump tells the recognizer, once it has written everything.
    if (AiVoiceInput.pumpTimer !== -1) { return; }
    if (AiVoiceInput.sink !== null) { AiVoiceInput.sink.finish(); }
  }

  /** Drop the session without a result. */
  static cancel(): void {
    AiVoiceInput.finishing = true;
    AiVoiceInput.clearPump();
    void AiVoiceInput.closeCapturer();
    const sink: AiAsrSink | null = AiVoiceInput.sink;
    AiVoiceInput.sink = null;
    if (sink !== null) { sink.cancel(); }
  }

  /** The user is talking over the answer and the monitor keeps it for the recognizer: it must not be let go. */
  static monitorClaimed(): boolean { return AiVoiceInput.claimed && AiVoiceInput.monitorCapturer !== null; }

  /** The echo-cancelled microphone of the answer just read is still open (and nobody's yet). */
  static monitorLive(): boolean { return AiVoiceInput.monitorCapturer !== null && !AiVoiceInput.claimed; }
}

function samplingRate(rate: number): audio.AudioSamplingRate {
  if (rate === 24000) { return audio.AudioSamplingRate.SAMPLE_RATE_24000; }
  if (rate === 22050) { return audio.AudioSamplingRate.SAMPLE_RATE_22050; }
  if (rate === 32000) { return audio.AudioSamplingRate.SAMPLE_RATE_32000; }
  if (rate === 44100) { return audio.AudioSamplingRate.SAMPLE_RATE_44100; }
  if (rate === 48000) { return audio.AudioSamplingRate.SAMPLE_RATE_48000; }
  return audio.AudioSamplingRate.SAMPLE_RATE_16000;
}

/**
 * Plays PCM (mono, 16-bit) as a voice call does — STREAM_USAGE_VOICE_COMMUNICATION on the loudspeaker — so a
 * voice-communication capture running at the same time gets the system's echo cancellation and can hear the user
 * over it. Reports the level of what it plays (the speaking light follows the real voice).
 */
class AiPcmPlayer {
  private renderer: audio.AudioRenderer | null = null;
  private queue: Uint8Array[] = [];
  private head: number = 0;
  private ended: boolean = false;
  private stopped: boolean = false;
  private rate: number = 16000;
  /**
   * Push mode (the usual): the app writes the voice into the renderer piece by piece — no data callback, so stopping
   * never has to take one away (taking it away while the audio thread waited on it held the app up for a second,
   * just as the user talked over the answer). Callback mode only if this device refuses written audio.
   */
  private callbackMode: boolean = false;
  private wrote: boolean = false;
  private wake: (() => void) | null = null;
  private pumped: Promise<void> = Promise.resolve();
  // Callback mode only.
  private idleCalls: number = 0;
  private drained: (() => void) | null = null;
  private afterWrite: (() => void) | null = null;
  private readonly onLevel: (level: number) => void;

  constructor(onLevel: (level: number) => void) { this.onLevel = onLevel; }

  private async create(rate: number): Promise<audio.AudioRenderer> {
    const options: audio.AudioRendererOptions = {
      streamInfo: { samplingRate: samplingRate(rate), channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 }
    };
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
    try { await renderer.setDefaultOutputDevice(audio.DeviceType.SPEAKER); } catch (_error) { /* headset or default */ }
    return renderer;
  }

  async start(rate: number): Promise<void> {
    this.rate = rate;
    const renderer: audio.AudioRenderer = await this.create(rate);
    this.renderer = renderer;
    await renderer.start();
    this.pumped = this.pump(renderer);
  }

  push(chunk: Uint8Array): void {
    if (this.stopped || chunk.length === 0) { return; }
    this.queue.push(chunk);
    const wake: (() => void) | null = this.wake;
    if (wake !== null) { this.wake = null; wake(); }
  }

  /** Up to `size` bytes from the queue (whole samples), as a buffer of its own; null when nothing is waiting. */
  private nextPiece(size: number): ArrayBuffer | null {
    let available: number = 0;
    for (let i = 0; i < this.queue.length && available < size; i++) {
      available += this.queue[i].length - (i === 0 ? this.head : 0);
    }
    const count: number = Math.min(size, available) - Math.min(size, available) % 2;
    if (count <= 0) { return null; }
    const out: Uint8Array = new Uint8Array(count);
    let written: number = 0;
    while (written < count && this.queue.length > 0) {
      const chunk: Uint8Array = this.queue[0];
      const take: number = Math.min(count - written, chunk.length - this.head);
      out.set(chunk.subarray(this.head, this.head + take), written);
      written += take;
      this.head += take;
      if (this.head >= chunk.length) { this.queue.shift(); this.head = 0; }
    }
    return out.buffer;
  }

  /** Push mode: writes the queue out in ~40 ms pieces (each write waits for room: playback paces it). */
  private async pump(renderer: audio.AudioRenderer): Promise<void> {
    const size: number = Math.max(640, Math.round(this.rate * 2 * 0.04));
    while (!this.stopped) {
      const piece: ArrayBuffer | null = this.nextPiece(size);
      if (piece === null) {
        if (this.ended) { break; }
        await new Promise<void>((resolve: () => void): void => { this.wake = resolve; setTimeout(resolve, 30); });
        this.wake = null;
        continue;
      }
      this.onLevel(aiPcmLevel(piece));
      try {
        await renderer.write(piece);
        this.wrote = true;
      } catch (error) {
        if (!this.wrote && !this.stopped) {
          hilog.warn(0x0000, 'AiChat', 'tts written audio refused %{public}s, using the callback', String((error as BusinessError).code));
          await this.toCallbackMode(renderer, piece);
          return;
        }
        break;
      }
    }
    this.onLevel(0);
    // The last of it is heard before the answer counts as read.
    if (!this.stopped) { await aiBounded(renderer.drain(), 4000); }
  }

  /** This device takes no written audio: a renderer fed by its data callback instead (the piece not played first). */
  private async toCallbackMode(old: audio.AudioRenderer, first: ArrayBuffer): Promise<void> {
    this.callbackMode = true;
    this.queue.unshift(new Uint8Array(first));
    this.head = 0;
    this.renderer = null;
    await aiBounded((async (): Promise<void> => {
      try { await old.stop(); } catch (_error) { /* not started */ }
      try { await old.release(); } catch (_error) { /* already released */ }
    })(), ASR_RELEASE_WAIT_MS);
    if (this.stopped) { return; }
    const renderer: audio.AudioRenderer = await this.create(this.rate);
    this.renderer = renderer;
    renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
      this.fill(buffer);
      // Stopping: the callback is taken away once this one has fully returned (a task of its own).
      const after: (() => void) | null = this.afterWrite;
      if (after !== null) { this.afterWrite = null; setTimeout(after, 0); }
      return audio.AudioDataCallbackResult.VALID;
    });
    await renderer.start();
    // Played out (or stopped): finish() waits for this.
    await new Promise<void>((resolve: () => void): void => {
      if (this.stopped) { resolve(); return; }
      this.drained = resolve;
    });
  }

  /** Callback mode: one buffer of the voice (silence once it has run out). */
  private fill(buffer: ArrayBuffer): void {
    const out: Uint8Array = new Uint8Array(buffer);
    let written: number = 0;
    while (written < out.length && this.queue.length > 0) {
      const chunk: Uint8Array = this.queue[0];
      const count: number = Math.min(out.length - written, chunk.length - this.head);
      out.set(chunk.subarray(this.head, this.head + count), written);
      written += count;
      this.head += count;
      if (this.head >= chunk.length) { this.queue.shift(); this.head = 0; }
    }
    if (written < out.length) { out.fill(0, written); }
    this.onLevel(written > 0 ? aiPcmLevel(buffer.slice(0, written - written % 2)) : 0);
    if (written === 0 && (this.ended || this.stopped)) {
      // A few silent buffers after the last sample, so the voice is not cut off at the very end.
      this.idleCalls++;
      if (this.idleCalls > 4 && this.drained !== null) { const done: () => void = this.drained; this.drained = null; done(); }
    } else {
      this.idleCalls = 0;
    }
  }

  /** No more audio: resolves once everything queued has been played. */
  finish(): Promise<void> {
    this.ended = true;
    const wake: (() => void) | null = this.wake;
    if (wake !== null) { this.wake = null; wake(); }
    return this.pumped;
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.queue = [];
    const wake: (() => void) | null = this.wake;
    if (wake !== null) { this.wake = null; wake(); }
    if (this.drained !== null) { const done: () => void = this.drained; this.drained = null; done(); }
    const renderer: audio.AudioRenderer | null = this.renderer;
    this.renderer = null;
    this.onLevel(0);
    if (renderer === null) { return; }
    if (this.callbackMode) {
      // The callback is taken away right after a buffer was written (or after a moment, should none come); until
      // then it writes silence. Stopping with it still there could hang for good.
      await new Promise<void>((resolve: () => void): void => {
        this.afterWrite = resolve;
        setTimeout(resolve, 120);
      });
      this.afterWrite = null;
      try { renderer.off('writeData'); } catch (_error) { /* not listening */ }
    }
    // Stopped, then released — in order; only the waiting is bounded (a player that never reports back must not hold
    // voice mode up). Written audio has no callback to take away: nothing here can hold the app up.
    const sequence = async (): Promise<void> => {
      try { await renderer.stop(); } catch (_error) { /* not started */ }
      try { await renderer.release(); } catch (_error) { /* already released */ }
    };
    await aiBounded(sequence(), ASR_RELEASE_WAIT_MS);
  }
}

/**
 * Voice mode holds the audio focus for its whole session, as Siri does: other apps' media pauses when it opens and
 * stays paused between its turns (each answer used to take the focus and give it back — music came and went in bits),
 * and resumes when voice mode closes.
 */
export class AiAudioFocus {
  private static held: boolean = false;

  static hold(): void {
    if (AiAudioFocus.held) { return; }
    AiAudioFocus.held = true;
    void AiAudioFocus.take();
  }

  private static async take(): Promise<void> {
    try {
      const manager: audio.AudioSessionManager = audio.getAudioManager().getSessionManager();
      await manager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS });
    } catch (error) {
      AiAudioFocus.held = false;
      hilog.warn(0x0000, 'AiChat', 'audio focus unavailable %{public}s', String((error as BusinessError).code));
      return;
    }
    // The session's rule applies once one of our streams starts: a moment of silence as the assistant makes the
    // others pause now, not only when the first answer is read. (Written audio: nothing to take away afterwards.)
    try {
      const renderer: audio.AudioRenderer = await audio.createAudioRenderer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT, rendererFlags: 0 }
      });
      await renderer.start();
      await aiBounded(renderer.write(new ArrayBuffer(1920)).then((): void => {}), 600);
      await aiBounded((async (): Promise<void> => {
        try { await renderer.stop(); } catch (_error) { /* not started */ }
        try { await renderer.release(); } catch (_error) { /* already released */ }
      })(), ASR_RELEASE_WAIT_MS);
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'audio focus ping failed %{public}s', String((error as BusinessError).code));
    }
    hilog.info(0x0000, 'AiChat', 'audio focus held, other media paused');
  }

  static release(): void {
    if (!AiAudioFocus.held) { return; }
    AiAudioFocus.held = false;
    try {
      audio.getAudioManager().getSessionManager().deactivateAudioSession()
        .then((): void => { hilog.info(0x0000, 'AiChat', 'audio focus released'); })
        .catch((_error: BusinessError): void => { /* already inactive */ });
    } catch (_error) { /* already inactive */ }
  }
}

/** PCM from a cloud voice and its sample rate. */
class AiPcmChunk {
  rate: number;
  data: Uint8Array;

  constructor(rate: number, data: Uint8Array) {
    this.rate = rate;
    this.data = data;
  }
}

/** A WAV file's PCM samples and rate (阿里云百炼 returns WAV); anything else is taken as raw PCM at `fallbackRate`. */
function aiWavPcm(data: ArrayBuffer, fallbackRate: number): number[] {
  const view: DataView = new DataView(data);
  if (data.byteLength < 44 || view.getUint32(0, false) !== 0x52494646) { return [fallbackRate, 0, data.byteLength]; }
  let rate: number = fallbackRate;
  let offset: number = 12;
  while (offset + 8 <= data.byteLength) {
    const id: number = view.getUint32(offset, false);
    const size: number = view.getUint32(offset + 4, true);
    if (id === 0x666D7420) { rate = view.getUint32(offset + 12, true); }
    if (id === 0x64617461) { return [rate, offset + 8, Math.min(size, data.byteLength - offset - 8)]; }
    offset += 8 + size + (size % 2);
  }
  return [rate, 44, data.byteLength - 44];
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
  /** Duplex (voice mode): our own player, and where the system voice's synthesized audio goes. */
  private static pcm: AiPcmPlayer | null = null;
  private static sink: ((requestId: string, audio: ArrayBuffer, sequence: number) => void) | null = null;
  private static sinkDone: ((requestId: string) => void) | null = null;
  /**
   * The synthesize-only request (voice mode) still running ('' none). It is never stopped: stopping holds the app
   * up for about a second — right when the user has started talking over the answer. Its audio is simply dropped,
   * and the next request waits for it to end (engineIdle).
   */
  private static synthRequest: string = '';
  /** The system voice is reading by itself (playType 1): the one case stop() stops the engine. */
  private static systemPlaying: boolean = false;
  /** Ends a duplex reading's wait for its synthesis (set while one runs). */
  private static abortDuplex: (() => void) | null = null;

  static available(): boolean { return canIUse('SystemCapability.AI.TextToSpeech'); }

  /**
   * Read a message aloud; onChange gets its id, then '' when done or stopped. Resolves when reading ends, with ''
   * or a note to show (the cloud voice failed and the system voice took over, the male voice is not downloaded…).
   */
  static async speak(context: common.Context, owner: string, id: string, text: string,
    onChange: (id: string) => void, duplex: boolean = false,
    onLevel: (level: number) => void = (_level: number): void => {}): Promise<string> {
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
      if (duplex) {
        note = await AiReadAloud.speakDuplex(context, settings, config, spoken, generation, onLevel);
      } else if (config.enabled && config.provider !== 'system' && config.hasKey) {
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
    // Only the system voice reading by itself is stopped: a stop holds the app up for about a second, and in voice
    // mode (synthesis only) the engine can still count as busy after its last piece — that is left to end by itself.
    if (AiReadAloud.engine !== null && AiReadAloud.systemPlaying) {
      AiReadAloud.systemPlaying = false;
      try { if (AiReadAloud.engine.isBusy()) { AiReadAloud.engine.stop(); } } catch (_error) { /* nothing playing */ }
    }
    const abort: (() => void) | null = AiReadAloud.abortDuplex;
    AiReadAloud.abortDuplex = null;
    if (abort !== null) { abort(); }
    AiReadAloud.waiters.forEach((resolve: () => void): void => { resolve(); });
    AiReadAloud.waiters.clear();
    if (AiReadAloud.player !== null) {
      try { void AiReadAloud.player.stop(); } catch (_error) { /* not playing */ }
    }
    if (AiReadAloud.pcm !== null) { void AiReadAloud.pcm.stop(); AiReadAloud.pcm = null; }
    AiReadAloud.sink = null;
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
        if (response.type === 0 && requestId === AiReadAloud.synthRequest) { AiReadAloud.synthRequest = ''; }
        if (response.type === 0 && AiReadAloud.sinkDone !== null) { AiReadAloud.sinkDone(requestId); }
        if (response.type === 1) { AiReadAloud.wake(requestId); }
      },
      onData: (requestId: string, data: ArrayBuffer, response: textToSpeech.SynthesisResponse): void => {
        if (AiReadAloud.sink !== null) { AiReadAloud.sink(requestId, data, response.sequence); }
      },
      onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
        if (requestId === AiReadAloud.synthRequest) { AiReadAloud.synthRequest = ''; }
        AiReadAloud.wake(requestId);
      },
      onError: (requestId: string, code: number, message: string): void => {
        if (requestId === AiReadAloud.synthRequest) { AiReadAloud.synthRequest = ''; }
        hilog.warn(0x0000, 'AiChat', 'tts error %{public}s %{public}s', code.toString(), message);
        AiReadAloud.wake(requestId);
      }
    });
    AiReadAloud.engine = engine;
    AiReadAloud.enginePerson = person;
    return engine;
  }

  /**
   * Before a new request: the engine finishes what it was doing (an earlier answer's synthesis, dropped unheard,
   * takes a moment); only if it will not, it is stopped.
   */
  private static async engineIdle(engine: textToSpeech.TextToSpeechEngine): Promise<void> {
    for (let i = 0; i < 30 && engine.isBusy(); i++) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
    }
    if (engine.isBusy()) {
      try { engine.stop(); } catch (_error) { /* already done */ }
    }
    AiReadAloud.synthRequest = '';
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
    await AiReadAloud.engineIdle(engine);
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
    AiReadAloud.systemPlaying = true;
    await new Promise<void>((resolve: () => void): void => {
      AiReadAloud.waiters.set(requestId, resolve);
      try {
        engine.speak(spoken, { requestId: requestId, extraParams: extra });
      } catch (error) {
        hilog.warn(0x0000, 'AiChat', 'tts speak failed %{public}s', String((error as BusinessError).code));
        AiReadAloud.wake(requestId);
      }
    });
    if (generation === AiReadAloud.generation) { AiReadAloud.systemPlaying = false; }
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

  // ------------------------------------------------------------------ duplex (voice mode)

  /**
   * Voice mode reads through its own player (AiPcmPlayer) so the user can talk over it: the system voice only
   * synthesizes (playType 0; its own playback would mute the microphone) and hands the audio over, in order; a cloud
   * voice is fetched as PCM. If the cloud fails, the system voice reads the rest.
   */
  private static async speakDuplex(context: common.Context, settings: AiVoiceSettings, config: AiVoiceConfig,
    spoken: string, generation: number, onLevel: (level: number) => void): Promise<string> {
    if (spoken === '') { return ''; }
    let note: string = '';
    let rest: string = spoken;
    if (config.enabled && config.provider !== 'system' && config.hasKey) {
      const key: string = settings.key(config.provider);
      const pieces: string[] = aiSpeechPieces(spoken, TTS_PIECE_CHARS);
      let player: AiPcmPlayer | null = null;
      try {
        for (let i = 0; i < pieces.length; i++) {
          const pcm: AiPcmChunk = await AiReadAloud.cloudPcm(config, key, pieces[i]);
          if (generation !== AiReadAloud.generation) { break; }
          if (player === null) {
            player = new AiPcmPlayer(onLevel);
            AiReadAloud.pcm = player;
            await player.start(pcm.rate);
          }
          player.push(pcm.data);
          rest = pieces.slice(i + 1).join('');
        }
        if (player !== null) { await player.finish(); await player.stop(); }
        if (AiReadAloud.pcm === player) { AiReadAloud.pcm = null; }
        return '';
      } catch (error) {
        const why: string = error instanceof Error ? error.message : '网络不可用';
        hilog.warn(0x0000, 'AiChat', 'cloud tts failed %{public}s', why);
        if (player !== null) { await player.finish(); await player.stop(); }
        if (generation !== AiReadAloud.generation) { return ''; }
        note = '云端语音不可用（' + why + '），已改用系统语音';
      }
    }
    await AiReadAloud.systemDuplex(config.provider === 'system' ? config : new AiVoiceConfig(), rest, generation, onLevel);
    return note;
  }

  /** The system voice, synthesize-only, into our player in sequence order. */
  private static async systemDuplex(config: AiVoiceConfig, text: string, generation: number,
    onLevel: (level: number) => void): Promise<void> {
    if (text === '' || generation !== AiReadAloud.generation) { return; }
    let person: number = parseInt(config.voice, 10) || 13;
    let engine: textToSpeech.TextToSpeechEngine;
    try { engine = await AiReadAloud.systemEngine(person); } catch (_error) { person = 13; engine = await AiReadAloud.systemEngine(13); }
    if (generation !== AiReadAloud.generation) { return; }
    await AiReadAloud.engineIdle(engine);
    if (generation !== AiReadAloud.generation) { return; }
    const player: AiPcmPlayer = new AiPcmPlayer(onLevel);
    AiReadAloud.pcm = player;
    await player.start(16000);
    const requestId: string = 'rd-ttsd-' + generation.toString() + '-' + Date.now().toString(36);
    const waiting: Map<number, Uint8Array> = new Map<number, Uint8Array>();
    let expected: number = 0;
    let synthesized: () => void = (): void => {};
    const done: Promise<void> = new Promise<void>((resolve: () => void): void => { synthesized = resolve; });
    AiReadAloud.sink = (id: string, data: ArrayBuffer, sequence: number): void => {
      if (id !== requestId) { return; }
      waiting.set(sequence, new Uint8Array(data.slice(0)));
      while (waiting.has(expected)) {
        const chunk: Uint8Array | undefined = waiting.get(expected);
        waiting.delete(expected);
        if (chunk !== undefined) { player.push(chunk); }
        expected++;
      }
    };
    AiReadAloud.sinkDone = (id: string): void => { if (id === requestId) { synthesized(); } };
    AiReadAloud.abortDuplex = (): void => { synthesized(); };
    const extra: Record<string, Object> = {};
    extra['speed'] = aiVoiceSpeed(config.rate);
    extra['volume'] = 2;
    extra['pitch'] = 1;
    extra['languageContext'] = 'zh-CN';
    extra['audioType'] = 'pcm';
    extra['soundChannel'] = 3;
    extra['playType'] = 0;
    try {
      AiReadAloud.synthRequest = requestId;
      try { engine.speak(text, { requestId: requestId, extraParams: extra }); } catch (error) {
        AiReadAloud.synthRequest = '';
        throw error as Error;
      }
      // Synthesis is much faster than speech; a stop also ends the wait (abortDuplex).
      await Promise.race([done, new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 60000); })]);
      waiting.forEach((chunk: Uint8Array): void => { player.push(chunk); });
      await player.finish();
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'tts duplex failed %{public}s', String((error as BusinessError).code));
    } finally {
      if (AiReadAloud.sink !== null && AiReadAloud.pcm === player) {
        AiReadAloud.sink = null;
        AiReadAloud.sinkDone = null;
        AiReadAloud.abortDuplex = null;
      }
      await player.stop();
      if (AiReadAloud.pcm === player) { AiReadAloud.pcm = null; }
    }
  }

  /** One piece of text from a cloud voice, as PCM. */
  private static async cloudPcm(config: AiVoiceConfig, key: string, text: string): Promise<AiPcmChunk> {
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
      const info: Record<string, Object> | undefined = output !== undefined ? output['audio'] as Record<string, Object> | undefined : undefined;
      const url: string = info !== undefined && typeof info['url'] === 'string' ? info['url'] as string : '';
      if (!url.startsWith('http')) { throw new Error('没有返回音频'); }
      const wav: ArrayBuffer = await AiReadAloud.getBytes(url);
      const parts: number[] = aiWavPcm(wav, 24000);
      return new AiPcmChunk(parts[0], new Uint8Array(wav, parts[1], parts[2] - parts[2] % 2));
    }
    if (config.provider === 'minimax') {
      const voice: Record<string, Object> = {};
      voice['voice_id'] = config.voice;
      voice['speed'] = aiVoiceSpeed(config.rate);
      voice['vol'] = 1;
      voice['pitch'] = 0;
      const audioSetting: Record<string, Object> = {};
      audioSetting['sample_rate'] = 24000;
      audioSetting['format'] = 'pcm';
      audioSetting['channel'] = 1;
      const body: Record<string, Object> = {};
      body['model'] = config.model;
      body['text'] = text;
      body['stream'] = false;
      body['voice_setting'] = voice;
      body['audio_setting'] = audioSetting;
      body['output_format'] = 'hex';
      const reply: Record<string, Object> = await AiReadAloud.postJson('https://api.minimaxi.com/v1/t2a_v2' +
        (config.groupId !== '' ? '?GroupId=' + encodeURIComponent(config.groupId) : ''), key, body);
      const data: Record<string, Object> | undefined = reply['data'] as Record<string, Object> | undefined;
      const hex: string = data !== undefined && typeof data['audio'] === 'string' ? data['audio'] as string : '';
      if (hex.length < 4) { throw new Error('没有返回音频'); }
      const bytes: Uint8Array = new Uint8Array(Math.floor(hex.length / 4) * 2);
      for (let i = 0; i < bytes.length; i++) { bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16); }
      return new AiPcmChunk(24000, bytes);
    }
    const body: Record<string, Object> = {};
    body['model'] = config.model;
    body['input'] = text;
    body['voice'] = config.voice;
    body['response_format'] = 'pcm';
    body['speed'] = aiVoiceSpeed(config.rate);
    const base: string = config.baseUrl !== '' ? config.baseUrl : 'https://api.openai.com/v1';
    if (!base.startsWith('https://')) { throw new Error('服务地址需要以 https:// 开头'); }
    const pcm: ArrayBuffer = await AiReadAloud.postAudio(base + '/audio/speech', key, body);
    const parts: number[] = aiWavPcm(pcm, 24000);
    return new AiPcmChunk(parts[0], new Uint8Array(pcm, parts[1], parts[2] - parts[2] % 2));
  }

  private static async getBytes(url: string): Promise<ArrayBuffer> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false,
        connectTimeout: 10000, readTimeout: TTS_TIMEOUT_MS
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(AiReadAloud.httpProblem(response.responseCode));
      }
      return response.result as ArrayBuffer;
    } catch (error) {
      if (error instanceof Error) { throw error; }
      throw new Error('网络不可用');
    } finally { client.destroy(); }
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
