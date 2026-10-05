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

/** What answers a request: nothing (the user declined), a USB security key, or the paired phone's passkey. */
typedef enum
{
	REMOTEDESK_RDPEWA_NONE = 0,
	REMOTEDESK_RDPEWA_USB_KEY = 1,
	REMOTEDESK_RDPEWA_PHONE = 2
} RemoteDeskRdpewaAuthenticator;

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
 * Opens the authenticator chosen for this session. When interactive, the user may be asked to choose one: a USB
 * security key (opened and returned; the caller closes and frees it) or the paired phone (NULL is returned and
 * kind says REMOTEDESK_RDPEWA_PHONE). Otherwise only an earlier choice is used and nothing is shown. product
 * receives a display name; kind receives what was chosen (REMOTEDESK_RDPEWA_NONE on failure).
 */
fido_dev_t* remotedesk_rdpewa_open(rdpContext* context, BOOL interactive, char* product, size_t productLen,
                                   RemoteDeskRdpewaAuthenticator* kind);

/**
 * Sends one CTAP command (command byte + CBOR) to the paired phone and returns its CTAP response (status byte +
 * CBOR) in a new buffer the caller frees. FALSE when the user, the server or the session cancelled, or it timed out.
 */
BOOL remotedesk_rdpewa_passkey(rdpContext* context, const BYTE* command, size_t commandLen, BYTE** response,
                               size_t* responseLen);

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
