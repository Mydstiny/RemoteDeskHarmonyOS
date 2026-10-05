/*
 * RemoteDesk device provider for the vendored MS-RDPEWA client channel.
 *
 * The channel never enumerates or opens system HID devices. Every request goes through the RemoteDesk security-key
 * broker of the RDP session: the local user confirms the remote relying party, authorizes one USB security key,
 * enters a PIN locally and is told when to touch the key. Every wait is bounded, ends on cancellation and ends
 * with the remote request's own timeout.
 */
#ifndef REMOTEDESK_RDPEWA_PROVIDER_H
#define REMOTEDESK_RDPEWA_PROVIDER_H

#include <winpr/wtypes.h>
#include <freerdp/freerdp.h>
#include <fido.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Windows reports this HRESULT when the user cancels a WebAuthn request. */
#define REMOTEDESK_RDPEWA_HRESULT_CANCELLED ((HRESULT)0x80090036L)

typedef enum
{
	REMOTEDESK_RDPEWA_REGISTER = 1,
	REMOTEDESK_RDPEWA_SIGN_IN = 2
} RemoteDeskRdpewaOperation;

/**
 * Starts a remote request when it is dispatched: clears the previous cancellation and bounds the request's prompts
 * by its timeout (milliseconds, 0 for none). FALSE when the session has no open broker.
 */
BOOL remotedesk_rdpewa_begin(rdpContext* context, UINT32 timeoutMs);

/** Milliseconds left before the current request's deadline, or INFINITE. */
DWORD remotedesk_rdpewa_remaining(rdpContext* context);

/** Asks the local user whether the remote relying party may use the security key. */
BOOL remotedesk_rdpewa_confirm(rdpContext* context, const char* rpId, RemoteDeskRdpewaOperation operation);

/**
 * Opens the security key authorized for this session. When interactive, the user may be asked to select and
 * authorize a key; otherwise only a key that is already authorized is used and nothing is shown.
 * product receives a display name. The caller closes and frees the device.
 */
fido_dev_t* remotedesk_rdpewa_open(rdpContext* context, BOOL interactive, char* product, size_t productLen);

/** Whether a key is authorized for this session, without any device I/O. product receives its name. */
BOOL remotedesk_rdpewa_authorized(rdpContext* context, char* product, size_t productLen);

/** PIN entered locally; the caller wipes and frees it. NULL when the user cancels. */
char* remotedesk_rdpewa_pin(rdpContext* context, int retries);

/** Shows or hides the "touch your security key" prompt. */
void remotedesk_rdpewa_touch(rdpContext* context, BOOL waiting);

/** Manual-reset event signalled when the user, the server or the session cancels the request. */
HANDLE remotedesk_rdpewa_cancel_event(rdpContext* context);

/** Cancels the in-flight request (server CANCEL_CUR_OP or channel close). */
void remotedesk_rdpewa_cancel(rdpContext* context);

#ifdef __cplusplus
}
#endif

#endif /* REMOTEDESK_RDPEWA_PROVIDER_H */
