/** Native VNC certificate probe error-category tests. */
#include "test_runner.h"
#include "common/network_generation_fence.h"
#include "vnc/vnc_certificate_probe.h"
#include "vnc/vnc_rfb_engine.h"
#include "vnc/vnc_rfb_protocol.h"
#include "vnc/vnc_transport.h"

#include <arpa/inet.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <memory>
#include <string>
#include <thread>
#include <utility>

namespace {

RDP_TEST_CASE(vnc_rfb_protocol_banner_rejects_unsupported_versions) {
    const std::array<uint8_t, VncRfbProtocol::kProtocolVersionBytes> oldBanner =
        {'R', 'F', 'B', ' ', '0', '0', '3', '.', '0', '0', '2', '\n'};
    const std::array<uint8_t, VncRfbProtocol::kProtocolVersionBytes> supportedBanner =
        {'R', 'F', 'B', ' ', '0', '0', '3', '.', '0', '0', '8', '\n'};
    RDP_ASSERT(!VncRfbProtocol::protocolBannerIsSupported(oldBanner.data(), oldBanner.size()));
    RDP_ASSERT(VncRfbProtocol::protocolBannerIsSupported(
        supportedBanner.data(), supportedBanner.size()));
}

class ScopedEnvironment final {
public:
    ScopedEnvironment(const char* name, const std::string& value)
        : name_(name == nullptr ? "" : name) {
        const char* previous = name_.empty() ? nullptr : std::getenv(name_.c_str());
        if (previous != nullptr) {
            previous_ = previous;
            hadPrevious_ = true;
        }
        if (!name_.empty()) {
            active_ = ::setenv(name_.c_str(), value.c_str(), 1) == 0;
        }
    }

    ~ScopedEnvironment() {
        if (name_.empty()) return;
        if (hadPrevious_) {
            (void)::setenv(name_.c_str(), previous_.c_str(), 1);
        } else {
            (void)::unsetenv(name_.c_str());
        }
    }

    bool active() const { return active_; }

private:
    std::string name_;
    std::string previous_;
    bool hadPrevious_ = false;
    bool active_ = false;
};

class LocalTlsFixture final {
public:
    explicit LocalTlsFixture(std::string commonName = "localhost", int holdHandshakeMs = 0,
                             bool ipv6 = false, bool expired = false,
                             bool noCertificate = false, bool trustedRoot = false,
                             int protocolVersion = 0)
        : commonName_(std::move(commonName)), holdHandshakeMs_(holdHandshakeMs),
          ipv6_(ipv6), expired_(expired), noCertificate_(noCertificate),
          trustedRoot_(trustedRoot), protocolVersion_(protocolVersion) {}

    ~LocalTlsFixture() { stop(); }

