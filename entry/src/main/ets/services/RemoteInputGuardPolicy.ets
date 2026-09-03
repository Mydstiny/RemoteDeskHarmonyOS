export function shouldBlockRemoteInputForBrowseMode(protocol: string, rustdeskBrowseMode: boolean): boolean {
  return protocol === 'rustdesk' && rustdeskBrowseMode;
}

/** Ability background/minimize signals are authoritative before ArkUI's
 * asynchronous detach work can close its normal input-ready flag. */
export function shouldBlockRemoteInputForLifecycle(isBackground: boolean,
  cleanupStarted: boolean, restorePending: boolean, restoreInProgress: boolean,
  renderPreservedInPip: boolean, pipSurfaceTransferInProgress: boolean): boolean {
  return isBackground || cleanupStarted || restorePending || restoreInProgress ||
    renderPreservedInPip || pipSurfaceTransferInProgress;
}

/** WINDOW_SHOWN only means visible; input must remain fenced until WMS emits
 * WINDOW_ACTIVE. Unknown events preserve the previous focus state. */
export function remoteInputWindowActiveAfterEvent(current: boolean, eventName: string): boolean {
  if (eventName === 'active') {
    return true;
  }
  if (eventName === 'inactive' || eventName === 'hidden' || eventName === 'destroyed') {
    return false;
  }
  return current;
}

/** Track only protocol buttons whose DOWN was actually submitted. Lifecycle
 * cleanup can then release real holds without synthesizing unrelated UPs. */
export function remoteMouseButtonsAfterEvent(current: Array<number>, button: number,
  pressed: boolean): Array<number> {
  const next: Array<number> = current.filter((value: number): boolean =>
    Number.isSafeInteger(value) && value >= 0 && value <= 2);
  if (!Number.isSafeInteger(button) || button < 0 || button > 2) {
    return next;
  }
  const index: number = next.indexOf(button);
  if (pressed && index < 0) {
    next.push(button);
  } else if (!pressed && index >= 0) {
    next.splice(index, 1);
  }
  return next;
}

/** ArkUI may surface a terminal mouse event after a window was minimized.
 * Resolve an UP only against locally observed DOWN buttons. Some drivers omit
 * the released button; that form is unambiguous only while exactly one button
 * is held. */
export function resolvePhysicalMouseReleaseButton(mappedButton: number,
  heldButtons: Array<number>): number {
  const validHeld: Array<number> = heldButtons.filter((value: number): boolean =>
    Number.isSafeInteger(value) && value >= 0 && value <= 2);
  if (mappedButton >= 0) {
    return validHeld.indexOf(mappedButton) >= 0 ? mappedButton : -1;
  }
  return validHeld.length === 1 ? validHeld[0] : -1;
}

export function shouldReleaseAllMouseButtonsForAmbiguousUp(mappedButton: number,
  heldButtons: Array<number>): boolean {
  if (mappedButton >= 0) {
    return false;
  }
  const validHeld: Array<number> = heldButtons.filter((value: number): boolean =>
    Number.isSafeInteger(value) && value >= 0 && value <= 2);
  return validHeld.length > 1;
}

export enum PhysicalMousePressDisposition {
  SEND_NOW = 0,
  STAGE = 1,
  COMMIT_STAGED_THEN_SEND = 2,
  IGNORE_DUPLICATE = 3
}

export function physicalMousePressDisposition(stageEligible: boolean,
  stagedButton: number, heldButtons: Array<number>, pressedButton: number):
  PhysicalMousePressDisposition {
  if (heldButtons.indexOf(pressedButton) >= 0) {
    return PhysicalMousePressDisposition.IGNORE_DUPLICATE;
  }
  if (stagedButton >= 0) {
    return stagedButton === pressedButton ?
      PhysicalMousePressDisposition.IGNORE_DUPLICATE :
      PhysicalMousePressDisposition.COMMIT_STAGED_THEN_SEND;
  }
  if (stageEligible && heldButtons.length === 0) {
    return PhysicalMousePressDisposition.STAGE;
  }
  return PhysicalMousePressDisposition.SEND_NOW;
}

/** Convert the local logical button to the actual protocol button. Keeping
 * this separate from local DOWN tracking is essential when left/right swap is
 * enabled. */
export function mouseButtonForRemote(button: number, swapLeftRight: boolean): number {
  if (!swapLeftRight) {
    return button;
  }
  if (button === 0) {
    return 2;
  }
  if (button === 2) {
    return 0;
  }
  return button;
}

export function shouldReleaseMouseButtonsBeforeSwapChange(currentSwap: boolean,
  nextSwap: boolean, heldRemoteButtons: Array<number>): boolean {
  return currentSwap !== nextSwap && heldRemoteButtons.length > 0;
}

export function shouldRecoverPointerFocusAfterMouseRelease(heldButtons: Array<number>,
  stagedClickPending: boolean): boolean {
  return heldButtons.length === 0 && !stagedClickPending;
}

export function remoteInputBlockedReason(protocol: string, rustdeskBrowseMode: boolean): string {
  if (shouldBlockRemoteInputForBrowseMode(protocol, rustdeskBrowseMode)) {
    return 'RustDesk 浏览模式已开启，仅查看远端画面，不会发送键盘、鼠标或触控输入';
  }
  return '';
}
