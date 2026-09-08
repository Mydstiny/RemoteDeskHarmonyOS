#include "ai_tls.h"
#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <climits>
#include <csignal>
#include <pthread.h>
#include <memory>
#include <stdexcept>
#include <algorithm>

namespace RemoteAi {
namespace {
[[noreturn]] void fail(const char* code) { throw std::runtime_error(code); }
void need(bool valid, const char* code) { if (!valid) fail(code); }
template<class T, auto Free> using Owned = std::unique_ptr<T, decltype(Free)>;
using Clock = std::chrono::steady_clock;
size_t number(const std::string& text, unsigned base, size_t max) {
    need(!text.empty() && text.size() <= 16, "AI_HTTP_LENGTH_INVALID");
    size_t value = 0;
    for (unsigned char c : text) {
        unsigned digit = c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
        need(digit < base && value <= (max - std::min<size_t>(max, digit)) / base && digit <= max,
            "AI_HTTP_LENGTH_INVALID");
        value = value * base + digit;
    }
    return value;
}
std::string trim(std::string text) {
    while (!text.empty() && (text.front() == ' ' || text.front() == '\t')) text.erase(0, 1);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\t')) text.pop_back();
    return text;
}
std::string lower(std::string text) {
    for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}
std::string bioString(BIO* bio) {
    char* p = nullptr;
    long length = BIO_get_mem_data(bio, &p);
    need(length > 0 && length < 65536, "AI_IDENTITY_ENCODING_FAILED");
    return std::string(p, static_cast<size_t>(length));
}
void check(Cancellation& cancel, Clock::time_point deadline) {
    need(!cancel.stopped(), "AI_REQUEST_CANCELLED");
    need(Clock::now() < deadline, "AI_REQUEST_TIMEOUT_RECONCILE");
}
void waitSocket(int fd, short event, Cancellation& cancel, Clock::time_point deadline) {
    while (true) {
        check(cancel, deadline);
        pollfd item{fd, event, 0};
        int result = poll(&item, 1, 100);
        if (result > 0) {
            need(!(item.revents & POLLNVAL), "AI_CONNECTION_CLOSED");
            return; // SSL/read reports precise EOF/error after HUP.
        }
        need(result == 0 || errno == EINTR, "AI_CONNECTION_LOST_RECONCILE");
    }
}
struct Socket {
    int fd = -1;
    Cancellation& cancel;
    explicit Socket(Cancellation& c): cancel(c) {}
    ~Socket() { cancel.detach(); if (fd >= 0) close(fd); }
};
bool addressValid(const std::string& value) {
    return !value.empty() && value.size() <= 253 && std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isalnum(c) || c == '.' || c == '-' || c == '_' || c == ':' || c == '%';
    });
}
bool peerNameValid(const std::string& value) {
    if (!addressValid(value)) return false;
    std::string host = value;
    const auto zone = host.find('%');
    if (zone != std::string::npos) {
        if (zone + 1 == host.size() || host.find('%', zone + 1) != std::string::npos) return false;
        host.erase(zone);
    }
    unsigned char ip[16];
    if (inet_pton(AF_INET6, host.c_str(), ip) == 1) return true;
    if (zone != std::string::npos) return false;
    if (inet_pton(AF_INET, host.c_str(), ip) == 1) return true;
    size_t from = 0;
    while (from < host.size()) {
        auto end = host.find('.', from);
        if (end == std::string::npos) end = host.size();
        const auto length = end - from;
        if (length == 0 || length > 63 || !std::isalnum(static_cast<unsigned char>(host[from])) ||
            !std::isalnum(static_cast<unsigned char>(host[end - 1]))) return false;
        for (size_t i = from; i < end; ++i)
            if (!std::isalnum(static_cast<unsigned char>(host[i])) && host[i] != '-') return false;
        if (end == host.size()) return true;
        from = end + 1;
    }
    return false;
}
void validate(const Request& cfg) {
    need(addressValid(cfg.address) && peerNameValid(cfg.serverName) && cfg.port > 0 && cfg.port <= 65535,
        "AI_ENDPOINT_INVALID");
    need(cfg.timeoutMs >= 100 && cfg.timeoutMs <= 60000 && cfg.ca.size() <= 65536 &&
        cfg.certificate.size() <= 65536 && cfg.privateKey.size() <= 16384 && cfg.body.size() <= 800000,
        "AI_REQUEST_INVALID");
    bool eventPath = cfg.path.rfind("/v1/events?cursor=", 0) == 0 && cfg.path.size() <= 500 &&
        std::all_of(cfg.path.begin(), cfg.path.end(), [](unsigned char c) {
            return std::isalnum(c) || c == '/' || c == '?' || c == '=' || c == '&' || c == '_' || c == '-' || c == '%';
        });
    need((cfg.stream && eventPath && cfg.body.empty()) ||
        (!cfg.stream && (cfg.path == "/v1/rpc" || cfg.path == "/v1/pair")), "AI_REQUEST_PATH_INVALID");
    need(cfg.path == "/v1/pair" || (!cfg.certificate.empty() && !cfg.privateKey.empty()), "AI_IDENTITY_REQUIRED");
}
}
Request::~Request() { if (!privateKey.empty()) OPENSSL_cleanse(privateKey.data(), privateKey.size()); }
void Cancellation::cancel() {
    cancelled_.store(true);
    std::lock_guard<std::mutex> lock(mutex_);
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
}
bool Cancellation::attach(int fd) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (cancelled_.load()) return false;
    fd_ = fd;
    return true;
}
void Cancellation::detach() { std::lock_guard<std::mutex> lock(mutex_); fd_ = -1; }
Identity generateIdentity(Cancellation& cancellation) {
    Owned<EVP_PKEY_CTX, EVP_PKEY_CTX_free> ctx(EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr), EVP_PKEY_CTX_free);
    need(ctx && EVP_PKEY_keygen_init(ctx.get()) > 0 && EVP_PKEY_CTX_set_rsa_keygen_bits(ctx.get(), 3072) > 0,
        "AI_IDENTITY_GENERATION_FAILED");
    const auto keyDeadline = Clock::now() + std::chrono::seconds(10);
    struct KeyProgress { Cancellation* cancellation; Clock::time_point deadline; } progress{&cancellation, keyDeadline};
    EVP_PKEY_CTX_set_app_data(ctx.get(), &progress);
    EVP_PKEY_CTX_set_cb(ctx.get(), [](EVP_PKEY_CTX* context) {
        auto* progress = static_cast<KeyProgress*>(EVP_PKEY_CTX_get_app_data(context));
        return !progress->cancellation->stopped() && Clock::now() < progress->deadline ? 1 : 0;
    });
    EVP_PKEY* raw = nullptr;
    need(EVP_PKEY_keygen(ctx.get(), &raw) > 0, "AI_IDENTITY_GENERATION_FAILED");
    Owned<EVP_PKEY, EVP_PKEY_free> key(raw, EVP_PKEY_free);
    Owned<X509_REQ, X509_REQ_free> csr(X509_REQ_new(), X509_REQ_free);
    need(csr && X509_REQ_set_version(csr.get(), 0) == 1 && X509_REQ_set_pubkey(csr.get(), key.get()) == 1,
        "AI_IDENTITY_GENERATION_FAILED");
    const unsigned char name[] = "RemoteDesk HarmonyOS";
    need(X509_NAME_add_entry_by_txt(X509_REQ_get_subject_name(csr.get()), "CN", MBSTRING_ASC,
        name, -1, -1, 0) == 1 && X509_REQ_sign(csr.get(), key.get(), EVP_sha256()) > 0,
        "AI_IDENTITY_GENERATION_FAILED");
    Owned<BIO, BIO_free> keyBio(BIO_new(BIO_s_mem()), BIO_free), csrBio(BIO_new(BIO_s_mem()), BIO_free);
    need(keyBio && csrBio && PEM_write_bio_PrivateKey(keyBio.get(), key.get(), nullptr, nullptr, 0, nullptr, nullptr) == 1 &&
        PEM_write_bio_X509_REQ(csrBio.get(), csr.get()) == 1, "AI_IDENTITY_ENCODING_FAILED");
    return {bioString(keyBio.get()), bioString(csrBio.get())};
}
HttpBody::HttpBody(Chunk chunk, size_t limit): chunk_(std::move(chunk)), limit_(limit) {}
void HttpBody::headers() {
    const size_t end = buffer_.find("\r\n\r\n");
    if (end == std::string::npos) { need(buffer_.size() <= 16384, "AI_HTTP_HEADERS_TOO_LARGE"); return; }
    need(end <= 16384, "AI_HTTP_HEADERS_TOO_LARGE");
    size_t lineEnd = buffer_.find("\r\n");
    const std::string first = buffer_.substr(0, lineEnd);
    need(first.rfind("HTTP/1.1 ", 0) == 0 && first.size() >= 12 &&
        (first.size() == 12 || first[12] == ' '), "AI_HTTP_STATUS_INVALID");
    status_ = static_cast<int>(number(first.substr(9, 3), 10, 599));
    need(status_ >= 200, "AI_HTTP_STATUS_INVALID");
    bool hasEncoding = false;
    size_t offset = lineEnd + 2;
    while (offset < end) {
        lineEnd = buffer_.find("\r\n", offset);
        const auto line = buffer_.substr(offset, lineEnd - offset);
        const size_t colon = line.find(':');
        need(colon != std::string::npos && colon > 0 && line.front() != ' ' && line.front() != '\t',
            "AI_HTTP_HEADER_INVALID");
        const std::string name = lower(line.substr(0, colon)), value = lower(trim(line.substr(colon + 1)));
        if (name == "content-length") {
            need(!hasLength_, "AI_HTTP_DUPLICATE_LENGTH");
            remaining_ = number(value, 10, limit_);
            hasLength_ = true;
        } else if (name == "transfer-encoding") {
            need(!hasEncoding && value == "chunked", "AI_HTTP_ENCODING_UNSUPPORTED");
            chunked_ = true; hasEncoding = true;
        } else if (name == "content-encoding") {
            need(value == "identity", "AI_HTTP_ENCODING_UNSUPPORTED");
        }
        offset = lineEnd + 2;
    }
    need(!(chunked_ && hasLength_), "AI_HTTP_AMBIGUOUS_LENGTH");
    buffer_.erase(0, end + 4);
    parsed_ = true;
    if (hasLength_ && remaining_ == 0) done_ = true;
}
void HttpBody::deliver(size_t size) {
    need(size <= limit_ - bytes_, "AI_HTTP_BODY_TOO_LARGE");
    if (size > 0) {
        need(chunk_(buffer_.data(), size), "AI_STREAM_BACKPRESSURE");
        bytes_ += size; buffer_.erase(0, size);
    }
}
void HttpBody::consume() {
    while (!done_ && !buffer_.empty()) {
        if (!chunked_) {
            const size_t size = hasLength_ ? std::min(buffer_.size(), remaining_) : buffer_.size();
            deliver(size);
            if (hasLength_) { remaining_ -= size; done_ = remaining_ == 0; }
            return;
        }
        if (phase_ == Phase::Size) {
            const size_t end = buffer_.find("\r\n");
            if (end == std::string::npos) { need(buffer_.size() <= 128, "AI_HTTP_CHUNK_INVALID"); return; }
            need(end <= 128, "AI_HTTP_CHUNK_INVALID");
            std::string value = buffer_.substr(0, end);
            const size_t extension = value.find(';');
            if (extension != std::string::npos) value.erase(extension);
            remaining_ = number(value, 16, limit_ - bytes_);
            buffer_.erase(0, end + 2);
            phase_ = remaining_ == 0 ? Phase::Trailers : Phase::Data;
        } else if (phase_ == Phase::Data) {
            const size_t size = std::min(remaining_, buffer_.size());
            deliver(size); remaining_ -= size;
            if (remaining_ == 0) phase_ = Phase::End;
        } else if (phase_ == Phase::End) {
            if (buffer_.size() < 2) return;
            need(buffer_.substr(0, 2) == "\r\n", "AI_HTTP_CHUNK_INVALID");
            buffer_.erase(0, 2); phase_ = Phase::Size;
        } else {
            if (buffer_.rfind("\r\n", 0) == 0) { buffer_.erase(0, 2); done_ = true; }
            else {
                const size_t end = buffer_.find("\r\n\r\n");
                need(buffer_.size() <= 16384, "AI_HTTP_TRAILERS_TOO_LARGE");
                if (end == std::string::npos) return;
                buffer_.erase(0, end + 4); done_ = true;
            }
        }
    }
}
void HttpBody::feed(const char* data, size_t size) {
    need(!done_ || size == 0, "AI_HTTP_EXTRA_DATA");
    need(size <= 65536, "AI_HTTP_READ_TOO_LARGE");
    buffer_.append(data, size);
    if (!parsed_) headers();
    if (parsed_) consume();
    if (done_) need(buffer_.empty(), "AI_HTTP_EXTRA_DATA");
}
void HttpBody::finish() {
    need(parsed_ && ((!chunked_ && !hasLength_) || done_), "AI_HTTP_TRUNCATED");
    done_ = true;
}
Response request(const Request& cfg, Cancellation& cancel, const Chunk& chunk) {
    validate(cfg);
    // SSL's socket BIO can write(2); block SIGPIPE only on this owned worker.
#ifndef __APPLE__
    struct SigpipeGuard {
        sigset_t old{}, set{};
        bool restore = false, pending = false;
        SigpipeGuard() {
            sigemptyset(&set); sigaddset(&set, SIGPIPE);
            sigset_t existing{}; sigpending(&existing); pending = sigismember(&existing, SIGPIPE) == 1;
            restore = pthread_sigmask(SIG_BLOCK, &set, &old) == 0;
        }
        ~SigpipeGuard() {
            if (!restore) return;
            if (!pending && sigismember(&old, SIGPIPE) != 1) {
                timespec zero{};
                while (sigtimedwait(&set, nullptr, &zero) >= 0) {}
            }
            pthread_sigmask(SIG_SETMASK, &old, nullptr);
        }
    } sigpipe;
#endif

    auto deadline = Clock::now() + std::chrono::milliseconds(cfg.timeoutMs);
    Owned<SSL_CTX, SSL_CTX_free> ctx(SSL_CTX_new(TLS_client_method()), SSL_CTX_free);
    need(ctx && SSL_CTX_set_min_proto_version(ctx.get(), TLS1_3_VERSION) == 1 &&
        SSL_CTX_set_max_proto_version(ctx.get(), TLS1_3_VERSION) == 1, "AI_TLS_UNAVAILABLE");
    SSL_CTX_set_verify(ctx.get(), SSL_VERIFY_PEER, nullptr);
    // No default paths/store: the out-of-band invite's private CA is the only trust root.
    Owned<BIO, BIO_free> caBio(BIO_new_mem_buf(cfg.ca.data(), static_cast<int>(cfg.ca.size())), BIO_free);
    Owned<X509, X509_free> ca(caBio ? PEM_read_bio_X509(caBio.get(), nullptr, nullptr, nullptr) : nullptr, X509_free);
    need(ca && X509_check_ca(ca.get()) > 0 && X509_STORE_add_cert(SSL_CTX_get_cert_store(ctx.get()), ca.get()) == 1,
        "AI_CA_INVALID");
    if (!cfg.certificate.empty()) {
        Owned<BIO, BIO_free> certBio(BIO_new_mem_buf(cfg.certificate.data(), static_cast<int>(cfg.certificate.size())), BIO_free);
        Owned<BIO, BIO_free> keyBio(BIO_new_mem_buf(cfg.privateKey.data(), static_cast<int>(cfg.privateKey.size())), BIO_free);
        Owned<X509, X509_free> cert(certBio ? PEM_read_bio_X509(certBio.get(), nullptr, nullptr, nullptr) : nullptr, X509_free);
        Owned<EVP_PKEY, EVP_PKEY_free> key(keyBio ? PEM_read_bio_PrivateKey(keyBio.get(), nullptr, nullptr, nullptr) : nullptr, EVP_PKEY_free);
        need(cert && key && SSL_CTX_use_certificate(ctx.get(), cert.get()) == 1 &&
            SSL_CTX_use_PrivateKey(ctx.get(), key.get()) == 1 && SSL_CTX_check_private_key(ctx.get()) == 1,
            "AI_IDENTITY_INVALID");
        Owned<X509_STORE_CTX, X509_STORE_CTX_free> clientCheck(X509_STORE_CTX_new(), X509_STORE_CTX_free);
        need(clientCheck && X509_STORE_CTX_init(clientCheck.get(), SSL_CTX_get_cert_store(ctx.get()), cert.get(), nullptr) == 1 &&
            X509_STORE_CTX_set_purpose(clientCheck.get(), X509_PURPOSE_SSL_CLIENT) == 1 &&
            X509_verify_cert(clientCheck.get()) == 1, "AI_CLIENT_CERTIFICATE_REJECTED");
    }
    addrinfo hints{}; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    addrinfo* resolved = nullptr;
    need(getaddrinfo(cfg.address.c_str(), std::to_string(cfg.port).c_str(), &hints, &resolved) == 0,
        "AI_HOST_NOT_FOUND");
    Owned<addrinfo, freeaddrinfo> addresses(resolved, freeaddrinfo);
    Socket socket(cancel);
    for (addrinfo* item = addresses.get(); item; item = item->ai_next) {
        check(cancel, deadline);
        int fd = ::socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (fd < 0) continue;
#ifdef SO_NOSIGPIPE
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || !cancel.attach(fd)) { close(fd); continue; }
        socket.fd = fd;
        int connected = connect(fd, item->ai_addr, item->ai_addrlen);
        if (connected < 0 && errno == EINPROGRESS) {
            waitSocket(fd, POLLOUT, cancel, deadline);
            int error = 0; socklen_t size = sizeof(error);
            connected = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0 ? 0 : -1;
        }
        if (connected == 0) break;
        cancel.detach(); close(fd); socket.fd = -1;
    }
    need(socket.fd >= 0, "AI_CONNECTION_FAILED");
    Owned<SSL, SSL_free> tls(SSL_new(ctx.get()), SSL_free);
    need(tls && SSL_set_fd(tls.get(), socket.fd) == 1, "AI_TLS_UNAVAILABLE");
    std::string identity = cfg.serverName;
    const size_t zone = identity.find('%');
    if (zone != std::string::npos) identity.erase(zone);
    unsigned char ip[16];
    X509_VERIFY_PARAM* verification = SSL_get0_param(tls.get());
    X509_VERIFY_PARAM_set_hostflags(verification, X509_CHECK_FLAG_NEVER_CHECK_SUBJECT | X509_CHECK_FLAG_NO_WILDCARDS);
    if (inet_pton(AF_INET, identity.c_str(), ip) == 1 || inet_pton(AF_INET6, identity.c_str(), ip) == 1) {
        need(X509_VERIFY_PARAM_set1_ip_asc(verification, identity.c_str()) == 1, "AI_SERVER_IDENTITY_INVALID");
    } else {
        need(identity.find(':') == std::string::npos && SSL_set1_host(tls.get(), identity.c_str()) == 1 &&
            SSL_set_tlsext_host_name(tls.get(), identity.c_str()) == 1, "AI_SERVER_IDENTITY_INVALID");
    }
    const unsigned char alpn[] = {8, 'h','t','t','p','/','1','.','1'};
    need(SSL_set_alpn_protos(tls.get(), alpn, sizeof(alpn)) == 0, "AI_TLS_UNAVAILABLE");
    auto retry = [&](int result, const char* error) {
        check(cancel, deadline);
        const int reason = SSL_get_error(tls.get(), result);
        if (reason == SSL_ERROR_WANT_READ) waitSocket(socket.fd, POLLIN, cancel, deadline);
        else if (reason == SSL_ERROR_WANT_WRITE) waitSocket(socket.fd, POLLOUT, cancel, deadline);
        else fail(error);
    };
    for (;;) {
        check(cancel, deadline); ERR_clear_error();
        const int rc = SSL_connect(tls.get());
        if (rc == 1) break;
        retry(rc, "AI_TLS_IDENTITY_REJECTED");
    }
    need(SSL_get_verify_result(tls.get()) == X509_V_OK && SSL_version(tls.get()) >= TLS1_3_VERSION,
        "AI_TLS_IDENTITY_REJECTED");
    const std::string authority = identity.find(':') == std::string::npos ? identity : "[" + identity + "]";
    std::string wire = (cfg.stream ? "GET " : "POST ") + cfg.path + " HTTP/1.1\r\nHost: " +
        authority + ":" + std::to_string(cfg.port) + "\r\nConnection: close\r\nAccept-Encoding: identity\r\n";
    wire += cfg.stream ? "Accept: text/event-stream\r\n\r\n" :
        "Content-Type: application/json\r\nContent-Length: " + std::to_string(cfg.body.size()) + "\r\n\r\n" + cfg.body;
    size_t sent = 0;
    while (sent < wire.size()) {
        check(cancel, deadline); ERR_clear_error();
        const int rc = SSL_write(tls.get(), wire.data() + sent, static_cast<int>(wire.size() - sent));
        if (rc > 0) sent += static_cast<size_t>(rc);
        else retry(rc, "AI_CONNECTION_LOST_RECONCILE");
    }
    Response response;
    HttpBody* current = nullptr;
    HttpBody parser([&](const char* data, size_t size) {
        if (cfg.stream && current->status() == 200) return chunk(data, size);
        need(response.body.size() + size <= 16000000, "AI_HTTP_BODY_TOO_LARGE");
        response.body.append(data, size); return true;
    }, cfg.stream ? SIZE_MAX : 16000000);
    current = &parser;
    char buffer[16384];
    while (!parser.done()) {
        check(cancel, deadline); ERR_clear_error();
        const int rc = SSL_read(tls.get(), buffer, sizeof(buffer));
        if (rc > 0) {
            if (cfg.stream) deadline = Clock::now() + std::chrono::milliseconds(cfg.timeoutMs);
            parser.feed(buffer, static_cast<size_t>(rc));
        } else {
            const int error = SSL_get_error(tls.get(), rc);
            if (error == SSL_ERROR_ZERO_RETURN) { parser.finish(); break; }
            retry(rc, "AI_CONNECTION_LOST_RECONCILE");
        }
    }
    response.status = parser.status();
    return response;
}
}