    bool start() {
        (void)std::signal(SIGPIPE, SIG_IGN);
        context_ = SSL_CTX_new(TLS_server_method());
        const int minimumVersion = protocolVersion_ == 0 ? TLS1_2_VERSION : protocolVersion_;
        if (context_ == nullptr || SSL_CTX_set_min_proto_version(context_, minimumVersion) != 1) {
            return false;
        }
        if (protocolVersion_ != 0) {
            (void)SSL_CTX_set_max_proto_version(context_, protocolVersion_);
            (void)SSL_CTX_set_security_level(context_, 0);
            (void)SSL_CTX_set_cipher_list(context_, "DEFAULT:@SECLEVEL=0");
        }
        if (noCertificate_) {
            // OpenSSL will reject the handshake before a peer certificate is
            // available. This fixture keeps the no-certificate path explicit
            // without weakening the production probe's cipher policy.
            (void)SSL_CTX_set_cipher_list(context_, "aNULL:@SECLEVEL=0");
            (void)SSL_CTX_set_max_proto_version(context_, TLS1_2_VERSION);
        }
        EVP_PKEY_CTX* keyContext = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
        if (!noCertificate_ && (keyContext == nullptr || EVP_PKEY_keygen_init(keyContext) != 1 ||
            EVP_PKEY_CTX_set_rsa_keygen_bits(keyContext, 2048) != 1 ||
            EVP_PKEY_keygen(keyContext, &privateKey_) != 1)) {
            if (keyContext != nullptr) EVP_PKEY_CTX_free(keyContext);
            return false;
        }
        if (keyContext != nullptr) EVP_PKEY_CTX_free(keyContext);
        if (noCertificate_) {
            certificate_ = nullptr;
        } else {
            if (trustedRoot_ && !createTrustedRoot()) {
                return false;
            }
            certificate_ = X509_new();
        }
        if (!noCertificate_ && (certificate_ == nullptr || X509_set_version(certificate_, 2) != 1 ||
            ASN1_INTEGER_set(X509_get_serialNumber(certificate_), 1) != 1 ||
            X509_gmtime_adj(X509_get_notBefore(certificate_), expired_ ? -7200 : -60) == nullptr ||
            X509_gmtime_adj(X509_get_notAfter(certificate_), expired_ ? -3600 : 3600) == nullptr ||
            X509_set_pubkey(certificate_, privateKey_) != 1)) {
            return false;
        }
        X509_NAME* name = noCertificate_ ? nullptr : X509_get_subject_name(certificate_);
        if (!noCertificate_ && (name == nullptr ||
            X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
            reinterpret_cast<const unsigned char*>(commonName_.c_str()),
                                       -1, -1, 0) != 1 ||
            X509_set_issuer_name(certificate_, trustedRoot_ ?
                                 X509_get_subject_name(caCertificate_) : name) != 1 ||
            X509_sign(certificate_, trustedRoot_ ? caPrivateKey_ : privateKey_, EVP_sha256()) <= 0 ||
            SSL_CTX_use_certificate(context_, certificate_) != 1 ||
            SSL_CTX_use_PrivateKey(context_, privateKey_) != 1)) {
            return false;
        }
        if (trustedRoot_ && !writeTrustedRootFile()) {
            return false;
        }
        SSL_CTX_set_tlsext_servername_callback(context_, &LocalTlsFixture::onServerName);
        SSL_CTX_set_tlsext_servername_arg(context_, this);

        const int family = ipv6_ ? AF_INET6 : AF_INET;
        listenFd_ = ::socket(family, SOCK_STREAM, 0);
        if (listenFd_ < 0) return false;
        const int reuse = 1;
        (void)::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        sockaddr_storage storage {};
        socklen_t storageLength = 0;
        if (ipv6_) {
            auto* address = reinterpret_cast<sockaddr_in6*>(&storage);
            address->sin6_family = AF_INET6;
            address->sin6_addr = in6addr_loopback;
            address->sin6_port = htons(0);
            storageLength = sizeof(sockaddr_in6);
        } else {
            auto* address = reinterpret_cast<sockaddr_in*>(&storage);
            address->sin_family = AF_INET;
            address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            address->sin_port = htons(0);
            storageLength = sizeof(sockaddr_in);
        }
        if (::bind(listenFd_, reinterpret_cast<const sockaddr*>(&storage), storageLength) != 0 ||
            ::listen(listenFd_, 8) != 0) {
            return false;
        }
        if (::getsockname(listenFd_, reinterpret_cast<sockaddr*>(&storage), &storageLength) != 0) {
            return false;
        }
        port_ = ipv6_ ? ntohs(reinterpret_cast<sockaddr_in6*>(&storage)->sin6_port) :
            ntohs(reinterpret_cast<sockaddr_in*>(&storage)->sin_port);
        if (certificate_ != nullptr) {
            unsigned char digest[EVP_MAX_MD_SIZE] = {0};
            unsigned int digestSize = 0;
            if (X509_digest(certificate_, EVP_sha256(), digest, &digestSize) != 1 || digestSize != 32) {
                return false;
            }
            static constexpr char kHex[] = "0123456789abcdef";
            for (unsigned int index = 0; index < digestSize; ++index) {
                fingerprint_.push_back(kHex[(digest[index] >> 4) & 0x0f]);
                fingerprint_.push_back(kHex[digest[index] & 0x0f]);
            }
        }
        stopRequested_.store(false, std::memory_order_release);
        worker_ = std::thread(&LocalTlsFixture::acceptLoop, this);
        return true;
    }

