/**
 * rdp_certificate_validation.h - Shared RDP X.509 validation helpers.
 *
 * FreeRDP supplies the leaf certificate followed by the peer chain when its
 * X.509 callback is enabled. Keep that chain intact when evaluating trust and
 * distinguish IP subjectAltName checks from DNS hostname checks.
 */

#pragma once

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif

#include <climits>
#include <cstddef>
#include <string>

namespace RdpCertificateValidation {

inline bool isIpLiteral(const std::string& value) {
    if (value.empty()) {
        return false;
    }
    in_addr ipv4 {};
    if (inet_pton(AF_INET, value.c_str(), &ipv4) == 1) {
        return true;
    }
    in6_addr ipv6 {};
    return inet_pton(AF_INET6, value.c_str(), &ipv6) == 1;
}

inline bool hostnameMatches(X509* certificate, const std::string& name) {
    if (certificate == nullptr || name.empty()) {
        return true;
    }
    if (isIpLiteral(name)) {
        return X509_check_ip_asc(certificate, name.c_str(), 0) == 1;
    }
    return X509_check_host(certificate, name.c_str(), name.size(), 0, nullptr) == 1;
}

inline bool parsePemChain(const unsigned char* data, size_t length,
                          X509*& leaf, STACK_OF(X509)*& untrusted) {
    leaf = nullptr;
    untrusted = nullptr;
    if (data == nullptr || length == 0 || length > static_cast<size_t>(INT_MAX)) {
        return false;
    }
    BIO* bio = BIO_new_mem_buf(data, static_cast<int>(length));
    if (bio == nullptr) {
        return false;
    }
    leaf = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
    if (leaf == nullptr) {
        BIO_free(bio);
        ERR_clear_error();
        return false;
    }
    untrusted = sk_X509_new_null();
    if (untrusted == nullptr) {
        X509_free(leaf);
        leaf = nullptr;
        BIO_free(bio);
        return false;
    }
    for (;;) {
        X509* certificate = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
        if (certificate == nullptr) {
            // PEM_read_bio_X509 reports EOF through the OpenSSL error queue.
            ERR_clear_error();
            break;
        }
        if (sk_X509_push(untrusted, certificate) <= 0) {
            X509_free(certificate);
            sk_X509_pop_free(untrusted, X509_free);
            untrusted = nullptr;
            X509_free(leaf);
            leaf = nullptr;
            BIO_free(bio);
            return false;
        }
    }
    BIO_free(bio);
    return true;
}

inline bool hostnameMatchesPem(const unsigned char* data, size_t length,
                               const std::string& name, bool& parsed) {
    parsed = false;
    X509* leaf = nullptr;
    STACK_OF(X509)* untrusted = nullptr;
    if (!parsePemChain(data, length, leaf, untrusted)) {
        return false;
    }
    parsed = true;
    const bool matches = hostnameMatches(leaf, name);
    sk_X509_pop_free(untrusted, X509_free);
    X509_free(leaf);
    return matches;
}

inline bool rootTrustedFromPemWithStore(const unsigned char* data, size_t length,
                                        X509_STORE* store) {
    if (store == nullptr) {
        return false;
    }
    X509* leaf = nullptr;
    STACK_OF(X509)* untrusted = nullptr;
    if (!parsePemChain(data, length, leaf, untrusted)) {
        return false;
    }
    bool trusted = false;
    X509_STORE_CTX* storeContext = X509_STORE_CTX_new();
    if (storeContext != nullptr &&
        X509_STORE_CTX_init(storeContext, store, leaf, untrusted) == 1) {
        trusted = X509_verify_cert(storeContext) == 1;
    }
    if (storeContext != nullptr) {
        X509_STORE_CTX_free(storeContext);
    }
    sk_X509_pop_free(untrusted, X509_free);
    X509_free(leaf);
    return trusted;
}

inline bool rootTrustedFromPem(const unsigned char* data, size_t length) {
    X509_STORE* store = X509_STORE_new();
    if (store == nullptr) {
        return false;
    }
    const bool ready = X509_STORE_set_default_paths(store) == 1;
    const bool trusted = ready && rootTrustedFromPemWithStore(data, length, store);
    X509_STORE_free(store);
    return trusted;
}

} // namespace RdpCertificateValidation
