#include "moonlight/moonlight_napi.h"

#include "moonlight/bridge/MoonlightNativeBridge.h"
#include "moonlight/runtime/MoonlightProductRuntime.h"
#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

constexpr double kMaxSafeInteger = 9007199254740991.0;
constexpr std::size_t kMaxIdentityBytes = 256U;
constexpr std::size_t kMaxAddressBytes = 512U;
constexpr std::size_t kMaxDiagnosticTokenBytes = 64U;

enum class AsyncRequestPhase : std::uint8_t {
    Queued = 0,
    Executing,
    ResultReady,
    Completing,
    Completed,
};

struct NapiKeyHash final {
    std::size_t operator()(const MoonlightBridgeRequestKey& key) const noexcept {
        std::size_t value = static_cast<std::size_t>(key.requestId);
        value ^= static_cast<std::size_t>(key.generation) + 0x9e3779b9U +
                 (value << 6U) + (value >> 2U);
        value ^= static_cast<std::size_t>(key.ownerToken) + 0x9e3779b9U +
                 (value << 6U) + (value >> 2U);
        return value;
    }
};

struct AsyncRequestControl final {
    MoonlightBridgeRequestKey key {};
    MoonlightBridgeOperation operation = MoonlightBridgeOperation::Catalog;
    std::atomic<bool> cancellationRequested {false};
    std::atomic<AsyncRequestPhase> phase {AsyncRequestPhase::Queued};
    std::atomic<napi_async_work> work {nullptr};
};

struct MoonlightEnvState final {
    explicit MoonlightEnvState(napi_env valueEnv)
        : env(valueEnv), bridge(std::make_shared<MoonlightNativeBridge>(
                             createMoonlightProductRuntimePort())) {}

    napi_env env = nullptr;
    std::atomic<bool> closing {false};
    std::shared_ptr<MoonlightNativeBridge> bridge;
    std::mutex pendingMutex;
    std::unordered_map<MoonlightBridgeRequestKey,
                       std::shared_ptr<AsyncRequestControl>, NapiKeyHash> pending;
};

std::mutex gEnvMutex;
std::unordered_map<napi_env, std::shared_ptr<MoonlightEnvState>> gEnvStates;

std::shared_ptr<MoonlightEnvState> stateFor(napi_env env) {
    std::lock_guard<std::mutex> lock(gEnvMutex);
    const auto iterator = gEnvStates.find(env);
    return iterator == gEnvStates.end() ? nullptr : iterator->second;
}

void cleanupEnvironment(void* rawData) noexcept {
    try {
        auto* rawState = static_cast<MoonlightEnvState*>(rawData);
        std::shared_ptr<MoonlightEnvState> state;
        {
            std::lock_guard<std::mutex> lock(gEnvMutex);
            for (auto iterator = gEnvStates.begin(); iterator != gEnvStates.end();
                 ++iterator) {
                if (iterator->second.get() == rawState) {
                    state = iterator->second;
                    gEnvStates.erase(iterator);
                    break;
                }
            }
        }
        if (state == nullptr) {
            return;
        }
        state->closing.store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(state->pendingMutex);
            for (const auto& item : state->pending) {
                item.second->cancellationRequested.store(
                    true, std::memory_order_release);
                const auto work = item.second->work.load(std::memory_order_acquire);
                if (work != nullptr) {
                    (void)napi_cancel_async_work(state->env, work);
                }
            }
        }
        if (state->bridge != nullptr) {
            state->bridge->shutdown();
        }
        MoonlightProductStreamingRuntime::process().shutdown();
    } catch (...) {
        // The environment is already closing; no exception may cross NAPI.
    }
}

bool hasProperty(napi_env env, napi_value object, const char* name, bool& present) {
    return napi_has_named_property(env, object, name, &present) == napi_ok;
}

bool getProperty(napi_env env, napi_value object, const char* name, napi_value& value) {
    return napi_get_named_property(env, object, name, &value) == napi_ok;
}

bool readExactObject(napi_env env, napi_value value,
                     const std::unordered_set<std::string>& allowed,
                     std::string& error) {
    napi_valuetype type = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &type) != napi_ok ||
        type != napi_object) {
        error = "value must be an object";
        return false;
    }
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || isArray) {
        error = "value must be a non-array object";
        return false;
    }
    napi_value names = nullptr;
    if (napi_get_property_names(env, value, &names) != napi_ok) {
        error = "object properties are not readable";
        return false;
    }
    std::uint32_t length = 0U;
    if (napi_get_array_length(env, names, &length) != napi_ok) {
        error = "object properties are not enumerable";
        return false;
    }
    for (std::uint32_t index = 0U; index < length; ++index) {
        napi_value item = nullptr;
        if (napi_get_element(env, names, index, &item) != napi_ok) {
            error = "object property name is invalid";
            return false;
        }
        napi_valuetype itemType = napi_undefined;
        if (napi_typeof(env, item, &itemType) != napi_ok || itemType != napi_string) {
            error = "symbol properties are not accepted";
            return false;
        }
        std::size_t size = 0U;
        if (napi_get_value_string_utf8(env, item, nullptr, 0U, &size) != napi_ok ||
            size == 0U || size > kMaxDiagnosticTokenBytes) {
            error = "object property name is invalid";
            return false;
        }
        std::string name(size, '\0');
        std::size_t copied = 0U;
        std::vector<char> buffer(size + 1U, '\0');
        if (napi_get_value_string_utf8(env, item, buffer.data(), buffer.size(),
                                       &copied) != napi_ok || copied != size) {
            error = "object property name is invalid";
            return false;
        }
        name.assign(buffer.data(), copied);
        if (allowed.find(name) == allowed.end()) {
            error = "object contains an unknown field";
            return false;
        }
    }
    return true;
}