    void stop() {
        stopRequested_.store(true, std::memory_order_release);
        const int fd = listenFd_.exchange(-1, std::memory_order_acq_rel);
        if (fd >= 0) {
            (void)::shutdown(fd, SHUT_RDWR);
            (void)::close(fd);
        }
        if (worker_.joinable()) worker_.join();
        if (certificate_ != nullptr) {
            X509_free(certificate_);
            certificate_ = nullptr;
        }
        if (privateKey_ != nullptr) {
            EVP_PKEY_free(privateKey_);
            privateKey_ = nullptr;
        }
        if (context_ != nullptr) {
            SSL_CTX_free(context_);
            context_ = nullptr;
        }
        if (caCertificate_ != nullptr) {
            X509_free(caCertificate_);
            caCertificate_ = nullptr;
        }
        if (caPrivateKey_ != nullptr) {
            EVP_PKEY_free(caPrivateKey_);
            caPrivateKey_ = nullptr;
        }
        if (!trustStorePath_.empty()) {
            (void)::unlink(trustStorePath_.c_str());
            trustStorePath_.clear();
        }
    }

    int port() const { return port_; }
    const std::string& fingerprint() const { return fingerprint_; }
    const std::string& trustStorePath() const { return trustStorePath_; }
    bool sawServerName() const { return sawServerName_.load(std::memory_order_acquire); }

private:
    bool createTrustedRoot() {
        EVP_PKEY_CTX* keyContext = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
        if (keyContext == nullptr || EVP_PKEY_keygen_init(keyContext) != 1 ||
            EVP_PKEY_CTX_set_rsa_keygen_bits(keyContext, 2048) != 1 ||
            EVP_PKEY_keygen(keyContext, &caPrivateKey_) != 1) {
            if (keyContext != nullptr) EVP_PKEY_CTX_free(keyContext);
            return false;
        }
        EVP_PKEY_CTX_free(keyContext);
        caCertificate_ = X509_new();
        if (caCertificate_ == nullptr || X509_set_version(caCertificate_, 2) != 1 ||
            ASN1_INTEGER_set(X509_get_serialNumber(caCertificate_), 100) != 1 ||
            X509_gmtime_adj(X509_get_notBefore(caCertificate_), -60) == nullptr ||
            X509_gmtime_adj(X509_get_notAfter(caCertificate_), 3600) == nullptr ||
            X509_set_pubkey(caCertificate_, caPrivateKey_) != 1) {
            return false;
        }
        X509_NAME* name = X509_get_subject_name(caCertificate_);
        if (name == nullptr ||
            X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                       reinterpret_cast<const unsigned char*>("VNC Test Root"),
                                       -1, -1, 0) != 1 ||
            X509_set_issuer_name(caCertificate_, name) != 1) {
            return false;
        }
        X509V3_CTX extensionContext;
        X509V3_set_ctx_nodb(&extensionContext);
        X509V3_set_ctx(&extensionContext, caCertificate_, caCertificate_, nullptr, nullptr, 0);
        X509_EXTENSION* basicConstraints = X509V3_EXT_conf_nid(
            nullptr, &extensionContext, NID_basic_constraints,
            const_cast<char*>("critical,CA:TRUE,pathlen:1"));
        X509_EXTENSION* keyUsage = X509V3_EXT_conf_nid(
            nullptr, &extensionContext, NID_key_usage,
            const_cast<char*>("critical,keyCertSign,cRLSign"));
        const bool extensionsOk = basicConstraints != nullptr && keyUsage != nullptr &&
            X509_add_ext(caCertificate_, basicConstraints, -1) == 1 &&
            X509_add_ext(caCertificate_, keyUsage, -1) == 1;
        if (basicConstraints != nullptr) X509_EXTENSION_free(basicConstraints);
        if (keyUsage != nullptr) X509_EXTENSION_free(keyUsage);
        return extensionsOk && X509_sign(caCertificate_, caPrivateKey_, EVP_sha256()) > 0;
    }

    bool writeTrustedRootFile() {
        char path[] = "/tmp/vnc-test-root-XXXXXX";
        const int fd = ::mkstemp(path);
        if (fd < 0) return false;
        FILE* file = ::fdopen(fd, "w");
        if (file == nullptr) {
            (void)::close(fd);
            (void)::unlink(path);
            return false;
        }
        const bool written = PEM_write_X509(file, caCertificate_) == 1;
        (void)::fclose(file);
        if (!written) {
            (void)::unlink(path);
            return false;
        }
        trustStorePath_ = path;
        return true;
    }

    static int onServerName(SSL* ssl, int* /*alert*/, void* arg) {
        auto* fixture = static_cast<LocalTlsFixture*>(arg);
        const char* serverName = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
        if (fixture != nullptr && serverName != nullptr && fixture->commonName_ == serverName) {
            fixture->sawServerName_.store(true, std::memory_order_release);
        }
        return SSL_TLSEXT_ERR_OK;
    }

    void acceptLoop() {
        while (!stopRequested_.load(std::memory_order_acquire)) {
            const int fd = listenFd_.load(std::memory_order_acquire);
            if (fd < 0) break;
            pollfd descriptor {fd, POLLIN, 0};
            if (::poll(&descriptor, 1, 50) <= 0) continue;
            const int client = ::accept(fd, nullptr, nullptr);
            if (client < 0) continue;
            if (holdHandshakeMs_ > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(holdHandshakeMs_));
                (void)::shutdown(client, SHUT_RDWR);
                (void)::close(client);
                continue;
            }
            SSL* ssl = SSL_new(context_);
            if (ssl != nullptr && SSL_set_fd(ssl, client) == 1) {
                (void)SSL_accept(ssl);
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                (void)SSL_shutdown(ssl);
            }
            if (ssl != nullptr) SSL_free(ssl);
            (void)::shutdown(client, SHUT_RDWR);
            (void)::close(client);
        }
    }

    std::string commonName_;
    int holdHandshakeMs_ = 0;
    bool ipv6_ = false;
    bool expired_ = false;
    bool noCertificate_ = false;
    bool trustedRoot_ = false;
    int protocolVersion_ = 0;
    SSL_CTX* context_ = nullptr;
    X509* certificate_ = nullptr;
    EVP_PKEY* privateKey_ = nullptr;
    X509* caCertificate_ = nullptr;
    EVP_PKEY* caPrivateKey_ = nullptr;
    std::atomic<int> listenFd_ {-1};
    std::atomic<bool> stopRequested_ {true};
    std::thread worker_;
    int port_ = 0;
    std::string fingerprint_;
    std::string trustStorePath_;
    std::atomic<bool> sawServerName_ {false};
};

