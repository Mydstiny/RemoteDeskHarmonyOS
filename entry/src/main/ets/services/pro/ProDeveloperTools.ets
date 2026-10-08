import { DEBUG } from 'BuildProfile';

/**
 * The Pro developer tools (设置 › Pro 功能's 权益模拟, the purchase page's 开发者调试 and 沙盒测试, the USB FIDO probe and
 * the 「沙盒 ·」 label): hidden even in Debug builds since 2026-10-07, ahead of release. Set to true to bring them
 * back while developing; Release builds never show them either way.
 */
export const PRO_DEVELOPER_TOOLS_SHOWN: boolean = false;

export function proDeveloperToolsVisible(): boolean {
  return DEBUG && PRO_DEVELOPER_TOOLS_SHOWN;
}
