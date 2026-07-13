# ohosTest build recovery

Date: 2026-07-13

## Root cause

`default@OhosTestBuildArkTS` is the SDK's legacy webpack task. It does not receive the HarmonyOS extension API path, so imports of `@kit.UIDesignKit`, `@kit.AccountKit`, and `@kit.ScanKit` fail. Its error path then triggers a secondary DevEco SourceMap `share` exception.

## Repair

- Rewrote the `HdsTabs` declaration to keep the existing modifier values before the content block, which is accepted by the test compiler without changing the mobile/Pad immersive floating bottom bar.
- Declared both module targets as `runtimeOS: "HarmonyOS"` to match the product configuration explicitly.
- Replaced four stale `RemoteHost.isFavorite` cloud-sync test assertions with persisted `groupId` assertions. The former model field was intentionally removed and must not be restored just to satisfy tests.
- Adopted `default@OhosTestCompileArkTS` as the ArkTS test compilation gate. The old `default@OhosTestBuildArkTS` task is not a valid HarmonyOS extension-Kit gate in this SDK release.

## Verification

| Check | Result |
| --- | --- |
| `default@OhosTestCompileArkTS` | Passed in 7.4 s after the final changes; successfully compiled `HostListPage`, including `HdsTabs` and the HarmonyOS Kit imports. |
| `onDeviceTest` test-module compilation | `ohosTest@OhosTestCompileArkTS` passed in 9.6 s after the test update. |
| Production `assembleHap` | Passed in 16.2 s after the final changes. |

The `onDeviceTest` outer command exceeded the tool's 64-second execution window while starting the remaining device workflow. Its test-HAP compilation, packaging, and signing all completed; no ArkTS, HDS, SourceMap, or stale-model error remained.
