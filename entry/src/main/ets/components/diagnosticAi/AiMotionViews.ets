import { curves } from '@kit.ArkUI';
import { AI_MOTION_DONE, AI_MOTION_ORB, AI_MOTION_REDUCED, AI_MOTION_SPEED, AI_MOTION_THINKING,
  aiMotionSpeedFactor } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';
import { AiKernelRing } from './XiaoyiOrb';
import { AI_FLOAT_ORB, AiAssistantGlyph, AiCheckmark, AiSiriOrb } from './AiIslandChrome';
import { AiVoiceOrb } from './AiVoiceOrb';
import { AiAuroraOrb, AiAuroraRing, AiCoinDiscRing, AiCometOrbit, AiHaloRing, AiIslandRingsCheck, AiRippleCheck, AiSparkleCheck,
  AiVoiceStrands } from './AiMotionCanvas';

export { AiIslandRingsCheck };

/**
 * The AI motions the user can choose in AI 动效. Each view takes an explicit `style` (the settings previews) or,
 * left empty, follows the saved choice — and its quietest style while 减少动态效果 is on.
 */

/** 简洁: three dots rising and falling one after another. */
@Component
struct AiQuietDots {
  @Prop dotsSize: number = 34;
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  @State private lift: number = 0;

  aboutToAppear(): void {
    if (this.reduced) { return; }
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 520, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.lift = 1; });
    }, 16);
  }

  build() {
    Row({ space: this.dotsSize * 0.1 }) {
      ForEach([0, 1, 2], (i: number): void => {
        Circle().width(this.dotsSize * 0.18).height(this.dotsSize * 0.18).fill('#FFFFFF')
          .opacity(0.45 + 0.55 * (i === 1 ? 1 - this.lift : this.lift))
          .translate({ y: (i === 1 ? this.lift - 0.5 : 0.5 - this.lift) * this.dotsSize * 0.12 })
      }, (i: number): string => 'qd' + i.toString())
    }.width(this.dotsSize).height(this.dotsSize).justifyContent(FlexAlign.Center)
  }
}

/** The thinking / working indicator in the chosen style. */
@Component
export struct AiThinkingIndicator {
  @Prop indicatorSize: number = 34;
  @Prop style: string = '';
  /** One still frame (settings tiles that are not selected). */
  @Prop still: boolean = false;
  /** The ring opens from a dot as it appears; false shows it open at once (it was already there, only unseen). */
  @Prop opensFromDot: boolean = true;
  @StorageProp(AI_MOTION_THINKING) saved: string = 'dots';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;

  private effective(): string {
    if (this.style !== '') { return this.style; }
    return this.reduced ? 'minimal' : this.saved;
  }

  build() {
    Stack() {
      if (this.effective() === 'discs') {
        AiCoinDiscRing({ ringSize: this.indicatorSize, still: this.still })
      } else if (this.effective() === 'aurora') {
        AiAuroraRing({ ringSize: this.indicatorSize, still: this.still })
      } else if (this.effective() === 'halo') {
        AiHaloRing({ ringSize: this.indicatorSize, still: this.still })
      } else if (this.effective() === 'strands') {
        AiVoiceStrands({ ringSize: this.indicatorSize, still: this.still })
      } else if (this.effective() === 'orbit') {
        AiCometOrbit({ ringSize: this.indicatorSize, still: this.still })
      } else if (this.effective() === 'wave') {
        AiVoiceOrb({ orbSize: this.indicatorSize, sphere: false, active: true, still: this.still })
      } else if (this.effective() === 'minimal') {
        AiQuietDots({ dotsSize: this.indicatorSize })
      } else {
        AiKernelRing({ ringSize: this.indicatorSize, still: this.still, opensFromDot: this.opensFromDot })
      }
    }.width(this.indicatorSize).height(this.indicatorSize)
  }
}

/** 小艺标志 / 玻璃球: a dark glass sphere, with the assistant mark or only a soft breathing light. */
@Component
struct AiGlassOrb {
  @Prop orbSize: number = AI_FLOAT_ORB;
  @Prop mark: boolean = false;
  @Prop active: boolean = false;
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  @State private breath: number = 0;

  aboutToAppear(): void {
    if (this.reduced) { return; }
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 1800, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.breath = 1; });
    }, 16);
  }

  build() {
    Stack() {
      Column().width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .radialGradient({ center: ['50%', '42%'], radius: this.orbSize * 0.62,
          colors: [['#FF16161D', 0], ['#FF07070B', 0.72], ['#FF1C2230', 1]] })
      // Inner light, brighter while the assistant works.
      Column().width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .radialGradient({ center: ['50%', '62%'], radius: this.orbSize * 0.5,
          colors: [[this.active ? '#664D8CFF' : '#334D8CFF', 0], ['#00000000', 1]] })
        .opacity(0.6 + 0.4 * this.breath)
      if (this.mark) {
        AiAssistantGlyph({ glyphSize: this.orbSize * 0.56, ink: '#F2F2F7' })
      }
      Column().width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .border({ width: 1, color: { top: '#38FFFFFF', left: '#4DFFFFFF', right: '#4DFFFFFF', bottom: '#73FFFFFF' } })
      Column().width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .radialGradient({ center: ['50%', '6%'], radius: this.orbSize * 0.42,
          colors: [['#2EFFFFFF', 0], ['#00FFFFFF', 1]] })
    }.width(this.orbSize).height(this.orbSize)
    .shadow({ radius: 14, color: '#59000000', offsetY: 4 })
  }
}

