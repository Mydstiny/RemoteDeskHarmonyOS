#include "ai_tls.h"
#include <napi/native_api.h>
#include <openssl/crypto.h>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <cstring>
#include <thread>
#include <vector>

namespace RemoteAiNapi {
namespace {
struct Job {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    std::thread worker;
    std::atomic<bool> closing{false};
    std::atomic<bool> callbackFailed{false};
    napi_threadsafe_function chunks = nullptr;
    RemoteAi::Request request;
    RemoteAi::Cancellation cancel;
    RemoteAi::Response response;
    RemoteAi::Identity identity;
    std::string id, error;
    bool generate = false;
    ~Job() {
        if (!identity.privateKey.empty()) OPENSSL_cleanse(identity.privateKey.data(), identity.privateKey.size());
    }
};
std::mutex jobsMutex;
std::map<std::string, std::shared_ptr<Job>> jobs;
struct Chunk { std::string bytes; };
napi_value string(napi_env env, const std::string& value) {
    napi_value result;
    napi_create_string_utf8(env, value.data(), value.size(), &result);
    return result;
}
std::string readString(napi_env env, napi_value object, const char* name, size_t max, bool optional = false) {
    bool exists = false;
    napi_has_named_property(env, object, name, &exists);
    if (!exists && optional) return "";
    napi_value value; napi_valuetype type;
    if (!exists || napi_get_named_property(env, object, name, &value) != napi_ok ||
        napi_typeof(env, value, &type) != napi_ok || type != napi_string) throw std::runtime_error("AI_ARGUMENT_INVALID");
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > max)
        throw std::runtime_error("AI_ARGUMENT_TOO_LARGE");
    std::string text(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, text.data(), text.size(), &length) != napi_ok)
        throw std::runtime_error("AI_ARGUMENT_INVALID");
    text.resize(length);
    if (text.find('\0') != std::string::npos) throw std::runtime_error("AI_ARGUMENT_INVALID");
    return text;
}
int readInt(napi_env env, napi_value object, const char* name) {
    napi_value value; double number = 0;
    if (napi_get_named_property(env, object, name, &value) != napi_ok ||
        napi_get_value_double(env, value, &number) != napi_ok || !(number >= 0 && number <= 65535) ||
        number != static_cast<int>(number)) throw std::runtime_error("AI_ARGUMENT_INVALID");
    return static_cast<int>(number);
}
napi_value bytes(napi_env env, const std::string& data) {
    napi_value value; void* target = nullptr;
    if (napi_create_arraybuffer(env, data.size(), &target, &value) != napi_ok) return nullptr;
    if (!data.empty()) std::memcpy(target, data.data(), data.size());
    return value;
}
void callChunk(napi_env env, napi_value callback, void* context, void* raw) {
    std::unique_ptr<Chunk> chunk(static_cast<Chunk*>(raw));
    auto* job = static_cast<Job*>(context);
    if (!env || !callback || !chunk || !job || job->closing.load() || job->cancel.stopped()) return;
    napi_value argument = bytes(env, chunk->bytes), receiver, ignored;
    napi_get_undefined(env, &receiver);
    if (!argument || napi_call_function(env, receiver, callback, 1, &argument, &ignored) != napi_ok) {
        bool pending = false; napi_is_exception_pending(env, &pending);
        if (pending) { napi_value exception; napi_get_and_clear_last_exception(env, &exception); }
        job->callbackFailed.store(true); job->cancel.cancel();
    }
}
void execute(void* raw) {
    auto* job = static_cast<Job*>(raw);
    try {
        if (job->cancel.stopped()) throw std::runtime_error("AI_REQUEST_CANCELLED");
        if (job->generate) job->identity = RemoteAi::generateIdentity(job->cancel);
        else job->response = RemoteAi::request(job->request, job->cancel, [&](const char* data, size_t size) {
            if (job->cancel.stopped() || !job->chunks) return false;
            auto chunk = std::make_unique<Chunk>();
            chunk->bytes.assign(data, size);
            if (napi_call_threadsafe_function(job->chunks, chunk.get(), napi_tsfn_nonblocking) != napi_ok) return false;
            chunk.release(); return true;
        });
    } catch (const std::exception& error) { job->error = error.what(); }
    catch (...) { job->error = "AI_NATIVE_FAILURE"; }
    napi_release_threadsafe_function(job->chunks, napi_tsfn_release);
}
void finalize(napi_env env, void* raw, void*) {
    std::unique_ptr<std::shared_ptr<Job>> held(static_cast<std::shared_ptr<Job>*>(raw));
    auto job = *held;
    // Worker no longer produces events; all queued chunks have been dispatched
    // (or discarded during environment teardown) before this finalizer runs.
    if (job->worker.joinable()) job->worker.join();
    {
        std::lock_guard<std::mutex> lock(jobsMutex);
        auto found = jobs.find(job->id);
        if (found != jobs.end() && found->second == job) jobs.erase(found);
    }
    if (!env || !job->deferred) return;
    napi_handle_scope scope = nullptr;
    if (napi_open_handle_scope(env, &scope) != napi_ok) return;
    if (job->callbackFailed.load()) job->error = "AI_STREAM_CALLBACK_FAILED";
    if (job->cancel.stopped() && job->error.empty()) job->error = "AI_REQUEST_CANCELLED";
    if (!job->error.empty()) {
        napi_value error;
        napi_create_error(env, nullptr, string(env, job->error), &error);
        napi_reject_deferred(env, job->deferred, error);
    } else {
        napi_value result;
        napi_create_object(env, &result);
        if (job->generate) {
            napi_set_named_property(env, result, "privateKey", string(env, job->identity.privateKey));
            napi_set_named_property(env, result, "csr", string(env, job->identity.csr));
        } else {
            napi_value code;
            napi_create_int32(env, job->response.status, &code);
            napi_set_named_property(env, result, "status", code);
            napi_set_named_property(env, result, "body", bytes(env, job->response.body));
        }
        napi_resolve_deferred(env, job->deferred, result);
    }
    job->deferred = nullptr;
    napi_close_handle_scope(env, scope);
}
napi_value start(napi_env env, napi_callback_info info, bool generate) {
    std::shared_ptr<Job> job = std::make_shared<Job>();
    bool registered = false;
    napi_value promise = nullptr;
    try {
        napi_value argv[2]; size_t argc = 2;
        napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
        if (argc < 1) throw std::runtime_error("AI_ARGUMENT_INVALID");
        job->env = env; job->generate = generate;
        job->id = readString(env, argv[0], "id", 100);
        if (job->id.empty()) throw std::runtime_error("AI_ARGUMENT_INVALID");
        if (!generate) {
            auto& cfg = job->request;
            cfg.address = readString(env, argv[0], "address", 253);
            cfg.serverName = readString(env, argv[0], "serverName", 253);
            cfg.port = readInt(env, argv[0], "port");
            cfg.timeoutMs = readInt(env, argv[0], "timeoutMs");
            cfg.ca = readString(env, argv[0], "ca", 65536);
            cfg.caSha256 = readString(env, argv[0], "caSha256", 64, true);
            cfg.certificate = readString(env, argv[0], "certificate", 65536, true);
            cfg.privateKey = readString(env, argv[0], "privateKey", 16384, true);
            cfg.path = readString(env, argv[0], "path", 500);
            cfg.body = readString(env, argv[0], "body", 800000, true);
            cfg.stream = cfg.path.rfind("/v1/events?", 0) == 0;

        }
        {
            std::lock_guard<std::mutex> lock(jobsMutex);
            if (jobs.size() >= 8 || jobs.count(job->id)) throw std::runtime_error("AI_NATIVE_BUSY");
            jobs.emplace(job->id, job); registered = true;
        }
        napi_value callback = nullptr;
        if (job->request.stream) {
            napi_valuetype type;
            if (argc < 2 || napi_typeof(env, argv[1], &type) != napi_ok || type != napi_function)
                throw std::runtime_error("AI_STREAM_CALLBACK_REQUIRED");
            callback = argv[1];
        }
        if (napi_create_promise(env, &job->deferred, &promise) != napi_ok)
            throw std::runtime_error("AI_NATIVE_UNAVAILABLE");
        auto held = std::make_unique<std::shared_ptr<Job>>(job);
        if (napi_create_threadsafe_function(env, callback, nullptr, string(env, "RemoteAiStream"),
            128, 1, held.get(), finalize, job.get(), callChunk, &job->chunks) != napi_ok)
            throw std::runtime_error("AI_STREAM_UNAVAILABLE");
        held.release();
        try { job->worker = std::thread([job]() { execute(job.get()); }); }
        catch (...) {
            job->error = "AI_NATIVE_UNAVAILABLE";
            napi_release_threadsafe_function(job->chunks, napi_tsfn_release);
        }

        return promise;
    } catch (const std::exception& error) {
        if (registered) { std::lock_guard<std::mutex> lock(jobsMutex); jobs.erase(job->id); }
        if (job->chunks) napi_release_threadsafe_function(job->chunks, napi_tsfn_abort);
        if (job->deferred) {
            napi_value failure; napi_create_error(env, nullptr, string(env, error.what()), &failure);
            napi_reject_deferred(env, job->deferred, failure); job->deferred = nullptr;
            return promise;
        }
        napi_throw_error(env, nullptr, error.what());
        return nullptr;
    }
}
napi_value request(napi_env env, napi_callback_info info) { return start(env, info, false); }
napi_value identity(napi_env env, napi_callback_info info) { return start(env, info, true); }
napi_value cancel(napi_env env, napi_callback_info info) {
    napi_value argv[1]; size_t argc = 1;
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc == 1) {
        try {
            const std::string id = readString(env, argv[0], "id", 100);
            std::lock_guard<std::mutex> lock(jobsMutex);
            auto found = jobs.find(id);
            if (found != jobs.end() && found->second->env == env) found->second->cancel.cancel();
        } catch (...) { napi_throw_error(env, nullptr, "AI_ARGUMENT_INVALID"); return nullptr; }
    }
    napi_value result; napi_get_undefined(env, &result); return result;
}
void cleanup(void* raw) {
    auto env = static_cast<napi_env>(raw);
    std::vector<std::shared_ptr<Job>> owned;
    {
        std::lock_guard<std::mutex> lock(jobsMutex);
        for (auto& entry : jobs) {
            if (entry.second->env == env) {
                entry.second->closing.store(true);
                entry.second->cancel.cancel();
                owned.push_back(entry.second);
            }
        }
    }
    // No worker waits on JavaScript: queue insertion is non-blocking, sockets
    // are cancellable, and DNS is resolved outside native before credentials.
    for (auto& job : owned) if (job->worker.joinable()) job->worker.join();
    napi_handle_scope scope = nullptr;
    if (napi_open_handle_scope(env, &scope) == napi_ok) {
        for (auto& job : owned) {
            if (job->deferred) {
                napi_value error; napi_create_error(env, nullptr, string(env, "AI_ENVIRONMENT_CLOSED"), &error);
                napi_reject_deferred(env, job->deferred, error); job->deferred = nullptr;
            }
        }
        napi_close_handle_scope(env, scope);
    }
}
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"aiTlsRequest", nullptr, request, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"aiGenerateIdentity", nullptr, identity, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"aiCancelRequest", nullptr, cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    napi_add_env_cleanup_hook(env, cleanup, env);
    return exports;
}
}
