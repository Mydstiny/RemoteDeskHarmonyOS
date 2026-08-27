# VNC Wheel Input Normalization Plan

## Goal

Make VNC scrolling predictable across the in-app virtual touchpad, HarmonyOS PC physical touchpads and physical mouse wheels without changing other protocols.

## Invariants

1. A valid mouse-only `scrollStep` takes precedence over Axis lifecycle metadata.
2. One physical mouse detent produces one RFB wheel tick; timing never multiplies it.
3. Continuous physical input is normalized per gesture and cannot depend on a universal raw value such as 45.
4. Virtual two-finger input uses vp-distance accumulation, retains fractional motion and has a strict per-frame and post-release budget.
5. `BEGIN`, `END`, `CANCEL`, direction changes, source changes and idle gaps cannot leak remainder into another gesture.
6. The reverse-wheel preference is applied once after source normalization.
7. RDP, RustDesk and Moonlight paths retain their existing policies.

## Steps

1. Replace tests that encode the faulty `/45`, four-click baseline and unbounded fling with behavioral contracts for all three VNC input sources.
2. Refactor the VNC physical classifier so `scrollStep` is authoritative and AxisAction only controls gesture state.
3. Add a per-gesture continuous physical normalizer with an adaptive unit baseline, fractional remainder, bounded output and reset semantics.
4. Add a vp-based virtual touchpad normalizer and remove the unconditional minimum tick and long release recursion.
5. Integrate both state machines into `RemoteDesktop`, add bounded diagnostic fields and keep the native RFB sender unchanged.
6. Run targeted tests, exact Hvigor gates, Light compliance, diff checks and available device/emulator validation before a precise commit.
