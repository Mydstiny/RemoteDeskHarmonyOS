/**
 * ProFeedbackPolicy.ets — Pro 专属反馈群的云端清单地址。
 *
 * 清单和二维码仍由反馈站点轮换；应用只固定受信任的 HTTPS 清单地址，
 * 不把二维码图片打包进 HAP，也不把 Pro 权益状态交给远端页面决定。
 */

export const PRO_FEEDBACK_FEATURE: string = 'pro.feedback';
export const PRO_FEEDBACK_CHANLIAN_MANIFEST_URL: string =
  'https://lijiong.online/feedback/pro-chanlian.json';
export const PRO_FEEDBACK_QQ_MANIFEST_URL: string =
  'https://lijiong.online/feedback/pro-qq.json';