bool readStringValue(napi_env env, napi_value value, std::size_t maximum,
                     std::string& output, std::string& error) {
    napi_valuetype type = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &type) != napi_ok ||
        type != napi_string) {
        error = "field must be a string";
        return false;
    }
    std::size_t size = 0U;
    if (napi_get_value_string_utf8(env, value, nullptr, 0U, &size) != napi_ok ||
        size == 0U || size > maximum) {
        error = "string field is outside its bound";
        return false;
    }
    std::vector<char> buffer(size + 1U, '\0');
    std::size_t copied = 0U;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                   &copied) != napi_ok || copied != size) {
        error = "string field could not be read";
        return false;
    }
    output.assign(buffer.data(), copied);
    if (std::any_of(output.begin(), output.end(), [](char character) {
            const auto byte = static_cast<unsigned char>(character);
            return byte < 0x20U || byte == 0x7fU;
        })) {
        output.clear();
        error = "string field contains a control character";
        return false;
    }
    return true;
}

bool readRequiredString(napi_env env, napi_value object, const char* name,
                        std::size_t maximum, std::string& output,
                        std::string& error) {
    bool present = false;
    napi_value value = nullptr;
    if (!hasProperty(env, object, name, present) || !present ||
        !getProperty(env, object, name, value)) {
        error = "required string field is missing";
        return false;
    }
    return readStringValue(env, value, maximum, output, error);
}

bool readOptionalString(napi_env env, napi_value object, const char* name,
                        std::size_t maximum, std::string& output,
                        std::string& error) {
    bool present = false;
    if (!hasProperty(env, object, name, present)) {
        error = "optional string field is not readable";
        return false;
    }
    if (!present) {
        return true;
    }
    napi_value value = nullptr;
    return getProperty(env, object, name, value) &&
           readStringValue(env, value, maximum, output, error);
}

bool readSafeIntegerValue(napi_env env, napi_value value, bool allowZero,
                          std::uint64_t& output, std::string& error) {
    napi_valuetype type = napi_undefined;
    double number = 0.0;
    if (value == nullptr || napi_typeof(env, value, &type) != napi_ok ||
        type != napi_number || napi_get_value_double(env, value, &number) != napi_ok ||
        !std::isfinite(number) || std::floor(number) != number || number < 0.0 ||
        (!allowZero && number == 0.0) || number > kMaxSafeInteger) {
        error = "field must be a bounded safe integer";
        return false;
    }
    output = static_cast<std::uint64_t>(number);
    return true;
}

bool readRequiredSafeInteger(napi_env env, napi_value object, const char* name,
                             bool allowZero, std::uint64_t& output,
                             std::string& error) {
    bool present = false;
    napi_value value = nullptr;
    if (!hasProperty(env, object, name, present) || !present ||
        !getProperty(env, object, name, value)) {
        error = "required integer field is missing";
        return false;
    }
    return readSafeIntegerValue(env, value, allowZero, output, error);
}

bool readOptionalSafeInteger(napi_env env, napi_value object, const char* name,
                             bool allowZero, std::uint64_t& output,
                             std::string& error) {
    bool present = false;
    if (!hasProperty(env, object, name, present)) {
        error = "optional integer field is not readable";
        return false;
    }
    if (!present) {
        return true;
    }
    napi_value value = nullptr;
    return getProperty(env, object, name, value) &&
           readSafeIntegerValue(env, value, allowZero, output, error);
}

bool readBooleanValue(napi_env env, napi_value value, bool& output,
                      std::string& error) {
    napi_valuetype type = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &type) != napi_ok ||
        type != napi_boolean || napi_get_value_bool(env, value, &output) != napi_ok) {
        error = "field must be a boolean";
        return false;
    }
    return true;
}

bool readOptionalBoolean(napi_env env, napi_value object, const char* name,
                         bool& output, std::string& error) {
    bool present = false;
    if (!hasProperty(env, object, name, present)) {
        error = "optional boolean field is not readable";
        return false;
    }
    if (!present) {
        return true;
    }
    napi_value value = nullptr;
    return getProperty(env, object, name, value) &&
           readBooleanValue(env, value, output, error);
}

bool readBytesValue(napi_env env, napi_value value, std::size_t exactSize,
                    std::vector<std::uint8_t>& output, std::string& error) {
    bool isArrayBuffer = false;
    if (napi_is_arraybuffer(env, value, &isArrayBuffer) != napi_ok) {
        error = "binary field type could not be read";
        return false;
    }
    void* data = nullptr;
    std::size_t size = 0U;
    if (isArrayBuffer) {
        if (napi_get_arraybuffer_info(env, value, &data, &size) != napi_ok) {
            error = "ArrayBuffer field could not be read";
            return false;
        }
    } else {
        bool isTypedArray = false;
        if (napi_is_typedarray(env, value, &isTypedArray) != napi_ok || !isTypedArray) {
            error = "binary field must be an ArrayBuffer or Uint8Array";
            return false;
        }
        napi_typedarray_type arrayType = napi_int8_array;
        napi_value arrayBuffer = nullptr;
        std::size_t offset = 0U;
        if (napi_get_typedarray_info(env, value, &arrayType, &size, &data,
                                     &arrayBuffer, &offset) != napi_ok ||
            arrayType != napi_uint8_array) {
            error = "typed binary field must be Uint8Array";
            return false;
        }
    }
    if (size != exactSize || data == nullptr) {
        error = "binary field has an invalid length";
        return false;
    }
    const auto* begin = static_cast<const std::uint8_t*>(data);
    output.assign(begin, begin + size);
    return true;
}

bool readOptionalBytes(napi_env env, napi_value object, const char* name,
                       std::size_t exactSize, std::vector<std::uint8_t>& output,
                       std::string& error) {
    bool present = false;
    if (!hasProperty(env, object, name, present)) {
        error = "optional binary field is not readable";
        return false;
    }
    if (!present) {
        return true;
    }
    napi_value value = nullptr;
    return getProperty(env, object, name, value) &&
           readBytesValue(env, value, exactSize, output, error);
}