/** A byte-level UltraVNC mode12 peer used only for bounded handoff tests. */
class LocalRepeaterFixture final {
public:
    explicit LocalRepeaterFixture(bool validBanner = true) : validBanner_(validBanner) {}
    ~LocalRepeaterFixture() { stop(); }

    bool start() {
        (void)::signal(SIGPIPE, SIG_IGN);
        listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd_ < 0) return false;
        const int reuse = 1;
        (void)::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(0);
        if (::bind(listenFd_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
            ::listen(listenFd_, 1) != 0) return false;
        socklen_t length = sizeof(address);
        if (::getsockname(listenFd_, reinterpret_cast<sockaddr*>(&address), &length) != 0) return false;
        port_ = ntohs(address.sin_port);
        stopRequested_.store(false, std::memory_order_release);
        worker_ = std::thread(&LocalRepeaterFixture::serve, this);
        return true;
    }

    void stop() {
        stopRequested_.store(true, std::memory_order_release);
        const int client = clientFd_.exchange(-1, std::memory_order_acq_rel);
        if (client >= 0) {
            (void)::shutdown(client, SHUT_RDWR);
            (void)::close(client);
        }
        const int listener = std::exchange(listenFd_, -1);
        if (listener >= 0) {
            (void)::shutdown(listener, SHUT_RDWR);
            (void)::close(listener);
        }
        if (worker_.joinable()) worker_.join();
    }

