/**
 * vnc_certificate_probe.h - bounded, RFB-free VNC TLS certificate probe.
 */
#ifndef VNC_CERTIFICATE_PROBE_H
#define VNC_CERTIFICATE_PROBE_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>

enum class VncCertificateProbeErrorCode : int {
    None = 0,
    InvalidInput = 1001,
    ResolveFailed = 1002,
    ConnectFailed = 1003,
    ConnectTimeout = 1004,
    TlsContextFailed = 1005,
    TlsHandshakeFailed = 1006,
    TlsTimeout = 1007,
    Cancelled = 1008,
    NoCertificate = 1009,
    FingerprintFailed = 1010,
    TlsVersionRejected = 1011,
    MetadataFailed = 1012,
    CertificateChainTooDeep = 1013,
    ResolveTimeout = 1014,
};

struct VncCertificateProbeConfig {
    std::string host;
    int port = 5900;
    std::string serverName;
    int timeoutMs = 10000;
    std::shared_ptr<std::atomic_bool> cancelled;
};

struct VncCertificateInfo {
    bool ok = false;
    std::string host;
    int port = 5900;
    std::string serverName;
    std::string fingerprintSha256;
    std::string commonName;
    std::string subject;
    std::string issuer;
    int64_t notBeforeMs = 0;
    int64_t notAfterMs = 0;
    bool rootTrusted = false;
    bool hostMismatch = false;
    std::string tlsVersion;
    std::string cipherCategory;
    int errorCode = static_cast<int>(VncCertificateProbeErrorCode::None);
    std::string errorMessageCategory;
    std::string errorMessage;
};

/** Performs TCP + immediate TLS only; it never sends RFB or Repeater bytes. */
VncCertificateInfo probeVncCertificate(const VncCertificateProbeConfig& config);

/** Normalizes accepted SHA-256 display forms to exactly 64 lowercase hex chars. */
bool vncNormalizeCertificateFingerprint(const std::string& value, std::string& normalized);

bool vncCertificateFingerprintIsCanonical(const std::string& value);
std::string vncCertificateProbeErrorCategory(int errorCode);
std::string vncCertificateProbeErrorMessage(int errorCode);

/** Redacts the full pin from connection logs while preserving UI handoff text. */
std::string vncRedactCertificateMessageForLog(const std::string& message);

#endif // VNC_CERTIFICATE_PROBE_H