bool parseOperation(const std::string& value, MoonlightBridgeOperation& operation) {
    if (value == "pair") {
        operation = MoonlightBridgeOperation::Pair;
    } else if (value == "catalog") {
        operation = MoonlightBridgeOperation::Catalog;
    } else if (value == "asset") {
        operation = MoonlightBridgeOperation::Asset;
    } else if (value == "launch") {
        operation = MoonlightBridgeOperation::Launch;
    } else if (value == "resume") {
        operation = MoonlightBridgeOperation::Resume;
    } else if (value == "quit") {
        operation = MoonlightBridgeOperation::Quit;
    } else {
        return false;
    }
    return true;
}

bool parseRequestKey(napi_env env, napi_value value,
                     MoonlightBridgeRequestKey& key, std::string& error) {
    static const std::unordered_set<std::string> allowed {
        "requestId", "generation", "ownerToken"
    };
    return readExactObject(env, value, allowed, error) &&
           readRequiredSafeInteger(env, value, "requestId", false,
                                   key.requestId, error) &&
           readRequiredSafeInteger(env, value, "generation", false,
                                   key.generation, error) &&
           readRequiredSafeInteger(env, value, "ownerToken", false,
                                   key.ownerToken, error);
}

bool parseAddress(napi_env env, napi_value value, MoonlightHostAddress& address,
                  std::string& error) {
    static const std::unordered_set<std::string> allowed {"value", "family"};
    std::string family;
    if (!readExactObject(env, value, allowed, error) ||
        !readRequiredString(env, value, "value", kMaxAddressBytes,
                            address.value, error) ||
        !readRequiredString(env, value, "family", 16U, family, error)) {
        return false;
    }
    if (family == "ipv4") {
        address.family = MoonlightHostAddressFamily::Ipv4;
    } else if (family == "ipv6") {
        address.family = MoonlightHostAddressFamily::Ipv6;
    } else if (family == "unspecified") {
        address.family = MoonlightHostAddressFamily::Unspecified;
    } else {
        error = "address family is not supported";
        return false;
    }
    return true;
}

bool parseEndpoint(napi_env env, napi_value value, MoonlightHostEndpoint& endpoint,
                   std::string& error) {
    static const std::unordered_set<std::string> allowed {
        "serverName", "addresses", "httpPort", "httpsPort",
        "pinnedTrustAvailable", "allowHttpPairingCandidate"
    };
    if (!readExactObject(env, value, allowed, error) ||
        !readRequiredString(env, value, "serverName", kMaxIdentityBytes,
                            endpoint.serverName, error)) {
        return false;
    }
    bool present = false;
    napi_value addresses = nullptr;
    bool isArray = false;
    if (!hasProperty(env, value, "addresses", present) || !present ||
        !getProperty(env, value, "addresses", addresses) ||
        napi_is_array(env, addresses, &isArray) != napi_ok || !isArray) {
        error = "endpoint addresses must be an array";
        return false;
    }
    std::uint32_t length = 0U;
    if (napi_get_array_length(env, addresses, &length) != napi_ok || length == 0U ||
        length > MoonlightHostLimits::kMaxAddresses) {
        error = "endpoint address count is outside its bound";
        return false;
    }
    endpoint.addresses.reserve(length);
    for (std::uint32_t index = 0U; index < length; ++index) {
        napi_value item = nullptr;
        MoonlightHostAddress address;
        if (napi_get_element(env, addresses, index, &item) != napi_ok ||
            !parseAddress(env, item, address, error)) {
            return false;
        }
        endpoint.addresses.push_back(std::move(address));
    }
    std::uint64_t httpPort = endpoint.httpPort;
    std::uint64_t httpsPort = endpoint.httpsPort;
    if (!readOptionalSafeInteger(env, value, "httpPort", false, httpPort, error) ||
        !readOptionalSafeInteger(env, value, "httpsPort", false, httpsPort, error) ||
        httpPort > 65535U || httpsPort > 65535U ||
        !readOptionalBoolean(env, value, "pinnedTrustAvailable",
                             endpoint.pinnedTrustAvailable, error) ||
        !readOptionalBoolean(env, value, "allowHttpPairingCandidate",
                             endpoint.allowHttpPairingCandidate, error)) {
        error = error.empty() ? "endpoint port is invalid" : error;
        return false;
    }
    endpoint.httpPort = static_cast<std::uint16_t>(httpPort);
    endpoint.httpsPort = static_cast<std::uint16_t>(httpsPort);
    return true;
}

bool parseLaunchConfiguration(napi_env env, napi_value value,
                              MoonlightBridgeLaunchConfiguration& configuration,
                              std::string& error) {
    static const std::unordered_set<std::string> allowed {
        "width", "height", "refreshRate", "additionalStates", "sops", "hdr",
        "playAudioOnHost", "surroundAudioInfo", "remoteControllersBitmap",
        "gamepadMask", "persistGamepads"
    };
    if (!readExactObject(env, value, allowed, error)) {
        return false;
    }
    std::uint64_t width = configuration.width;
    std::uint64_t height = configuration.height;
    std::uint64_t refreshRate = configuration.refreshRate;
    std::uint64_t surround = configuration.surroundAudioInfo;
    std::uint64_t controllers = configuration.remoteControllersBitmap;
    std::uint64_t gamepads = configuration.gamepadMask;
    if (!readOptionalSafeInteger(env, value, "width", false, width, error) ||
        !readOptionalSafeInteger(env, value, "height", false, height, error) ||
        !readOptionalSafeInteger(env, value, "refreshRate", false, refreshRate, error) ||
        !readOptionalSafeInteger(env, value, "surroundAudioInfo", true, surround, error) ||
        !readOptionalSafeInteger(env, value, "remoteControllersBitmap", true,
                                 controllers, error) ||
        !readOptionalSafeInteger(env, value, "gamepadMask", true, gamepads, error) ||
        width > std::numeric_limits<std::uint32_t>::max() ||
        height > std::numeric_limits<std::uint32_t>::max() ||
        refreshRate > std::numeric_limits<std::uint32_t>::max() ||
        surround > std::numeric_limits<std::uint32_t>::max() ||
        controllers > std::numeric_limits<std::uint32_t>::max() ||
        gamepads > std::numeric_limits<std::uint32_t>::max() ||
        !readOptionalBoolean(env, value, "additionalStates",
                             configuration.additionalStates, error) ||
        !readOptionalBoolean(env, value, "sops", configuration.sops, error) ||
        !readOptionalBoolean(env, value, "hdr", configuration.hdr, error) ||
        !readOptionalBoolean(env, value, "playAudioOnHost",
                             configuration.playAudioOnHost, error) ||
        !readOptionalBoolean(env, value, "persistGamepads",
                             configuration.persistGamepads, error)) {
        error = error.empty() ? "launch configuration integer is invalid" : error;
        return false;
    }
    configuration.width = static_cast<std::uint32_t>(width);
    configuration.height = static_cast<std::uint32_t>(height);
    configuration.refreshRate = static_cast<std::uint32_t>(refreshRate);
    configuration.surroundAudioInfo = static_cast<std::uint32_t>(surround);
    configuration.remoteControllersBitmap = static_cast<std::uint32_t>(controllers);
    configuration.gamepadMask = static_cast<std::uint32_t>(gamepads);
    return true;
}

