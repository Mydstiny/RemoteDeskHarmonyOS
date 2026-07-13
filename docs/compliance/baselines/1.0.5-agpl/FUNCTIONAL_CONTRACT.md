# Functional non-regression contract

The migration must not change protocol bytes, NAPI/native ABI, session threads,
rendering, audio, input, authentication, host/credential/cloud schemas,
Preferences keys, permissions, bundle/version identity, or existing navigation.
RDP, RustDesk, SSH/SFTP and VNC keep their current supported behavior.

The only permitted visible change is the About license/source wording.
