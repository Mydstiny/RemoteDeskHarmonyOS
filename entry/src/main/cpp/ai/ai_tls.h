#pragma once
#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace RemoteAi {
struct Identity { std::string privateKey; std::string csr; };
struct Request {
    std::string address, serverName, ca, certificate, privateKey, path, body;
    int port = 0;
    int timeoutMs = 45000;
    bool stream = false;
    ~Request();
};
class Cancellation {
public:
    void cancel();
    bool stopped() const { return cancelled_.load(); }
    bool attach(int fd);
    void detach();
private:
    std::atomic<bool> cancelled_{false};
    std::mutex mutex_;
    int fd_ = -1;
};
struct Response { int status = 0; std::string body; };
using Chunk = std::function<bool(const char*, size_t)>;
Identity generateIdentity(Cancellation& cancellation);
Response request(const Request& config, Cancellation& cancellation, const Chunk& chunk);
// Tested independently of NAPI against fragmented HTTP/1.1 responses.
class HttpBody {
public:
    explicit HttpBody(Chunk chunk, size_t limit = 16000000);
    void feed(const char* data, size_t size);
    void finish();
    bool done() const { return done_; }
    int status() const { return status_; }
private:
    void headers();
    void consume();
    void deliver(size_t size);
    Chunk chunk_;
    std::string buffer_;
    size_t limit_, bytes_ = 0, remaining_ = 0;
    int status_ = 0;
    bool parsed_ = false, chunked_ = false, hasLength_ = false, done_ = false;
    enum class Phase { Size, Data, End, Trailers } phase_ = Phase::Size;
};
}