bool parseRequest(napi_env env, napi_value value, MoonlightBridgeRequest& request,
                  std::string& error) {
    static const std::unordered_set<std::string> allowed {
        "operation", "key", "ownerScopeFingerprint", "installationId", "hostId",
        "serverUuid", "pinnedCertificateSha256", "endpoint", "timeoutMs", "appId", "catalogGeneration",
        "expectedCurrentAppId", "userConfirmedTermination", "allowLegacySha1",
        "pin", "launchConfiguration"
    };
    if (!readExactObject(env, value, allowed, error)) {
        return false;
    }
    std::string operation;
    if (!readRequiredString(env, value, "operation", 16U, operation, error) ||
        !parseOperation(operation, request.operation)) {
        error = "operation is not supported";
        return false;
    }
    bool present = false;
    napi_value nested = nullptr;
    if (!hasProperty(env, value, "key", present) || !present ||
        !getProperty(env, value, "key", nested) ||
        !parseRequestKey(env, nested, request.key, error) ||
        !readRequiredString(env, value, "ownerScopeFingerprint", 64U,
                            request.ownerScopeFingerprint, error) ||
        !readOptionalString(env, value, "installationId", kMaxIdentityBytes,
                            request.installationId, error) ||
        !readRequiredString(env, value, "hostId", kMaxIdentityBytes,
                            request.hostId, error) ||
        !readRequiredString(env, value, "serverUuid", kMaxIdentityBytes,
                            request.serverUuid, error) ||
        !readOptionalString(env, value, "pinnedCertificateSha256", 64U,
                            request.pinnedCertificateSha256, error)) {
        return false;
    }
    if (request.ownerScopeFingerprint.size() != 64U ||
        std::any_of(request.ownerScopeFingerprint.begin(),
                    request.ownerScopeFingerprint.end(), [](char character) {
                        return !((character >= '0' && character <= '9') ||
                                 (character >= 'a' && character <= 'f'));
                    })) {
        error = "owner scope fingerprint must be 64 lowercase hex characters";
        return false;
    }
    if (!request.pinnedCertificateSha256.empty() &&
        (request.pinnedCertificateSha256.size() != 64U ||
         std::any_of(request.pinnedCertificateSha256.begin(),
                     request.pinnedCertificateSha256.end(), [](char character) {
                         return !((character >= '0' && character <= '9') ||
                                  (character >= 'a' && character <= 'f'));
                     }))) {
        error = "pinned certificate fingerprint must be 64 lowercase hex characters";
        return false;
    }
    if (!hasProperty(env, value, "endpoint", present) || !present ||
        !getProperty(env, value, "endpoint", nested) ||
        !parseEndpoint(env, nested, request.endpoint, error)) {
        error = error.empty() ? "endpoint is required" : error;
        return false;
    }
    std::uint64_t timeoutMs = request.timeout.count();
    std::uint64_t appId = request.appId;
    std::uint64_t catalogGeneration = request.catalogGeneration;
    std::uint64_t expectedAppId = request.expectedCurrentAppId;
    if (!readOptionalSafeInteger(env, value, "timeoutMs", false, timeoutMs, error) ||
        !readOptionalSafeInteger(env, value, "appId", true, appId, error) ||
        !readOptionalSafeInteger(env, value, "catalogGeneration", true,
                                 catalogGeneration, error) ||
        !readOptionalSafeInteger(env, value, "expectedCurrentAppId", true,
                                 expectedAppId, error) ||
        timeoutMs > static_cast<std::uint64_t>(MoonlightHostLimits::kMaxTimeout.count()) ||
        appId > std::numeric_limits<std::uint32_t>::max() ||
        expectedAppId > std::numeric_limits<std::uint32_t>::max() ||
        !readOptionalBoolean(env, value, "userConfirmedTermination",
                             request.userConfirmedTermination, error) ||
        !readOptionalBoolean(env, value, "allowLegacySha1",
                             request.allowLegacySha1, error) ||
        !readOptionalBytes(env, value, "pin", 4U, request.pin, error)) {
        error = error.empty() ? "request integer is invalid" : error;
        return false;
    }
    request.timeout = std::chrono::milliseconds(timeoutMs);
    request.appId = static_cast<std::uint32_t>(appId);
    request.catalogGeneration = catalogGeneration;
    request.expectedCurrentAppId = static_cast<std::uint32_t>(expectedAppId);
    if (!hasProperty(env, value, "launchConfiguration", present)) {
        error = "launch configuration field is not readable";
        return false;
    }
    if (present && (!getProperty(env, value, "launchConfiguration", nested) ||
                    !parseLaunchConfiguration(env, nested,
                                              request.launchConfiguration, error))) {
        return false;
    }
    return true;
}

