/**
 * NativeCallbackEntryIntegration — ohosTest-only NAPI carrier.
 *
 * The callback cases themselves live in the shared production-entry test
 * source entry/src/main/cpp/test/callback_entry_integration_test.cpp.  This
 * addon only adapts that registered native suite to an application-namespace
 * Hypium call; it does not add an entry point to the production NAPI module.
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include "../../main/cpp/test/test_runner.h"

namespace {

napi_value MakeInt32(napi_env env, int32_t value) {
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeString(napi_env env, const char* value) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value) {
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value RunProductionCallbackEntries(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
    if (argc != 0) {
        napi_throw_type_error(env, nullptr,
                              "runProductionCallbackEntries takes no arguments");
        return nullptr;
    }

    const int32_t registered = static_cast<int32_t>(testRegistry().size());
    std::vector<RdpTestCaseResult> cases;
    cases.reserve(testRegistry().size());
    const int runnerFailures = runAllTests(&cases);
    int32_t passed = 0;
    int32_t failed = 0;
    for (const auto& testCase : cases) {
        if (testCase.passed) {
            ++passed;
        } else {
            ++failed;
        }
    }
    // An unbound callback is a harness failure rather than a successful
    // case. Keep the nine real registrations intact, but make the NAPI
    // summary fail closed if the runner observed an orphan diagnostic that
    // cannot be attributed to one of those cases.
    if (runnerFailures > failed) {
        failed = runnerFailures;
    }
    OH_LOG_INFO(LOG_APP,
                "[NativeCallbackEntryIntegration] registered=%{public}d passed=%{public}d failed=%{public}d",
                registered, passed, failed);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "suite",
                            MakeString(env, "NativeCallbackEntryIntegration"));
    napi_set_named_property(env, result, "registered",
                            MakeInt32(env, registered));
    napi_set_named_property(env, result, "passed", MakeInt32(env, passed));
    napi_set_named_property(env, result, "failed", MakeInt32(env, failed));
    napi_set_named_property(env, result, "applicationNamespace",
                            MakeString(env, "ohosTest"));
    napi_value caseArray = nullptr;
    napi_create_array_with_length(env, cases.size(), &caseArray);
    for (size_t index = 0; index < cases.size(); ++index) {
        napi_value caseResult = nullptr;
        napi_create_object(env, &caseResult);
        napi_set_named_property(env, caseResult, "name",
                                MakeString(env, cases[index].name.c_str()));
        napi_set_named_property(env, caseResult, "passed",
                                MakeBool(env, cases[index].passed));
        napi_set_named_property(env, caseResult, "failure",
                                MakeString(env, cases[index].failure.c_str()));
        napi_set_element(env, caseArray, index, caseResult);
    }
    napi_set_named_property(env, result, "cases", caseArray);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor property {
        "runProductionCallbackEntries",
        nullptr,
        RunProductionCallbackEntries,
        nullptr,
        nullptr,
        nullptr,
        napi_default,
        nullptr,
    };
    napi_define_properties(env, exports, 1, &property);
    return exports;
}

} // namespace

NAPI_MODULE(native_callback_entry_integration, Init)