    int port() const { return port_; }
    bool pairingReceived() const { return pairingReceived_.load(std::memory_order_acquire); }
    size_t pairingBytesReceived() const { return pairingBytesReceived_.load(std::memory_order_acquire); }
    size_t pairingReadChunks() const { return pairingReadChunks_.load(std::memory_order_acquire); }
    const std::array<uint8_t, 250>& pairing() const { return pairing_; }

private:
    static bool sendChunks(int fd, const uint8_t* data, size_t size) {
        size_t offset = 0;
        while (offset < size) {
            const size_t chunk = std::min<size_t>(3, size - offset);
            const ssize_t written = ::send(fd, data + offset, chunk, MSG_NOSIGNAL);
            if (written <= 0) return false;
            offset += static_cast<size_t>(written);
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        return true;
    }

    bool recvExactSlow(int fd, uint8_t* data, size_t size) {
        size_t offset = 0;
        while (offset < size) {
            const ssize_t received = ::recv(fd, data + offset, std::min<size_t>(7, size - offset), 0);
            if (received <= 0) return false;
            offset += static_cast<size_t>(received);
            pairingBytesReceived_.fetch_add(static_cast<size_t>(received), std::memory_order_acq_rel);
            pairingReadChunks_.fetch_add(1, std::memory_order_acq_rel);
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }

    void serve() {
        const int listener = listenFd_;
        pollfd descriptor {listener, POLLIN, 0};
        while (!stopRequested_.load(std::memory_order_acquire) && ::poll(&descriptor, 1, 50) > 0) {
            const int client = ::accept(listener, nullptr, nullptr);
            if (client < 0) return;
            clientFd_.store(client, std::memory_order_release);
            static constexpr char valid[] = "RFB 000.000\n";
            static constexpr char invalid[] = "RFB 003.008\n";
            const char* banner = validBanner_ ? valid : invalid;
            if (!sendChunks(client, reinterpret_cast<const uint8_t*>(banner), 12)) return;
            if (!recvExactSlow(client, pairing_.data(), pairing_.size())) return;
            pairingReceived_.store(true, std::memory_order_release);
            static constexpr char rfb[] = "RFB 003.008\n";
            (void)sendChunks(client, reinterpret_cast<const uint8_t*>(rfb), 12);
            while (!stopRequested_.load(std::memory_order_acquire)) {
                pollfd clientDescriptor {client, POLLIN, 0};
                if (::poll(&clientDescriptor, 1, 50) < 0) break;
                if ((clientDescriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) break;
            }
            return;
        }
    }

    bool validBanner_ = true;
    std::atomic<bool> stopRequested_ {false};
    std::atomic<int> clientFd_ {-1};
    std::atomic<bool> pairingReceived_ {false};
    std::atomic<size_t> pairingBytesReceived_ {0};
    std::atomic<size_t> pairingReadChunks_ {0};
    std::array<uint8_t, 250> pairing_ {};
    int listenFd_ = -1;
    int port_ = 0;
    std::thread worker_;
};

} // namespace

RDP_TEST_CASE(vnc_certificate_probe_error_categories_are_stable) {
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::ConnectTimeout)) == "connect_timeout");
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::TlsHandshakeFailed)) == "tls_handshake_failed");
    RDP_ASSERT(vncCertificateProbeErrorCategory(9999) == "unknown");
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::CertificateChainTooDeep)) ==
        "certificate_chain_too_deep");
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::ResolveTimeout)) == "resolve_timeout");
    RDP_ASSERT(vncCertificateProbeErrorMessage(
        static_cast<int>(VncCertificateProbeErrorCode::Cancelled)).find("E-VNC-CERT-CANCELLED")
        != std::string::npos);
    const std::string redacted = vncRedactCertificateMessageForLog(
        "E-VNC-CERT-TRUST-REQUIRED;VNC_TRUST_REQUIRED:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    RDP_ASSERT(redacted.find("<fingerprint-redacted>") != std::string::npos);
    RDP_ASSERT(redacted.find("0123456789abcdef0123456789abcdef") == std::string::npos);
    const std::string changedRedacted = vncRedactCertificateMessageForLog(
        "E-VNC-CERT-CHANGED;VNC_CERT_CHANGED:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");
    RDP_ASSERT(changedRedacted.find("<fingerprint-redacted>") != std::string::npos);
    RDP_ASSERT(changedRedacted.find("fedcba9876543210fedcba9876543210") == std::string::npos);
}

RDP_TEST_CASE(vnc_certificate_probe_local_tls_fixture_reports_metadata_and_sni) {
    LocalTlsFixture fixture;
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = "localhost";
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.fingerprintSha256 == fixture.fingerprint());
    RDP_ASSERT(vncCertificateFingerprintIsCanonical(result.fingerprintSha256));
    RDP_ASSERT(result.commonName == "localhost");
    RDP_ASSERT(!result.subject.empty());
    RDP_ASSERT(!result.issuer.empty());
    RDP_ASSERT(result.notAfterMs > result.notBeforeMs);
    RDP_ASSERT(!result.hostMismatch);
    RDP_ASSERT(result.tlsVersion == "TLS1.2" || result.tlsVersion == "TLS1.3");
    RDP_ASSERT(fixture.sawServerName());
}

RDP_TEST_CASE(vnc_certificate_probe_reports_name_mismatch_without_trusting_the_name) {
    LocalTlsFixture fixture("localhost");
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = "different.local";
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.hostMismatch);
}

