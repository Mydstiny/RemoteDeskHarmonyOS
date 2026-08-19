export interface MoonlightNetworkBinding {
  ownerToken: number;
  nativeSessionId: number;
  activeNetId: number;
  unavailable: boolean;
}

export function moonlightNetIdIsValid(netId: number): boolean {
  // HarmonyOS API 23 reserves 0 for no default network and documents real
  // network IDs as values greater than or equal to 100.
  return Number.isSafeInteger(netId) && netId >= 100;
}

export function moonlightNetworkLostMatches(
  binding: MoonlightNetworkBinding,
  eventNetId: number,
  ownerToken: number,
  nativeSessionId: number): boolean {
  return moonlightNetIdIsValid(binding.activeNetId) &&
    binding.activeNetId === eventNetId &&
    binding.ownerToken === ownerToken && ownerToken > 0 &&
    binding.nativeSessionId === nativeSessionId && nativeSessionId > 0;
}

/**
 * Transport failure can reach the coordinator before NetConnection emits its
 * loss callback. During that reconnect window the immutable binding remains
 * the callback identity even though the live nativeSessionId mirror is -1.
 */
export function moonlightNetworkCallbackSessionId(
  binding: MoonlightNetworkBinding,
  nativeSessionId: number,
  reconnectWindowPresent: boolean): number {
  if (Number.isSafeInteger(nativeSessionId) && nativeSessionId > 0) {
    return nativeSessionId;
  }
  if (reconnectWindowPresent && Number.isSafeInteger(binding.nativeSessionId) &&
      binding.nativeSessionId > 0) {
    return binding.nativeSessionId;
  }
  return -1;
}

export function moonlightNetworkAvailableMatchesDefault(
  eventNetId: number, defaultNetId: number,
  ownerToken: number, expectedOwnerToken: number,
  nativeSessionId: number, expectedNativeSessionId: number): boolean {
  return moonlightNetIdIsValid(eventNetId) && eventNetId === defaultNetId &&
    ownerToken > 0 && ownerToken === expectedOwnerToken &&
    nativeSessionId > 0 && nativeSessionId === expectedNativeSessionId;
}

export function shouldResumeMoonlightInputAfterNetworkAvailable(
  wasUnavailable: boolean, reconnectWindowPresent: boolean,
  reconnectRuntimeLaunched: boolean, inputReady: boolean,
  routeCurrent: boolean): boolean {
  return wasUnavailable && !reconnectWindowPresent &&
    !reconnectRuntimeLaunched && inputReady && routeCurrent;
}
