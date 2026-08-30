/**
 * vnc_transport.h - VNC byte transports.
 *
 * This layer deliberately knows nothing about RFB messages. It owns the
 * socket, optional TLS session, WebSocket framing and UltraVNC pairing bytes
 * so the RFB engine can consume one ordered byte stream.
 */
#ifndef VNC_TRANSPORT_H
#define VNC_TRANSPORT_H

#include <cstddef>
#include <cstdint>
#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct VncTransportConfig {
    std::string host;
    int port = 5900;
    std::string transport = "direct_tcp";
    std::string repeaterMode = "mode12";
    std::string repeaterTarget;
    std::string websocketPath = "/vnc";
    // The resolver and the live transport share this explicit SNI contract.
    // It is normally the direct host or the selected gateway host.
    std::string serverName;
    bool tls = false;
    int connectTimeoutMs = 10000;
    std::string expectedCertificateFingerprintSha256;
    // Shared with the owning connection attempt so close/cancel can produce a
    // stable certificate cancellation code instead of a generic I/O error.
    std::shared_ptr<std::atomic_bool> cancelled;
    // Non-zero only for a live session attempt. The process network fence
    // invalidates DNS, candidate racing, TLS and established I/O from an old
    // default-network generation. Standalone certificate probes keep zero
    // here and use their existing request-scoped cancellation owner.
    uint64_t networkGeneration = 0;
#if defined(RDP_TESTS_ONLY)
    std::function<void()> afterConnectRestoreForTesting;
#endif
};

class VncTransport {
public:
    VncTransport();
    ~VncTransport();

    VncTransport(const VncTransport&) = delete;
    VncTransport& operator=(const VncTransport&) = delete;

    bool connect(const VncTransportConfig& config, std::string& error);
    bool readExact(uint8_t* destination, size_t size, int timeoutMs, std::string& error);
    bool writeAll(const uint8_t* source, size_t size, std::string& error);
    void close();
    bool isOpen() const;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // Takes ownership of one connected stream descriptor so established read
    // and write cancellation can exercise the production I/O loops.
    void adoptConnectedSocketForTesting(int socketFd,
                                        uint64_t networkGeneration);
#endif

private:
    bool connectTcp(const std::string& host, int port,
                    std::chrono::steady_clock::time_point deadline,
                    const std::shared_ptr<std::atomic_bool>& cancelled,
                    uint64_t networkGeneration,
                    std::string& error);
    bool enableTls(const VncTransportConfig& config,
                   std::chrono::steady_clock::time_point deadline,
                   std::string& error);
    bool validatePeerCertificate(const std::string& expectedFingerprint, std::string& error);
    bool websocketHandshake(const VncTransportConfig& config, std::string& error);
    bool readRaw(uint8_t* destination, size_t size, int timeoutMs, std::string& error);
    bool writeRaw(const uint8_t* source, size_t size, std::string& error);
    bool readWebSocketBytes(uint8_t* destination, size_t size, int timeoutMs, std::string& error);
    bool writeWebSocketFrame(uint8_t opcode, const uint8_t* source, size_t size,
                             std::string& error);
    bool readWebSocketFrame(std::vector<uint8_t>& payload, uint8_t& opcode,
                            int timeoutMs, std::string& error);
    bool sendRepeaterPairing(const VncTransportConfig& config, std::string& error);
    static std::string base64(const uint8_t* data, size_t size);
    static std::string lower(std::string value);
    static bool constantTimeEqual(const std::string& left, const std::string& right);

    int socketFd_ = -1;
    bool tls_ = false;
    bool websocket_ = false;
    bool open_ = false;
    void* sslContext_ = nullptr;
    void* ssl_ = nullptr;
    std::shared_ptr<std::atomic_bool> cancelled_;
    uint64_t networkGeneration_ = 0;
#if defined(RDP_TESTS_ONLY)
    std::function<void()> afterConnectRestoreForTesting_;
#endif
    std::mutex writeMutex_;
    std::vector<uint8_t> websocketIncoming_;
    size_t websocketIncomingOffset_ = 0;
};

#endif // VNC_TRANSPORT_H
