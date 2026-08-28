# VNC Cursor and Wheel Regression Plan

## Goal

Restore usable VNC scrolling across all HarmonyOS input sources and prevent the pointer from disappearing while macOS Screen Sharing delays or omits a usable protocol cursor.

## Invariants

1. Mouse-wheel degrees and `scrollStep` are interpreted according to the local API 23 contract; the configured coefficient is applied exactly once.
2. Touchpad px/vp streams remain continuous and are never interpreted as discrete mouse degrees.
3. RFB button-4/5 output is bounded per input sample and cannot retain a post-release backlog.
4. Direction, source, idle, begin, end and cancel transitions cannot leak fractional movement into another gesture.
5. Auto cursor mode always has a visible bootstrap pointer until a valid protocol cursor is ready; explicit hidden mode remains hidden.
6. RDP, RustDesk and Moonlight wheel behavior is unchanged.

## Steps

1. Replace tests that encode `raw=45 -> 1`, four physical samples per tick and `10vp` virtual thresholds with captured-device behavioral contracts.
2. Pass `scrollStep` into the VNC discrete normalizer and return a bounded signed logical tick count, with a portable sign fallback.
3. Retune continuous VNC virtual and physical curves while preserving fractional state and lifecycle resets.
4. Correct the VNC system-pointer policy and cover fallback, protocol-ready and explicit-hidden transitions.
5. Run focused tests, exact Hvigor gates, signed HAP assembly, diff checks and Light compliance.
6. Commit a precise checkpoint, obtain independent sub-agent review, remediate findings and repeat gates before device installation.
7. Apply the device-acceptance result as one VNC-only 5x wire gain across virtual touchpad, physical touchpad and physical mouse, with a native burst bound that cannot truncate the supported maximum.