RDP_TEST_CASE(vnc_certificate_probe_bounds_large_certificate_names) {
    LocalTlsFixture fixture(std::string(63, 'x'));
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = std::string(63, 'x');
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.commonName.size() <= 256);
    RDP_ASSERT(result.subject.size() <= 2048);
    RDP_ASSERT(result.issuer.size() <= 2048);
}

RDP_TEST_CASE(vnc_certificate_probe_reports_a_locally_trusted_root) {
    LocalTlsFixture fixture("trusted.local", 0, false, false, false, true);
    RDP_ASSERT(fixture.start());
    ScopedEnvironment trustStore("SSL_CERT_FILE", fixture.trustStorePath());
    RDP_ASSERT(trustStore.active());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = "trusted.local";
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.rootTrusted);
    RDP_ASSERT(!result.hostMismatch);
}

RDP_TEST_CASE(vnc_certificate_probe_handles_a_server_without_a_peer_certificate) {
    LocalTlsFixture fixture("no-certificate.local", 0, false, false, true);
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = "no-certificate.local";
    config.timeoutMs = 1000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.errorCode == static_cast<int>(VncCertificateProbeErrorCode::NoCertificate));
}

RDP_TEST_CASE(vnc_certificate_probe_rejects_legacy_tls_versions_with_stable_code) {
    for (const int version : {TLS1_VERSION, TLS1_1_VERSION}) {
        LocalTlsFixture fixture("legacy.local", 0, false, false, false, false, version);
        RDP_ASSERT(fixture.start());
        VncCertificateProbeConfig config;
        config.host = "127.0.0.1";
        config.port = fixture.port();
        config.serverName = "legacy.local";
        config.timeoutMs = 2000;
        const VncCertificateInfo result = probeVncCertificate(config);
        RDP_ASSERT(!result.ok);
        RDP_ASSERT(result.errorCode ==
                   static_cast<int>(VncCertificateProbeErrorCode::TlsVersionRejected));
        RDP_ASSERT(result.errorMessage.find("E-VNC-CERT-TLS-VERSION") != std::string::npos);
    }
}

RDP_TEST_CASE(vnc_transport_rejects_legacy_tls_versions_with_stable_code) {
    for (const int version : {TLS1_VERSION, TLS1_1_VERSION}) {
        LocalTlsFixture fixture("legacy.local", 0, false, false, false, false, version);
        RDP_ASSERT(fixture.start());
        VncTransportConfig config;
        config.transport = "direct_tcp";
        config.host = "127.0.0.1";
        config.serverName = "legacy.local";
        config.port = fixture.port();
        config.tls = true;
        config.connectTimeoutMs = 2000;
        VncTransport transport;
        std::string error;
        RDP_ASSERT(!transport.connect(config, error));
        RDP_ASSERT(error == "E-VNC-CERT-TLS-VERSION");
        transport.close();
    }
}

RDP_TEST_CASE(vnc_transport_local_tls_fixture_enforces_pin_and_rotation) {
    LocalTlsFixture fixture;
    RDP_ASSERT(fixture.start());
    VncTransportConfig config;
    config.transport = "direct_tcp";
    config.host = "127.0.0.1";
    config.serverName = "localhost";
    config.port = fixture.port();
    config.tls = true;
    config.connectTimeoutMs = 2000;
    config.expectedCertificateFingerprintSha256 = fixture.fingerprint();
    VncTransport transport;
    std::string error;
    RDP_ASSERT(transport.connect(config, error));
    transport.close();

    config.expectedCertificateFingerprintSha256.clear();
    error.clear();
    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(error.rfind("E-VNC-CERT-TRUST-REQUIRED;VNC_TRUST_REQUIRED:", 0) == 0);
    transport.close();

    LocalTlsFixture rotated;
    RDP_ASSERT(rotated.start());
    config.port = rotated.port();
    config.expectedCertificateFingerprintSha256 = fixture.fingerprint();
    error.clear();
    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(error.rfind("E-VNC-CERT-CHANGED;VNC_CERT_CHANGED:", 0) == 0);
    RDP_ASSERT(error.find(rotated.fingerprint()) != std::string::npos);
    transport.close();
}