void setString(napi_env env, napi_value object, const char* name, const char* value) {
    napi_value item = nullptr;
    if (napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void setString(napi_env env, napi_value object, const char* name,
               const std::string& value) {
    napi_value item = nullptr;
    if (napi_create_string_utf8(env, value.c_str(), value.size(), &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void setBoolean(napi_env env, napi_value object, const char* name, bool value) {
    napi_value item = nullptr;
    if (napi_get_boolean(env, value, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void setSafeInteger(napi_env env, napi_value object, const char* name,
                    std::uint64_t value) {
    napi_value item = nullptr;
    if (napi_create_double(env, static_cast<double>(value), &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void setInt32(napi_env env, napi_value object, const char* name, std::int32_t value) {
    napi_value item = nullptr;
    if (napi_create_int32(env, value, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void setSize(napi_env env, napi_value object, const char* name, std::size_t value) {
    setSafeInteger(env, object, name, static_cast<std::uint64_t>(value));
}

napi_value createKey(napi_env env, const MoonlightBridgeRequestKey& key) {
    napi_value object = nullptr;
    (void)napi_create_object(env, &object);
    setSafeInteger(env, object, "requestId", key.requestId);
    setSafeInteger(env, object, "generation", key.generation);
    setSafeInteger(env, object, "ownerToken", key.ownerToken);
    return object;
}

std::string safeDiagnosticToken(const std::string& value,
                                const char* fallback) {
    if (value.empty() || value.size() > kMaxDiagnosticTokenBytes ||
        std::any_of(value.begin(), value.end(), [](char character) {
            return !((character >= 'a' && character <= 'z') ||
                     (character >= '0' && character <= '9') ||
                     character == '_');
        })) {
        return fallback;
    }
    return value;
}

napi_value createResult(napi_env env, const MoonlightBridgeResult& result) {
    napi_value object = nullptr;
    (void)napi_create_object(env, &object);
    setString(env, object, "operation", moonlightBridgeOperationName(result.operation));
    (void)napi_set_named_property(env, object, "key", createKey(env, result.key));
    setString(env, object, "code", moonlightBridgeCodeName(result.code));
    setString(env, object, "terminalStage",
              moonlightBridgeTerminalStageName(result.terminalStage));
    setString(env, object, "preflightTruth",
              moonlightBridgeTruthName(result.preflightTruth));
    setString(env, object, "actionTruth", moonlightBridgeTruthName(result.actionTruth));
    setString(env, object, "postconditionTruth",
              moonlightBridgeTruthName(result.postconditionTruth));
    setSize(env, object, "partialAppCount", result.partialAppCount);
    setSafeInteger(env, object, "observedAtMs", result.observedAtMs);
    setBoolean(env, object, "idempotent", result.idempotent);
    setBoolean(env, object, "mutationMayHaveBeenSent",
               result.mutationMayHaveBeenSent);

    napi_value apps = nullptr;
    (void)napi_create_array_with_length(env, result.apps.size(), &apps);
    for (std::size_t index = 0U; index < result.apps.size(); ++index) {
        napi_value app = nullptr;
        (void)napi_create_object(env, &app);
        setSafeInteger(env, app, "id", result.apps[index].id);
        setString(env, app, "title", result.apps[index].title);
        if (result.apps[index].hdrSupported.has_value()) {
            setBoolean(env, app, "hdrSupported", *result.apps[index].hdrSupported);
        }
        (void)napi_set_element(env, apps, static_cast<std::uint32_t>(index), app);
    }
    (void)napi_set_named_property(env, object, "apps", apps);

    napi_value asset = nullptr;
    void* assetData = nullptr;
    if (napi_create_arraybuffer(env, result.asset.size(), &assetData, &asset) == napi_ok) {
        if (!result.asset.empty() && assetData != nullptr) {
            std::memcpy(assetData, result.asset.data(), result.asset.size());
        }
        (void)napi_set_named_property(env, object, "asset", asset);
    }
    if (!result.certificateSha256.empty()) {
        setString(env, object, "certificateSha256", result.certificateSha256);
    }
    if (result.rtspSessionUrl.has_value()) {
        setString(env, object, "rtspSessionUrl", *result.rtspSessionUrl);
    }

    napi_value diagnostics = nullptr;
    (void)napi_create_array_with_length(env, result.diagnostics.size(), &diagnostics);
    for (std::size_t index = 0U; index < result.diagnostics.size(); ++index) {
        const auto& source = result.diagnostics[index];
        napi_value diagnostic = nullptr;
        (void)napi_create_object(env, &diagnostic);
        setString(env, diagnostic, "stage",
                  safeDiagnosticToken(source.stage, "failed"));
        setString(env, diagnostic, "code",
                  safeDiagnosticToken(source.code, "protocol_failure"));
        setInt32(env, diagnostic, "httpStatus", source.httpStatus);
        setInt32(env, diagnostic, "xmlStatus", source.xmlStatus);
        setSize(env, diagnostic, "transportAttempts", source.transportAttempts);
        setSize(env, diagnostic, "byteCount", source.byteCount);
        setSafeInteger(env, diagnostic, "appIdFingerprint",
                       source.appIdFingerprint);
        (void)napi_set_element(env, diagnostics, static_cast<std::uint32_t>(index),
                               diagnostic);
    }
    (void)napi_set_named_property(env, object, "diagnostics", diagnostics);
    return object;
}

napi_value createCapabilities(napi_env env,
                              const MoonlightBridgeCapabilities& capabilities) {
    napi_value object = nullptr;
    (void)napi_create_object(env, &object);
    setBoolean(env, object, "bridgeCompiled", capabilities.bridgeCompiled);
    setBoolean(env, object, "identityReady", capabilities.identityReady);
    setBoolean(env, object, "transportReady", capabilities.transportReady);
    setBoolean(env, object, "trustReady", capabilities.trustReady);
    setBoolean(env, object, "commitReady", capabilities.commitReady);
    setBoolean(env, object, "pairingReady", capabilities.pairingReady);
    setBoolean(env, object, "hostControlReady", capabilities.hostControlReady);
    setString(env, object, "blocker",
              safeDiagnosticToken(capabilities.blocker, "runtime_proof_required"));
    return object;
}

napi_value createEvent(napi_env env, const MoonlightBridgeEvent& event) {
    napi_value object = nullptr;
    (void)napi_create_object(env, &object);
    setSafeInteger(env, object, "sequence", event.sequence);
    setSafeInteger(env, object, "monotonicTimestampMs", event.monotonicTimestampMs);
    setString(env, object, "operation", moonlightBridgeOperationName(event.operation));
    (void)napi_set_named_property(env, object, "key", createKey(env, event.key));
    setString(env, object, "code", moonlightBridgeCodeName(event.code));
    setString(env, object, "terminalStage",
              moonlightBridgeTerminalStageName(event.terminalStage));
    return object;
}

struct RequestAsyncData final {
    std::shared_ptr<MoonlightEnvState> state;
    std::shared_ptr<AsyncRequestControl> control;
    MoonlightBridgeRequest request;
    MoonlightBridgeResult result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void setTerminalResult(RequestAsyncData& data, MoonlightBridgeCode code) {
    data.result.operation = data.control == nullptr
                                ? data.request.operation
                                : data.control->operation;
    data.result.key = data.control == nullptr ? data.request.key : data.control->key;
    data.result.code = code;
    data.result.terminalStage = code == MoonlightBridgeCode::Cancelled ||
                                       code == MoonlightBridgeCode::ShuttingDown
                                   ? MoonlightBridgeTerminalStage::Cancelled
                                   : MoonlightBridgeTerminalStage::Failed;
    data.result.preflightTruth = MoonlightBridgeTruth::Failed;
}

void removePending(const std::shared_ptr<MoonlightEnvState>& state,
                   const std::shared_ptr<AsyncRequestControl>& control) noexcept {
    if (state == nullptr || control == nullptr) {
        return;
    }
    try {
        std::lock_guard<std::mutex> lock(state->pendingMutex);
        const auto iterator = state->pending.find(control->key);
        if (iterator != state->pending.end() && iterator->second == control) {
            state->pending.erase(iterator);
        }
    } catch (...) {
        // Teardown must remain noexcept even under allocation/runtime failure.
    }
}

void executeRequestAsync(napi_env /*env*/, void* rawData) noexcept {
    auto* data = static_cast<RequestAsyncData*>(rawData);
    if (data == nullptr || data->state == nullptr || data->control == nullptr ||
        data->state->bridge == nullptr) {
        return;
    }
    try {
        data->control->phase.store(AsyncRequestPhase::Executing,
                                   std::memory_order_release);
        if (data->state->closing.load(std::memory_order_acquire)) {
            setTerminalResult(*data, MoonlightBridgeCode::ShuttingDown);
        } else {
            data->result = data->state->bridge->execute(
                std::move(data->request), [control = data->control]() {
                    return control->cancellationRequested.load(
                        std::memory_order_acquire);
                });
        }
    } catch (...) {
        setTerminalResult(*data, MoonlightBridgeCode::ProtocolFailure);
    }
    if (data->control != nullptr) {
        data->control->phase.store(AsyncRequestPhase::ResultReady,
                                   std::memory_order_release);
    }
}

void completeRequestAsync(napi_env env, napi_status status, void* rawData) noexcept {
    auto* data = static_cast<RequestAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (data->control != nullptr) {
        data->control->phase.store(AsyncRequestPhase::Completing,
                                   std::memory_order_release);
        data->control->work.store(nullptr, std::memory_order_release);
    }
    removePending(data->state, data->control);
    if (data->state != nullptr &&
        !data->state->closing.load(std::memory_order_acquire)) {
        if (status != napi_ok) {
            setTerminalResult(*data, status == napi_cancelled
                                         ? MoonlightBridgeCode::Cancelled
                                         : MoonlightBridgeCode::ProtocolFailure);
        }
        try {
            napi_value value = createResult(env, data->result);
            (void)napi_resolve_deferred(env, data->deferred, value);
        } catch (...) {
            napi_value message = nullptr;
            napi_value error = nullptr;
            if (napi_create_string_utf8(env, "Moonlight result allocation failed",
                                        NAPI_AUTO_LENGTH, &message) == napi_ok &&
                napi_create_error(env, nullptr, message, &error) == napi_ok) {
                (void)napi_reject_deferred(env, data->deferred, error);
            }
        }
    }
    if (data->work != nullptr) {
        (void)napi_delete_async_work(env, data->work);
    }
    if (data->control != nullptr) {
        data->control->phase.store(AsyncRequestPhase::Completed,
                                   std::memory_order_release);
    }
    delete data;
}

napi_value getCapabilities(napi_env env, napi_callback_info /*info*/) {
    const auto state = stateFor(env);
    if (state == nullptr || state->bridge == nullptr) {
        return createCapabilities(env, {});
    }
    return createCapabilities(env, state->bridge->capabilities());
}

napi_value requestAsyncImpl(napi_env env, napi_callback_info info) {
    std::size_t argc = 1U;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 1U) {
        napi_throw_type_error(env, "E-MOONLIGHT-REQUEST",
                              "exactly one Moonlight request is required");
        return nullptr;
    }
    auto state = stateFor(env);
    if (state == nullptr || state->bridge == nullptr ||
        state->closing.load(std::memory_order_acquire)) {
        napi_throw_error(env, "E-MOONLIGHT-SHUTDOWN", "Moonlight bridge is shutting down");
        return nullptr;
    }
    auto data = std::unique_ptr<RequestAsyncData>(
        new (std::nothrow) RequestAsyncData());
    if (data == nullptr) {
        napi_throw_error(env, "E-MOONLIGHT-ALLOC", "Moonlight request allocation failed");
        return nullptr;
    }
    std::string error;
    if (!parseRequest(env, args[0], data->request, error)) {
        napi_throw_type_error(env, "E-MOONLIGHT-REQUEST", error.c_str());
        return nullptr;
    }
    data->state = std::move(state);
    const auto key = data->request.key;
    data->control = std::make_shared<AsyncRequestControl>();
    data->control->key = key;
    data->control->operation = data->request.operation;
    {
        std::lock_guard<std::mutex> lock(data->state->pendingMutex);
        if (data->state->closing.load(std::memory_order_acquire) ||
            data->state->pending.find(key) != data->state->pending.end()) {
            napi_throw_error(env, "E-MOONLIGHT-BUSY",
                             "Moonlight request key is already pending");
            return nullptr;
        }
        data->state->pending.emplace(key, data->control);
    }
    napi_value promise = nullptr;
    if (napi_create_promise(env, &data->deferred, &promise) != napi_ok) {
        removePending(data->state, data->control);
        napi_throw_error(env, "E-MOONLIGHT-PROMISE", "Moonlight promise creation failed");
        return nullptr;
    }
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, "MoonlightRequestAsync", NAPI_AUTO_LENGTH,
                                &resource) != napi_ok ||
        napi_create_async_work(env, resource, resource, executeRequestAsync,
                               completeRequestAsync, data.get(), &data->work) != napi_ok) {
        removePending(data->state, data->control);
        napi_throw_error(env, "E-MOONLIGHT-WORK", "Moonlight work creation failed");
        return nullptr;
    }
    data->control->work.store(data->work, std::memory_order_release);
    setSafeInteger(env, promise, "requestId", key.requestId);
    setSafeInteger(env, promise, "generation", key.generation);
    setSafeInteger(env, promise, "ownerToken", key.ownerToken);
    if (napi_queue_async_work(env, data->work) != napi_ok) {
        data->control->work.store(nullptr, std::memory_order_release);
        (void)napi_delete_async_work(env, data->work);
        removePending(data->state, data->control);
        napi_throw_error(env, "E-MOONLIGHT-QUEUE", "Moonlight work queue failed");
        return nullptr;
    }
    (void)data.release();
    return promise;
}

napi_value requestAsync(napi_env env, napi_callback_info info) {
    try {
        return requestAsyncImpl(env, info);
    } catch (...) {
        napi_throw_error(env, "E-MOONLIGHT-ALLOC",
                         "Moonlight request could not be admitted");
        return nullptr;
    }
}

bool readKeyArgument(napi_env env, napi_callback_info info,
                     MoonlightBridgeRequestKey& key) {
    std::size_t argc = 1U;
    napi_value args[1] = {nullptr};
    std::string error;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 1U || !parseRequestKey(env, args[0], key, error)) {
        napi_throw_type_error(env, "E-MOONLIGHT-KEY",
                              error.empty() ? "exact request key is required" : error.c_str());
        return false;
    }
    return true;
}

napi_value cancelRequest(napi_env env, napi_callback_info info) {
    MoonlightBridgeRequestKey key;
    if (!readKeyArgument(env, info, key)) {
        return nullptr;
    }
    const auto state = stateFor(env);
    bool cancelled = false;
    if (state != nullptr && state->bridge != nullptr) {
        std::shared_ptr<AsyncRequestControl> control;
        {
            std::lock_guard<std::mutex> lock(state->pendingMutex);
            const auto iterator = state->pending.find(key);
            if (iterator != state->pending.end()) {
                control = iterator->second;
            }
        }
        if (control != nullptr) {
            const auto phase = control->phase.load(std::memory_order_acquire);
            bool expected = false;
            if (phase <= AsyncRequestPhase::Executing &&
                control->cancellationRequested.compare_exchange_strong(
                    expected, true, std::memory_order_acq_rel)) {
                cancelled = true;
                (void)state->bridge->cancel(key);
            }
        }
    }
    napi_value result = nullptr;
    (void)napi_get_boolean(env, cancelled, &result);
    return result;
}

napi_value cancelOwner(napi_env env, napi_callback_info info) {
    std::size_t argc = 1U;
    napi_value args[1] = {nullptr};
    std::uint64_t ownerToken = 0U;
    std::string error;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 1U || !readSafeIntegerValue(env, args[0], false, ownerToken, error)) {
        napi_throw_type_error(env, "E-MOONLIGHT-OWNER", "valid owner token is required");
        return nullptr;
    }
    const auto state = stateFor(env);
    std::size_t count = 0U;
    if (state != nullptr && state->bridge != nullptr) {
        {
            std::lock_guard<std::mutex> lock(state->pendingMutex);
            for (const auto& item : state->pending) {
                if (item.first.ownerToken != ownerToken ||
                    item.second->phase.load(std::memory_order_acquire) >
                        AsyncRequestPhase::Executing) {
                    continue;
                }
                bool expected = false;
                if (item.second->cancellationRequested.compare_exchange_strong(
                        expected, true, std::memory_order_acq_rel)) {
                    ++count;
                }
            }
        }
        (void)state->bridge->cancelOwner(ownerToken);
    }
    napi_value result = nullptr;
    (void)napi_create_double(env, static_cast<double>(count), &result);
    return result;
}

napi_value pollEvents(napi_env env, napi_callback_info info) {
    std::size_t argc = 3U;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 1U || argc > 3U) {
        napi_throw_type_error(env, "E-MOONLIGHT-EVENTS", "invalid event poll arguments");
        return nullptr;
    }
    std::string error;
    std::uint64_t ownerToken = 0U;
    std::uint64_t afterSequence = 0U;
    std::uint64_t limit = 64U;
    if (!readSafeIntegerValue(env, args[0], false, ownerToken, error) ||
        (argc >= 2U && !readSafeIntegerValue(env, args[1], true,
                                             afterSequence, error)) ||
        (argc >= 3U && !readSafeIntegerValue(env, args[2], false, limit, error)) ||
        limit > 128U) {
        napi_throw_type_error(env, "E-MOONLIGHT-EVENTS", "invalid event poll bounds");
        return nullptr;
    }
    const auto state = stateFor(env);
    const auto events = state == nullptr || state->bridge == nullptr
                            ? std::vector<MoonlightBridgeEvent> {}
                            : state->bridge->pollEvents(ownerToken, afterSequence,
                                                       static_cast<std::size_t>(limit));
    napi_value result = nullptr;
    (void)napi_create_array_with_length(env, events.size(), &result);
    for (std::size_t index = 0U; index < events.size(); ++index) {
        (void)napi_set_element(env, result, static_cast<std::uint32_t>(index),
                               createEvent(env, events[index]));
    }
    return result;
}

bool parseStreamStartRequest(napi_env env, napi_value value,
                             MoonlightProductStreamStartRequest& request,
                             std::string& error) {
    static const std::unordered_set<std::string> allowed {
        "launchKey", "hostId", "serverUuid", "appId", "rendererHandle",
        "surfaceWidth", "surfaceHeight"
    };
    if (!readExactObject(env, value, allowed, error)) { return false; }
    bool present = false;
    napi_value nested = nullptr;
    std::uint64_t appId = 0U;
    std::uint64_t rendererHandle = 0U;
    std::uint64_t width = 0U;
    std::uint64_t height = 0U;
    if (!hasProperty(env, value, "launchKey", present) || !present ||
        !getProperty(env, value, "launchKey", nested) ||
        !parseRequestKey(env, nested, request.launchKey, error) ||
        !readRequiredString(env, value, "hostId", kMaxIdentityBytes,
                            request.hostId, error) ||
        !readRequiredString(env, value, "serverUuid", kMaxIdentityBytes,
                            request.serverUuid, error) ||
        !readRequiredSafeInteger(env, value, "appId", false, appId, error) ||
        !readRequiredSafeInteger(env, value, "rendererHandle", false,
                                 rendererHandle, error) ||
        !readRequiredSafeInteger(env, value, "surfaceWidth", false, width, error) ||
        !readRequiredSafeInteger(env, value, "surfaceHeight", false, height, error) ||
        appId > std::numeric_limits<std::uint32_t>::max() ||
        rendererHandle > static_cast<std::uint64_t>(kMaxSafeInteger) ||
        width > 16384U || height > 16384U) {
        return false;
    }
    request.appId = static_cast<std::uint32_t>(appId);
    request.rendererHandle = static_cast<std::int64_t>(rendererHandle);
    request.surfaceWidth = static_cast<std::int32_t>(width);
    request.surfaceHeight = static_cast<std::int32_t>(height);
    return true;
}

napi_value startStream(napi_env env, napi_callback_info info) {
    std::size_t argc = 1U;
    napi_value args[1] = {nullptr};
    MoonlightProductStreamStartRequest request;
    std::string error;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 1U || !parseStreamStartRequest(env, args[0], request, error)) {
        napi_throw_type_error(env, "E-MOONLIGHT-STREAM-START",
                              error.empty() ? "invalid stream start request" : error.c_str());
        return nullptr;
    }
    const auto result = MoonlightProductStreamingRuntime::process().start(
        std::move(request));
    napi_value value = nullptr;
    (void)napi_create_object(env, &value);
    setBoolean(env, value, "accepted", result.accepted);
    setString(env, value, "code", result.code);
    setSafeInteger(env, value, "sessionId", result.key.sessionId);
    setSafeInteger(env, value, "generation", result.key.generation);
    setSafeInteger(env, value, "ownerToken", result.key.ownerToken);
    return value;
}

napi_value streamSnapshot(napi_env env, napi_callback_info info) {
    MoonlightBridgeRequestKey key;
    if (!readKeyArgument(env, info, key)) { return nullptr; }
    const auto result = MoonlightProductStreamingRuntime::process().snapshot(key);
    napi_value value = nullptr;
    (void)napi_create_object(env, &value);
    setBoolean(env, value, "matched", result.matched);
    setString(env, value, "code", result.code);
    setSafeInteger(env, value, "sessionId", result.key.sessionId);
    setSafeInteger(env, value, "generation", result.key.generation);
    setSafeInteger(env, value, "ownerToken", result.key.ownerToken);
    setBoolean(env, value, "transportReady", result.transportReady);
    setBoolean(env, value, "firstFrameReady", result.firstFrameReady);
    setBoolean(env, value, "terminal", result.terminal);
    setSafeInteger(env, value, "lastSequence", result.lastSequence);
    return value;
}

napi_value stopStream(napi_env env, napi_callback_info info) {
    MoonlightBridgeRequestKey key;
    if (!readKeyArgument(env, info, key)) { return nullptr; }
    const bool stopped = MoonlightProductStreamingRuntime::process().stop(key);
    napi_value value = nullptr;
    (void)napi_get_boolean(env, stopped, &value);
    return value;
}

} // namespace

namespace MoonlightNapi {

napi_value Init(napi_env env, napi_value exports) {
    try {
        auto state = std::make_shared<MoonlightEnvState>(env);
        bool inserted = false;
        {
            std::lock_guard<std::mutex> lock(gEnvMutex);
            const auto existing = gEnvStates.find(env);
            if (existing == gEnvStates.end()) {
                gEnvStates.emplace(env, state);
                inserted = true;
            } else {
                state = existing->second;
            }
        }
        if (inserted &&
            napi_add_env_cleanup_hook(env, cleanupEnvironment, state.get()) != napi_ok) {
            {
                std::lock_guard<std::mutex> lock(gEnvMutex);
                const auto iterator = gEnvStates.find(env);
                if (iterator != gEnvStates.end() && iterator->second == state) {
                    gEnvStates.erase(iterator);
                }
            }
            state->closing.store(true, std::memory_order_release);
            state->bridge->shutdown();
        }
    } catch (...) {
        // The exports below remain callable and fail closed without env state.
    }

    napi_property_descriptor descriptors[] = {
        {"moonlightGetBridgeCapabilities", nullptr, getCapabilities, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"moonlightRequestAsync", nullptr, requestAsync, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"moonlightCancelRequest", nullptr, cancelRequest, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"moonlightCancelOwner", nullptr, cancelOwner, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"moonlightPollEvents", nullptr, pollEvents, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"moonlightStartStream", nullptr, startStream, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"moonlightGetStreamSnapshot", nullptr, streamSnapshot, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"moonlightStopStream", nullptr, stopStream, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    (void)napi_define_properties(env, exports,
                                 sizeof(descriptors) / sizeof(descriptors[0]),
                                 descriptors);
    return exports;
}

} // namespace MoonlightNapi
