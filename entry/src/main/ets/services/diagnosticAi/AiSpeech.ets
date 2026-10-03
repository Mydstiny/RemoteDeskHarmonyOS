import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { aiEnsurePermission } from './AiSystemTools';
import { aiMarkdownPlain } from './AiMarkdownPolicy';

/**
 * 语音 for the AI chat, on the device (Chinese, offline): dictation into the chat field, and reading an answer aloud.
 * One engine of each kind for the app, created on first use.
 */
export class AiVoiceInput {
  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static sessionId: string = '';

  static available(): boolean { return canIUse('SystemCapability.AI.SpeechRecognizer'); }

  /**
   * Listen until the speaker stops (or stop() is called). onText gets the words so far (final once isFinal); onEnd
   * comes once, with '' or what went wrong.
   */
  static async start(context: common.UIAbilityContext, onText: (text: string, final: boolean) => void,
    onEnd: (problem: string) => void): Promise<void> {
    if (!AiVoiceInput.available()) { onEnd('当前设备不支持语音输入'); return; }
    if (!(await aiEnsurePermission(context, 'ohos.permission.MICROPHONE'))) { onEnd('没有麦克风权限'); return; }
    try {
      if (AiVoiceInput.engine === null) {
        AiVoiceInput.engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
      }
      const engine: speechRecognizer.SpeechRecognitionEngine = AiVoiceInput.engine;
      if (engine.isBusy()) { engine.cancel(AiVoiceInput.sessionId); }
      const sessionId: string = 'rd-asr-' + Date.now().toString();
      AiVoiceInput.sessionId = sessionId;
      let ended: boolean = false;
      const end = (problem: string): void => { if (!ended) { ended = true; onEnd(problem); } };
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
      const extra: Record<string, Object> = {};
      // 0: the engine records from the microphone itself; a pause of 2 s ends the sentence; at most 60 s.
      extra['recognitionMode'] = 0;
      extra['vadBegin'] = 2500;
      extra['vadEnd'] = 2000;
      extra['maxAudioDuration'] = 60000;
      engine.startListening({ sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }, extraParams: extra });
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'asr start failed %{public}s', String((error as BusinessError).code));
      onEnd('语音输入启动失败');
    }
  }

  static stop(): void {
    if (AiVoiceInput.engine !== null && AiVoiceInput.sessionId !== '') {
      try { AiVoiceInput.engine.finish(AiVoiceInput.sessionId); } catch (_error) { /* already done */ }
    }
  }
}

export class AiReadAloud {
  private static engine: textToSpeech.TextToSpeechEngine | null = null;
  /** The message being read ('' none). */
  static speakingId: string = '';
  private static onChange: (id: string) => void = (_id: string): void => {};

  static available(): boolean { return canIUse('SystemCapability.AI.TextToSpeech'); }

  /** Read a message aloud (Markdown marks dropped); onChange gets its id, then '' when done or stopped. */
  static async speak(id: string, text: string, onChange: (id: string) => void): Promise<void> {
    AiReadAloud.stop();
    AiReadAloud.onChange = onChange;
    try {
      if (AiReadAloud.engine === null) {
        const extra: Record<string, Object> = {};
        extra['style'] = 'interaction-broadcast';
        extra['locate'] = 'CN';
        extra['name'] = 'RemoteDeskAiReadAloud';
        AiReadAloud.engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 13, online: 1, extraParams: extra });
        AiReadAloud.engine.setListener({
          onStart: (_r: string, _response: textToSpeech.StartResponse): void => { /* playing */ },
          // type 0 is synthesis done (long before the voice stops); 1 is playback done.
          onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
            if (response.type === 1) { AiReadAloud.finished(requestId); }
          },
          onStop: (requestId: string, _response: textToSpeech.StopResponse): void => { AiReadAloud.finished(requestId); },
          onError: (requestId: string, code: number, message: string): void => {
            hilog.warn(0x0000, 'AiChat', 'tts error %{public}s %{public}s', code.toString(), message);
            AiReadAloud.finished(requestId);
          }
        });
      }
      const plain: string = text.split('\n').map((line: string): string => aiMarkdownPlain(line.replace(/^\s*(#+|[-*+•]|\d+[.)、]|>)\s*/, ''))
        .replace(/\|/g, '，')).filter((line: string): boolean => line.trim() !== '' && !/^[-:\s，]+$/.test(line)).join('。')
        .slice(0, 9000);
      const extra: Record<string, Object> = {};
      extra['speed'] = 1;
      extra['volume'] = 2;
      extra['pitch'] = 1;
      extra['languageContext'] = 'zh-CN';
      extra['audioType'] = 'pcm';
      extra['soundChannel'] = 3;
      extra['playType'] = 1;
      AiReadAloud.speakingId = id;
      onChange(id);
      AiReadAloud.engine.speak(plain, { requestId: id, extraParams: extra });
    } catch (error) {
      hilog.warn(0x0000, 'AiChat', 'tts failed %{public}s', String((error as BusinessError).code));
      AiReadAloud.speakingId = '';
      onChange('');
    }
  }

  private static finished(requestId: string): void {
    if (requestId !== AiReadAloud.speakingId) { return; }
    AiReadAloud.speakingId = '';
    AiReadAloud.onChange('');
  }

  static stop(): void {
    if (AiReadAloud.engine !== null && AiReadAloud.speakingId !== '') {
      try { AiReadAloud.engine.stop(); } catch (_error) { /* nothing playing */ }
    }
    if (AiReadAloud.speakingId !== '') {
      AiReadAloud.speakingId = '';
      AiReadAloud.onChange('');
    }
  }
}