RDP_TEST_CASE(vnc_certificate_probe_ipv6_fixture_uses_the_same_sni_contract) {
    LocalTlsFixture fixture("localhost", 0, true);
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "::1";
    config.port = fixture.port();
    config.serverName = "localhost";
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.fingerprintSha256 == fixture.fingerprint());
    RDP_ASSERT(fixture.sawServerName());
}

RDP_TEST_CASE(vnc_certificate_probe_fixture_reports_expired_metadata_without_trusting_it) {
    LocalTlsFixture fixture("expired.local", 0, false, true);
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.serverName = "expired.local";
    config.timeoutMs = 2000;
    const VncCertificateInfo result = probeVncCertificate(config);
    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.notAfterMs <
               std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::system_clock::now().time_since_epoch()).count());
    RDP_ASSERT(!result.rootTrusted);
}

RDP_TEST_CASE(vnc_certificate_probe_tls_timeout_and_cancel_are_bounded) {
    LocalTlsFixture fixture("localhost", 300);
    RDP_ASSERT(fixture.start());
    VncCertificateProbeConfig timeoutConfig;
    timeoutConfig.host = "127.0.0.1";
    timeoutConfig.port = fixture.port();
    timeoutConfig.serverName = "localhost";
    timeoutConfig.timeoutMs = 100;
    const auto started = std::chrono::steady_clock::now();
    const VncCertificateInfo timeoutResult = probeVncCertificate(timeoutConfig);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    RDP_ASSERT(!timeoutResult.ok);
    RDP_ASSERT(timeoutResult.errorCode ==
               static_cast<int>(VncCertificateProbeErrorCode::TlsTimeout));
    RDP_ASSERT(elapsed < 500);

    auto cancelled = std::make_shared<std::atomic_bool>(false);
    timeoutConfig.timeoutMs = 2000;
    timeoutConfig.cancelled = cancelled;
    VncCertificateInfo cancelledResult;
    std::thread worker([&]() { cancelledResult = probeVncCertificate(timeoutConfig); });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    cancelled->store(true, std::memory_order_release);
    worker.join();
    RDP_ASSERT(!cancelledResult.ok);
    RDP_ASSERT(cancelledResult.errorCode ==
               static_cast<int>(VncCertificateProbeErrorCode::Cancelled));
}

RDP_TEST_CASE(vnc_transport_tls_cancel_returns_a_stable_code) {
    LocalTlsFixture fixture("localhost", 500);
    RDP_ASSERT(fixture.start());
    VncTransportConfig config;
    config.transport = "direct_tcp";
    config.host = "127.0.0.1";
    config.serverName = "localhost";
    config.port = fixture.port();
    config.tls = true;
    config.connectTimeoutMs = 2000;
    config.cancelled = std::make_shared<std::atomic_bool>(false);
    VncTransport transport;
    std::string error;
    bool connected = true;
    std::thread worker([&]() { connected = transport.connect(config, error); });
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    config.cancelled->store(true, std::memory_order_release);
    worker.join();
    RDP_ASSERT(!connected);
    RDP_ASSERT(error == "E-VNC-CERT-CANCELLED");
    transport.close();
}

RDP_TEST_CASE(vnc_transport_tls_handshake_observes_network_generation) {
    LocalTlsFixture fixture("localhost", 500);
    RDP_ASSERT(fixture.start());
    remotedesk::net::NetworkGenerationFence& fence =
        remotedesk::net::ProcessNetworkGenerationFence();
    const remotedesk::net::NetworkGenerationSnapshot captured =
        fence.snapshot();

    VncTransportConfig config;
    config.transport = "direct_tcp";
    config.host = "127.0.0.1";
    config.serverName = "localhost";
    config.port = fixture.port();
    config.tls = true;
    config.connectTimeoutMs = 2000;
    config.networkGeneration = captured.generation;
    VncTransport transport;
    std::string error;
    bool connected = true;
    std::thread worker([&]() { connected = transport.connect(config, error); });
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    RDP_ASSERT(fence.update(true, captured.generation + 1));
    worker.join();

    RDP_ASSERT(!connected);
    RDP_ASSERT(error == "E-VNC-CERT-CANCELLED");
    transport.close();
}