/** The floating orb in the chosen style. */
@Component
export struct AiFloatingOrb {
  @Prop orbSize: number = AI_FLOAT_ORB;
  @Prop active: boolean = false;
  @Prop style: string = '';
  /** One still frame (settings tiles that are not selected). */
  @Prop still: boolean = false;
  @StorageProp(AI_MOTION_ORB) saved: string = 'voice';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;

  private effective(): string {
    if (this.style !== '') { return this.style; }
    return this.reduced ? 'glass' : this.saved;
  }

  build() {
    Stack() {
      if (this.effective() === 'sine') {
        AiSiriOrb({ orbSize: this.orbSize, active: this.active, still: this.still })
      } else if (this.effective() === 'aurora') {
        AiAuroraOrb({ orbSize: this.orbSize, active: this.active, still: this.still })
      } else if (this.effective() === 'halo') {
        AiHaloRing({ ringSize: this.orbSize, backdrop: true, active: this.active, still: this.still })
      } else if (this.effective() === 'xiaoyi') {
        AiGlassOrb({ orbSize: this.orbSize, mark: true, active: this.active })
      } else if (this.effective() === 'glass') {
        AiGlassOrb({ orbSize: this.orbSize, mark: false, active: this.active })
      } else {
        AiVoiceOrb({ orbSize: this.orbSize, active: this.active, still: this.still })
      }
    }.width(this.orbSize).height(this.orbSize)
  }
}

/** 弹出对勾: the check pops in with a spring. */
@Component
struct AiBounceCheck {
  @Prop markSize: number = 30;
  @State private shown: number = 0;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.55) }, (): void => { this.shown = 1; });
    }, 16);
  }

  build() {
    Stack() {
      Circle().width(this.markSize).height(this.markSize).fill('#34C759')
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.markSize * 0.56).fontWeight(FontWeight.Bold)
        .fontColor(['#FFFFFF'])
    }.width(this.markSize).height(this.markSize)
    .scale({ x: 0.3 + 0.7 * this.shown, y: 0.3 + 0.7 * this.shown })
    .opacity(this.shown)
  }
}

/** The small done mark in the chosen style (画圆打勾 / 弹出对勾 / 涟漪扩散 / 粒子绽放). */
@Component
export struct AiDoneMark {
  @Prop markSize: number = 30;
  @Prop style: string = '';
  @StorageProp(AI_MOTION_DONE) saved: string = 'check';
  /** The finished mark at once (settings tiles that are not selected). */
  @Prop still: boolean = false;

  private chosen(): string { return this.style !== '' ? this.style : this.saved; }

  build() {
    Stack() {
      if (this.chosen() === 'bounce') {
        AiBounceCheck({ markSize: this.markSize })
      } else if (this.chosen() === 'ripple') {
        AiRippleCheck({ markSize: this.markSize, still: this.still })
      } else if (this.chosen() === 'sparkle') {
        AiSparkleCheck({ markSize: this.markSize, still: this.still })
      } else {
        AiCheckmark({ markSize: this.markSize })
      }
    }.width(this.markSize).height(this.markSize)
  }
}

/** Settings preview of 展开动画: a capsule growing into a panel, looping. */
@Component
export struct AiOpenPreview {
  @Prop style: string = 'morph';
  @State private stage: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval((): void => { this.play(); }, 2400);
    this.play();
  }

  aboutToDisappear(): void { if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; } }

  private play(): void {
    this.stage = 0;
    if (this.style === 'none') {
      setTimeout((): void => { this.stage = 2; }, 400);
    } else if (this.style === 'liquid') {
      setTimeout((): void => {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.55, 0.55) }, (): void => { this.stage = 2; });
      }, 300);
    } else if (this.style === 'focus') {
      setTimeout((): void => {
        this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseOut }, (): void => { this.stage = 2; });
      }, 300);
    } else if (this.style === 'fade') {
      setTimeout((): void => {
        this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, (): void => { this.stage = 2; });
      }, 300);
    } else {
      setTimeout((): void => {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.stage = 1; });
      }, 300);
      setTimeout((): void => {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.stage = 2; });
      }, 800);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width(this.style === 'morph' ? (this.stage === 0 ? 26 : this.stage === 1 ? 54 : 60) : 60)
        .height(this.style === 'morph' ? (this.stage === 0 ? 9 : this.stage === 1 ? 14 : 40) : 40)
        .borderRadius(this.style === 'morph' && this.stage < 2 ? 7 : 12)
        .backgroundColor('#000000')
        .opacity(this.style === 'morph' || this.style === 'liquid' ? 1 : this.stage === 2 ? 1 : 0)
        .scale(this.style === 'liquid' ? { x: this.stage === 2 ? 1 : 0.35, y: this.stage === 2 ? 1 : 0.2, centerX: '50%', centerY: 0 } :
          this.style === 'focus' ? { x: this.stage === 2 ? 1 : 0.86, y: this.stage === 2 ? 1 : 0.86 } : { x: 1, y: 1 })
        .blur(this.style === 'focus' && this.stage < 2 ? 12 : 0)
        .margin({ top: 6 })
    }.width(72).height(56)
  }
}
