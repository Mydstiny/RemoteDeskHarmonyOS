# VNC Cursor and Wheel Regression Queue

Updated: 2026-08-27 Asia/Shanghai

## Now

1. Correct discrete mouse, physical touchpad and virtual touchpad VNC scaling.
2. Preserve a visible local cursor while macOS VNC protocol cursor data is unavailable.
3. Add focused regression coverage and run exact build/package/compliance gates.

## Next

1. Obtain independent review and remediate every finding.
2. Install the signed HAP on `192.168.3.236:40123` and capture acceptance evidence.
3. Push the reviewed branch and complete PR/main closure after acceptance.

## Later / external acceptance

- Confirm UltraVNC and macOS Screen Sharing cursor transitions and scroll feel with physical mouse, physical touchpad and the in-app virtual touchpad.