RDP_TEST_CASE(vnc_transport_tls_deadline_covers_a_trickle_handshake) {
    // The peer accepts TCP but withholds the next TLS record. The transport
    // must spend the single connect budget across TCP and every handshake
    // wait, rather than restarting a full timeout after each WANT_READ.
    LocalTlsFixture fixture("localhost", 400);
    RDP_ASSERT(fixture.start());
    VncTransportConfig config;
    config.transport = "direct_tcp";
    config.host = "127.0.0.1";
    config.serverName = "localhost";
    config.port = fixture.port();
    config.tls = true;
    config.connectTimeoutMs = 120;
    VncTransport transport;
    std::string error;
    const auto started = std::chrono::steady_clock::now();
    RDP_ASSERT(!transport.connect(config, error));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    RDP_ASSERT(error == "E-VNC-CERT-TLS-TIMEOUT");
    RDP_ASSERT(elapsed < 350);
    transport.close();
}

RDP_TEST_CASE(vnc_repeater_transport_deep_handoff_reads_banner_and_exact_pairing) {
    LocalRepeaterFixture fixture;
    RDP_ASSERT(fixture.start());
    VncTransportConfig config;
    config.transport = "ultravnc_repeater";
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.repeaterMode = "mode12";
    config.repeaterTarget = "office-1";
    config.connectTimeoutMs = 2000;
    VncTransport transport;
    std::string error;
    RDP_ASSERT(transport.connect(config, error));
    std::array<uint8_t, VncRfbProtocol::kProtocolVersionBytes> rfbBanner {};
    RDP_ASSERT(transport.readExact(rfbBanner.data(), rfbBanner.size(), 1000, error));
    RDP_ASSERT(std::memcmp(rfbBanner.data(), "RFB 003.008\n", rfbBanner.size()) == 0);
    transport.close();
    RDP_ASSERT(fixture.pairingReceived());
    RDP_ASSERT(fixture.pairingReadChunks() > 1);
    std::string target;
    RDP_ASSERT(VncRfbProtocol::parseRepeaterTargetField(
        fixture.pairing().data(), fixture.pairing().size(), target, error));
    RDP_ASSERT(target == "office-1");
}

RDP_TEST_CASE(vnc_repeater_transport_rejects_invalid_banner_before_pairing) {
    LocalRepeaterFixture fixture(false);
    RDP_ASSERT(fixture.start());
    VncTransportConfig config;
    config.transport = "ultravnc_repeater";
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.repeaterMode = "mode12";
    config.repeaterTarget = "office-1";
    config.connectTimeoutMs = 1000;
    VncTransport transport;
    std::string error;
    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(error.find("banner is invalid") != std::string::npos);
    transport.close();
    RDP_ASSERT(!fixture.pairingReceived());
    RDP_ASSERT(fixture.pairingBytesReceived() == 0);
    RDP_ASSERT(fixture.pairingReadChunks() == 0);
}

RDP_TEST_CASE(vnc_rfb_engine_stop_during_tls_keeps_ssl_teardown_on_worker) {
    LocalTlsFixture fixture("localhost", 500);
    RDP_ASSERT(fixture.start());
    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = fixture.port();
    config.vncTransport = "direct_tcp";
    config.vncServerName = "localhost";
    config.vncTls = true;
    config.vncSecurityPolicy = "secure_only";
    config.vncConnectTimeoutMs = 2000;
    config.vncExpectedCertificateFingerprintSha256 = fixture.fingerprint();
    auto engine = std::make_shared<VncRfbEngine>(
        config,
        [](const VideoFrame&) {},
        [](ConnectionState, const std::string&) {},
        [](const VncCursorProtocol::DecodedCursor&) {});
    RDP_ASSERT(engine->start() == 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    const auto started = std::chrono::steady_clock::now();
    RDP_ASSERT(engine->stopWithin(std::chrono::milliseconds(500)));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    RDP_ASSERT(elapsed < 700);
    RDP_ASSERT(engine->state() == ConnectionState::DISCONNECTED);
}

RDP_TEST_CASE(vnc_certificate_probe_dns_resolution_is_bounded) {
    VncCertificateProbeConfig config;
    config.host = "vnc-probe-resolution-timeout.invalid";
    config.port = 5900;
    config.timeoutMs = 100;
    const auto started = std::chrono::steady_clock::now();
    const VncCertificateInfo result = probeVncCertificate(config);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.errorCode == static_cast<int>(VncCertificateProbeErrorCode::ResolveFailed) ||
               result.errorCode == static_cast<int>(VncCertificateProbeErrorCode::ResolveTimeout));
    RDP_ASSERT(elapsed < 1000);
}
