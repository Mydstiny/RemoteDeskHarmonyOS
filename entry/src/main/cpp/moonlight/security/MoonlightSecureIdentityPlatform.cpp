#include "MoonlightSecureIdentity.h"

#include <asset/asset_api.h>
#include <huks/native_huks_api.h>
#include <huks/native_huks_type.h>

#include <memory>

namespace remotedesk::moonlight {
namespace {

static_assert(OH_HUKS_MAX_KEY_ALIAS_LEN == MOONLIGHT_HUKS_ALIAS_LIMIT,
              "Moonlight identity aliases must fit the API-23 HUKS limit");
static_assert(MOONLIGHT_ASSET_SECRET_LIMIT < 1024U,
              "Asset Store accepts only sensitive data shorter than 1024 bytes");
static_assert(OH_HUKS_ALG_RSA != 0 && OH_HUKS_RSA_KEY_SIZE_2048 == 2048 &&
                  OH_HUKS_DIGEST_SHA256 != 0 &&
                  OH_HUKS_PADDING_PKCS1_V1_5 != 0 &&
                  OH_HUKS_KEY_PURPOSE_SIGN != 0,
              "API-23 HUKS must expose the Moonlight RSA signer primitives");
static_assert(OH_HUKS_ALG_AES != 0 && OH_HUKS_MODE_GCM != 0 &&
                  OH_HUKS_KEY_PURPOSE_ENCRYPT != 0 &&
                  OH_HUKS_KEY_PURPOSE_DECRYPT != 0,
              "API-23 HUKS must expose AES-GCM wrapping primitives");
static_assert(ASSET_TAG_SECRET != 0 && ASSET_TAG_ALIAS != 0 &&
                  ASSET_TAG_RETURN_TYPE != 0,
              "API-23 Asset Store metadata tags are required");

template <typename Function>
bool linked(Function* function) noexcept {
    return function != nullptr;
}

class UnavailablePlatformIdentityBackend final
    : public MoonlightIdentityBackend {
public:
    MoonlightIdentityCapability capability() const noexcept override {
        MoonlightIdentityCapability result;
        result.status =
            MoonlightIdentityCapabilityStatus::RuntimeProofRequired;
        result.storageMode =
            MoonlightIdentityStorageMode::HuksWrappedPkcs8;
        result.huksApiLinked = true;
        result.assetApiLinked = true;
        result.directRsaTlsSignerReady = false;
        result.wrappedPkcs8Ready = false;
        result.encryptedBlobAtomic = false;
        result.huksAliasLimit = OH_HUKS_MAX_KEY_ALIAS_LEN;
        result.assetSecretLimit = MOONLIGHT_ASSET_SECRET_LIMIT;
        return result;
    }

    MoonlightIdentityBackendLoadResult load(
        const std::string& alias) noexcept override {
        static_cast<void>(alias);
        return {};
    }

    MoonlightIdentityBackendCode store(
        const MoonlightIdentityStoredRecord& record,
        bool replaceExisting) noexcept override {
        static_cast<void>(record);
        static_cast<void>(replaceExisting);
        return MoonlightIdentityBackendCode::Unavailable;
    }

    MoonlightIdentityBackendCode erase(
        const std::string& alias) noexcept override {
        static_cast<void>(alias);
        return MoonlightIdentityBackendCode::Unavailable;
    }

    MoonlightIdentityBackendListResult list(
        const std::string& ownerScopeFingerprint) noexcept override {
        static_cast<void>(ownerScopeFingerprint);
        return {};
    }
};

} // namespace

std::unique_ptr<MoonlightIdentityBackend>
createMoonlightPlatformIdentityBackend() {
    // A compile/link receipt cannot prove AppSpawn access, hardware-backed
    // key semantics, TLS provider integration, or atomic encrypted-blob
    // persistence. Keep product capability closed until an in-HAP runtime
    // backend proves the complete contract.
    return std::make_unique<UnavailablePlatformIdentityBackend>();
}

bool moonlightSecureIdentityPlatformCompileProbe() noexcept {
    return linked(&OH_Huks_GenerateKeyItem) &&
           linked(&OH_Huks_ExportPublicKeyItem) &&
           linked(&OH_Huks_DeleteKeyItem) && linked(&OH_Huks_InitSession) &&
           linked(&OH_Huks_UpdateSession) && linked(&OH_Huks_FinishSession) &&
           linked(&OH_Huks_AbortSession) && linked(&OH_Asset_Add) &&
           linked(&OH_Asset_Query) && linked(&OH_Asset_Remove) &&
           linked(&OH_Asset_FreeResultSet);
}

} // namespace remotedesk::moonlight
