import { AiUiStyle } from './AiModels';

/** Colours of one remote AI page style (Claude Code or Codex) in one theme. */
export interface AiStylePalette {
  bg: string;
  surface: string;
  raised: string;
  border: string;
  text: string;
  text2: string;
  text3: string;
  userBubble: string;
  codeBg: string;
  codeText: string;
  accent: string;
  onAccent: string;
  addBg: string;
  addText: string;
  delBg: string;
  delText: string;
  danger: string;
  ok: string;
}

/**
 * Claude Code: warm off-white and terracotta (dark: charcoal and clay). Codex: neutral black and white with
 * GitHub-like diff colours. Both follow the app's light/dark choice.
 */
export function aiStylePalette(style: AiUiStyle, dark: boolean): AiStylePalette {
  if (style === 'codex') {
    return dark ? {
      bg: '#212121', surface: '#2F2F2F', raised: '#262626', border: '#3A3A3A', text: '#ECECEC', text2: '#B4B4B4',
      text3: '#8E8E8E', userBubble: '#303030', codeBg: '#171717', codeText: '#E3E3E3', accent: '#ECECEC',
      onAccent: '#0D0D0D', addBg: '#12351F', addText: '#56D364', delBg: '#3D1517', delText: '#F85149',
      danger: '#F85149', ok: '#56D364'
    } : {
      bg: '#FFFFFF', surface: '#F7F7F8', raised: '#FFFFFF', border: '#E5E5E5', text: '#0D0D0D', text2: '#5D5D5D',
      text3: '#8F8F8F', userBubble: '#F4F4F4', codeBg: '#F7F7F8', codeText: '#24292F', accent: '#0D0D0D',
      onAccent: '#FFFFFF', addBg: '#E6F4EA', addText: '#1A7F37', delBg: '#FDECEA', delText: '#CF222E',
      danger: '#CF222E', ok: '#1A7F37'
    };
  }
  return dark ? {
    bg: '#262624', surface: '#30302E', raised: '#2B2B29', border: '#3E3D39', text: '#F0EEE6', text2: '#C2BFB6',
    text3: '#8E8B83', userBubble: '#3A3936', codeBg: '#1F1E1D', codeText: '#E8E5DC', accent: '#D97757',
    onAccent: '#FFFFFF', addBg: '#22381F', addText: '#8FCB7C', delBg: '#45231C', delText: '#F2A08C',
    danger: '#F2A08C', ok: '#8FCB7C'
  } : {
    bg: '#F5F4EE', surface: '#FFFFFF', raised: '#FAF9F5', border: '#E8E5DC', text: '#1F1E1D', text2: '#5E5D59',
    text3: '#8A8780', userBubble: '#E9E5DA', codeBg: '#EFEDE5', codeText: '#3D3929', accent: '#C96442',
    onAccent: '#FFFFFF', addBg: '#E3F1E0', addText: '#2F6B2F', delBg: '#F7E1DD', delText: '#A2381F',
    danger: '#B3361E', ok: '#4E7A3C'
  };
}
