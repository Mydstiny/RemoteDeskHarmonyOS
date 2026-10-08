/**
 * 应用分身 and Pro (user decision 2026-10-08, plan B). Pro belongs to the signed-in Huawei account, and a clone signs
 * in to none (it is local-only by design), so a clone can neither buy nor restore Pro. During the free trial it has
 * Pro like everyone; afterwards it says so plainly instead of offering a purchase that fails before payment.
 * Plan A (signing a clone in for Pro only) is recorded in docs/codex/plans/2026-10-08-app-clone-pro-plan.md.
 */
export const PRO_CLONE_UNSUPPORTED_LABEL: string = '应用分身暂不支持 Pro';

export const PRO_CLONE_NOTICE: string =
  '应用分身不能登录华为账号，因此无法购买或恢复 Pro。Pro 跟随你的华为账号，请在主应用中购买和使用。';

export const PRO_CLONE_TRIAL_NOTICE: string = '试用结束后，应用分身暂不支持 Pro，请在主应用中使用。';

/** The Pro status label of an instance: a clone without Pro names the reason instead of 免费版. */
export function proCloneLabel(isClone: boolean, effectiveState: string, label: string): string {
  return isClone && effectiveState === 'free' ? PRO_CLONE_UNSUPPORTED_LABEL : label;
}

/** What a locked feature says in a clone: not 开通 Pro, which a clone cannot do. */
export function proCloneLockedDetail(isClone: boolean, detail: string): string {
  return isClone ? '应用分身暂不支持 Pro，请在主应用中使用' : detail;
}
