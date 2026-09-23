# RustDesk UI feedback follow-up — 2026-09-23

## Report

App version reported: 1.1.5.1; package reported: `com.example.remotedesktop`; Phone/Pad, breakpoint `lg`.

1. Session settings toggles change behavior but their checkmarks remain stale until reopening the menu.
2. RustDesk keyboard mapping can be set to Windows while wheel input keeps the macOS-style direction.
3. A floating toolbar hint can remain above every app page until restart.

## Source repair

- Give session-menu rows a render revision and increment it after each click so changed `checked` values are rebuilt immediately.
- Add a RustDesk wheel-direction follow mode. It defaults on, maps Windows to the existing normal direction and macOS to the existing reverse direction, and follows changes to the session keyboard mapping. Choosing the manual reverse-wheel toggle turns follow mode off. Existing stored reverse=true is kept as a manual choice; legacy false adopts the new follow default.
- Remove the session-toolbar `.bindTips` overlay configuration that allowed a non-disappearing hint; keep the accessibility text on each toolbar control.

## Verification

- `default@OhosTestCompileArkTS`: exit 0.
- `assembleHap`: `BUILD SUCCESSFUL in 1 min 39 s 363 ms`.
- Light open-source compliance: passed.
- `git diff --check`: passed.
- Independent review and device acceptance: pending. One HDC target is connected, but no app install or interaction was performed in this checkpoint.
