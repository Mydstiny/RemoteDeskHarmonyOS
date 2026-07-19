# Data, Cloud Sync, Backup, and File Integrity Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate data rollback, stale-password shadowing, plaintext secret upload, incomplete backup/restore, duplicate UI refresh, and file-transfer residue while preserving the existing Huawei cloud schemas and all recoverable user data.

**Architecture:** The local RDB becomes the only authoritative runtime source, with one canonical storage location for every field and a transactional extension store only for fields absent from existing cloud tables. A single sync coordinator owns cloud operations and durable mutation state; encryption, backup, and secure credentials receive explicit state machines that fail closed instead of silently writing plaintext or reporting false success. All service snapshots are immutable and revisioned so one successful mutation produces one visible refresh.

**Tech Stack:** HarmonyOS NEXT API 23, ArkTS/ArkUI, ArkData relationalStore and cloudSync, CryptoArchitectureKit/HUKS-compatible secure storage, CoreFileKit, Hypium, native C++/RustDesk FFI where streaming transfer requires it, PowerShell release gates.

## Global Constraints

- Use only `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`; do not create a persistent worktree.
- Do not add, delete, rename, or change the type of any Huawei cloud-table column.
- Preserve existing cloud rows and local data; every migration must be idempotent, resumable, and rollback-safe.
- Preserve unrelated dirty files and stage only files explicitly owned by the current task.
- Never use `git add -A`, `git reset --hard`, `git checkout --`, force-push, or direct push to `main`.
- Never log passwords, private keys, TOTP secrets, relay keys, access tokens, backup passphrases, or unmasked host/user identity.
- A local data mutation is successful only after every required local row is committed; cloud upload may be asynchronous but must have a durable dirty record.
- A cloud callback may refresh UI only after a completed cloud-first operation has produced a validated local snapshot.
- A configured-but-locked encryption state must never fall back to plaintext storage or upload.
- Local backup restore and manual cloud download must be atomic and must never automatically upload restored data.
- The existing `remotehosts.passward` spelling remains the cloud contract.
- Pro access tokens remain device-local and must not enter `rustdeskrelays.accountsjson` or an unencrypted backup.
- Validate new HarmonyOS APIs against the local API 23 documentation before implementation.
- Minimum ArkTS/UI verification: targeted tests, `default@OhosTestCompileArkTS`, `assembleHap`, `git diff --check`, and Light compliance.
- Data migration, encryption, cloud, backup, and secure-storage changes require real-device validation on device `38451` before completion.

---

## 1. Confirmed Defects and Required Outcomes

| Area | Confirmed defect | Required outcome |
|---|---|---|
| RustDesk remembered password | `passward` and `localextensions.password` can diverge; the extension shadows the canonical row | One canonical password value; successful auth visibly reports persistence failure; restart preserves the remembered value |
| Local extension writes | Extension failures are ignored after the main row succeeds | Main row and required extension commit in one transaction or both roll back |
| Encryption lock | Locked DEK paths return plaintext and can trigger cloud upload | Locked secret mutations are rejected with `unlock_required`; no plaintext reaches RDB or cloud |
| Encryption disable/reset | Disable decrypts `password`, while runtime reads `passward`; extensions are not decrypted or wiped | Every sensitive location is transformed or wiped atomically before crypto parameters change |
| Startup unlock | Services can cache encrypted strings and are not reloaded after unlock | Locked data never enters usable models; successful unlock publishes one decrypted snapshot |
| RDP credentials | Username is local-only while password is cloud-synced | Existing cloud schema carries a versioned credential envelope or UI explicitly blocks incomplete cross-device use |
| Pro credentials | Token JSON is stored in ordinary Preferences and persistence errors are swallowed | Keystore-backed secure storage with explicit result/error handling |
| Backup | Raw JSON may contain plaintext secrets; no read-size cap or complete-write verification | Version 3 backup with bounded I/O, authenticated encryption, scope manifest, verification, and rollback |
| Imports | TOTP CSV accepts invalid Base32; errors are inconsistent | Shared bounded reader and format-specific validation with actionable errors |
| File transfer | Same-name files overwrite, staging files leak, RustDesk buffers 100 MB, live tasks can remain active | Unique names, cleanup lifecycle, streaming/chunking, and exactly-once task completion |
| Refresh | startup `load`, listeners, and `whenReady` can render the same state twice | One immutable snapshot revision produces one UI refresh |
| Tests | Adapter pure functions pass while production RDB paths are untested | Real production-path RDB, migration, encryption, cloud sequencing, backup, and device tests |

---

## 2. Target Data Ownership

| Data | Canonical local source | Cloud representation | Device-local extension/security |
|---|---|---|---|
| Host password | `remotehosts.passward` only | `remotehosts.passward` | none |
| SSH key passphrase | secure local extension | not synced | encrypted extension |
| SSH/RDP trust records | canonical host extension payload | versioned `displayconfig._remoteDeskExtensionV2` | same transactional extension cache |
| RustDesk direct/Pro bindings | canonical host extension payload | `displayconfig._remoteDeskExtensionV2` | local cache with revision |
| RDP credential | canonical credential model | versioned payload in existing `password` field, encrypted as one unit | none after migration |
| SSH private key | `sshkeys.privatekey` | existing `privatekey` | format metadata may be derived or transactionally cached |
| TOTP secret | `totpentries.secret` | existing `secret` | none |
| Relay credentials/key | `rustdeskrelays` | existing columns/accounts JSON | Pro token excluded |
| Pro token/device identity | secure credential store | metadata only in `accountsjson` | HUKS/keystore-backed ciphertext |
| Settings | Preferences/AppStorage mirror of `usersettings` snapshot | existing `payload` | non-syncable session/device keys stay Preferences-only |
| Transfer staging | app-private transfer registry | never synced | cleanup journal and bounded temporary files |

The implementation must not introduce another secret shadow copy. A value may be cached only when the cache carries the same revision and cannot override a newer canonical row.

---

## 3. Planned File Structure

### New focused files

- `entry/src/main/ets/services/DataMutationResult.ets`: typed mutation/error results shared by services and UI.
- `entry/src/main/ets/services/SensitiveDataStatePolicy.ets`: pure encryption-state and write/sync gate decisions.
- `entry/src/main/ets/services/SensitiveDataMigrationPolicy.ets`: canonical column/extension migration decisions.
- `entry/src/main/ets/services/RdpCredentialCloudEnvelope.ets`: versioned username/password envelope using the existing cloud column.
- `entry/src/main/ets/services/SecureCredentialStore.ets`: device-local protected Pro token/device identity persistence.
- `entry/src/main/ets/services/DataSnapshotRevisionPolicy.ets`: immutable snapshot signatures/revisions and notification deduplication.
- `entry/src/main/ets/services/BackupCryptoPolicy.ets`: v3 backup key derivation, AEAD envelope metadata, and validation.
- `entry/src/main/ets/services/BoundedDocumentIo.ets`: bounded complete-read/complete-write CoreFileKit helper.
- `entry/src/main/ets/services/TransferStagingService.ets`: unique naming, journal, cleanup, and lifecycle ownership.
- Matching tests under `entry/src/test/` for each pure policy/service boundary.

### Existing files to modify

- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/main/ets/services/CloudTableAdapter.ets`
- `entry/src/main/ets/services/CloudSyncCoordinator.ets`
- `entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets`
- `entry/src/main/ets/services/CloudSyncSelectionPolicy.ets`
- `entry/src/main/ets/services/HostSyncService.ets`
- `entry/src/main/ets/services/HostSyncMergePolicy.ets`
- `entry/src/main/ets/services/KeyVaultService.ets`
- `entry/src/main/ets/services/DataCrypto.ets`
- `entry/src/main/ets/services/RustDeskProCredentialStore.ets`
- `entry/src/main/ets/services/RustDeskProSyncService.ets`
- `entry/src/main/ets/services/LocalBackupPolicy.ets`
- `entry/src/main/ets/services/LocalBackupService.ets`
- `entry/src/main/ets/services/SshKeyImportService.ets`
- `entry/src/main/ets/services/TotpImportService.ets`
- `entry/src/main/ets/services/RustDeskRelayImportService.ets`
- `entry/src/main/ets/services/FileTransferLiveTaskService.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/entryability/EntryAbility.ets`
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- RustDesk FFI files only if the current send API cannot accept bounded chunks.

### Legacy code to remove after proving no callers

- `entry/src/main/ets/services/CloudSyncService.ets`: unused REST sync path that serializes complete models outside the canonical cloud adapter.

---

### Task 1: Lock down production-path regression tests before migration

**Files:**
- Create: `entry/src/test/SensitiveDataStatePolicy.test.ets`
- Create: `entry/src/test/SensitiveDataMigrationPolicy.test.ets`
- Create: `entry/src/test/RdpCredentialCloudEnvelope.test.ets`
- Modify: `entry/src/test/CloudStore.test.ets`
- Modify: `entry/src/test/CloudTableAdapter.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces executable specifications for every later task.
- No production behavior changes in this task.

- [ ] **Step 1: Add a failing remembered-password precedence test**

Create a production-path fixture with `passward = new-secret` and a legacy `localextensions.password = old-secret`; assert the loaded host uses `new-secret` and marks the shadow field for removal.

- [ ] **Step 2: Add failing encryption-state tests**

Specify exact decisions:

```ts
expect(secretWriteDecision('disabled')).assertEqual('allow_plain_local');
expect(secretWriteDecision('unlocked')).assertEqual('allow_encrypted');
expect(secretWriteDecision('locked')).assertEqual('reject_unlock_required');
expect(secretCloudSyncDecision('disabled')).assertEqual('reject_encryption_required');
expect(secretCloudSyncDecision('unlocked')).assertEqual('allow');
```

- [ ] **Step 3: Add failing disable/reset coverage**

Assert that the sensitive inventory contains `remotehosts.passward`, SSH key data/passphrase, RDP credential envelope, relay API password/key/accounts, SSH private key, TOTP secret, secure Pro credentials, and sensitive extension rows. Assert no `password`/`passward` ambiguity remains.

- [ ] **Step 4: Add failing production-adapter wiring tests**

Replace tests that call only `projectLocalRow()` with tests against the bucket/row conversion interface actually consumed by `CloudStore`. The test must fail if a helper is dead code.

- [ ] **Step 5: Run RED gate**

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --daemon
```

Expected: new tests fail because the policies and canonical production adapter do not exist.

- [ ] **Step 6: Commit test specifications only**

```powershell
git add -- entry/src/test/SensitiveDataStatePolicy.test.ets entry/src/test/SensitiveDataMigrationPolicy.test.ets entry/src/test/RdpCredentialCloudEnvelope.test.ets entry/src/test/CloudStore.test.ets entry/src/test/CloudTableAdapter.test.ets entry/src/test/List.test.ets
git commit -m "test(data): specify canonical persistence and encryption gates"
```

---

### Task 2: Introduce typed mutation results and transactional record writes

**Files:**
- Create: `entry/src/main/ets/services/DataMutationResult.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/services/KeyVaultService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Create: `entry/src/test/DataMutationResult.test.ets`
- Modify: `entry/src/test/CloudStore.test.ets`
- Modify: `entry/src/test/HostSyncService.test.ets`
- Modify: `entry/src/test/KeyVaultService.test.ets`

**Interfaces:**
- Produces `DataMutationCode = 'ok' | 'not_ready' | 'not_found' | 'unchanged' | 'unlock_required' | 'local_write_failed' | 'extension_write_failed' | 'sync_deferred'`.
- Produces `DataMutationResult { ok: boolean; code: DataMutationCode; recordId: string; message: string }`.
- Produces transactional `CloudStore.mutateHost(host, mode): DataMutationResult` and equivalent credential/key operations.

- [ ] **Step 1: Write failing transaction tests**

Inject failures for main-row update, extension update, and commit. Assert that no partial row survives and that `updatedat` advances only after a successful transaction.

- [ ] **Step 2: Implement one-record transaction ownership**

For host/RDP credential/SSH key operations: begin one RDB transaction, write the canonical row, write/delete required extensions, update the durable mutation journal, commit, then return `ok`. On any error, roll back and return the exact failure code.

- [ ] **Step 3: Stop ignoring persistence results**

`confirmRustDeskProPreflight()` and `persistRustDeskSessionAuth()` must keep the authenticated session alive but show `设备密码已用于本次连接，但保存失败` when persistence fails. They must never log or imply `passwordSaved=true` without an `ok` result.

- [ ] **Step 4: Preserve one visible service event**

Publish the new immutable service snapshot only after commit. Do not emit from both the inner CloudStore write and service wrapper.

- [ ] **Step 5: Run targeted tests and ArkTS compile**

Expected: transaction rollback and error-propagation tests pass.

- [ ] **Step 6: Commit Task 2 files**

```powershell
git add -- entry/src/main/ets/services/DataMutationResult.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/services/KeyVaultService.ets entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/test/DataMutationResult.test.ets entry/src/test/CloudStore.test.ets entry/src/test/HostSyncService.test.ets entry/src/test/KeyVaultService.test.ets
git commit -m "refactor(data): make local mutations transactional"
```

---

### Task 3: Remove password shadowing and migrate legacy local extensions

**Files:**
- Create: `entry/src/main/ets/services/SensitiveDataMigrationPolicy.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/CloudTableAdapter.ets`
- Modify: `entry/src/main/ets/services/HostSyncMergePolicy.ets`
- Test: `entry/src/test/SensitiveDataMigrationPolicy.test.ets`
- Test: `entry/src/test/CloudTableAdapter.test.ets`

**Interfaces:**
- Produces `canonicalHostPassword(passward, legacyPassword, extensionPassword): PasswordMigrationDecision`.
- Produces local schema marker `canonical_secret_storage_version = 1` in a device-local metadata table or Preferences, not a cloud table.

- [ ] **Step 1: Specify precedence and recovery rules**

Use these exact rules:

1. Non-empty valid `passward` wins.
2. If `passward` is empty and legacy `password` is non-empty, copy legacy value into `passward`.
3. Use extension password only when both canonical columns are empty and the extension value is valid.
4. Never replace a non-empty canonical value with an extension value.
5. After successful canonical write, delete `password` from that extension payload.

- [ ] **Step 2: Implement idempotent migration in one transaction**

Snapshot affected host IDs and ciphertext hashes, migrate values, remove password shadows, verify row count and hashes, then set the migration marker. A crash before the marker must safely rerun.

- [ ] **Step 3: Stop writing password to `localextensions`**

Remove `password` from `hostExtensionValues`, `hostExtensionFromResult`, and `mergeHostExtension`. Keep `sshkeypassphrase` device-local.

- [ ] **Step 4: Make production conversion use one adapter**

`CloudStore` must consume the same adapter interface tested by `CloudTableAdapter.test.ets`; remove or stop exporting unused projection helpers.

- [ ] **Step 5: Verify legacy and current databases**

Test empty/non-empty combinations, encrypted values, failed migration rollback, repeat startup, and backup-restored v1/v2 extensions.

- [ ] **Step 6: Commit Task 3 files**

```powershell
git add -- entry/src/main/ets/services/SensitiveDataMigrationPolicy.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/CloudTableAdapter.ets entry/src/main/ets/services/HostSyncMergePolicy.ets entry/src/test/SensitiveDataMigrationPolicy.test.ets entry/src/test/CloudTableAdapter.test.ets
git commit -m "fix(data): make passward the canonical host secret"
```

---

### Task 4: Make encryption fail closed and reload decrypted snapshots

**Files:**
- Create: `entry/src/main/ets/services/SensitiveDataStatePolicy.ets`
- Modify: `entry/src/main/ets/services/DataCrypto.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/CloudSyncCoordinator.ets`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Test: `entry/src/test/SensitiveDataStatePolicy.test.ets`

**Interfaces:**
- Produces `SensitiveDataState = 'disabled' | 'locked' | 'unlocked' | 'migration' | 'reset_pending'`.
- Produces `DataCrypto.onStateChange(listener)` and `CloudStore.reloadAfterCryptoTransition()`.
- Produces `encryptRequired(value): string` that throws/rejects when configured encryption is locked; no plaintext fallback.

- [ ] **Step 1: Add failing locked-write tests for every sensitive table**

Cover hosts, RDP credentials, relays/accounts, SSH keys, TOTP, and sensitive extensions. Assert zero RDB change, zero dirty-journal change, and `unlock_required`.

- [ ] **Step 2: Replace conditional plaintext encryption**

Remove `crypto.isReady() ? crypto.encrypt(value) : value` from sensitive bucket builders. Disabled encryption may write local plaintext, but selected cloud sync of sensitive tables must require encryption or an explicit one-time informed override recorded outside cloud data.

- [ ] **Step 3: Gate cloud selection and uploads**

When a user selects a sensitive table while encryption is disabled, open the encryption setup flow. When encryption is locked, queue no secret mutation and show an unlock sheet. `cryptoparams` being selected by itself must never be presented as proof that row data is encrypted.

- [ ] **Step 4: Reload services after unlock/disable/reset**

After a successful state transition, clear encrypted in-memory models, reload all affected rows through decrypting converters, calculate one new snapshot revision, and emit exactly one change event.

- [ ] **Step 5: Verify background/foreground behavior**

Background lock must preserve read-only card metadata while redacting secrets. Foreground edit/connect requiring a secret must prompt unlock before constructing a native session config.

- [ ] **Step 6: Commit Task 4 files**

```powershell
git add -- entry/src/main/ets/services/SensitiveDataStatePolicy.ets entry/src/main/ets/services/DataCrypto.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/CloudSyncCoordinator.ets entry/src/main/ets/entryability/EntryAbility.ets entry/src/main/ets/pages/HostListPage.ets entry/src/test/SensitiveDataStatePolicy.test.ets
git commit -m "fix(security): reject secret writes while encryption is locked"
```

---

### Task 5: Repair encryption disable, reset, and cross-device state transitions

**Files:**
- Modify: `entry/src/main/ets/services/DataCrypto.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/CloudSyncCoordinator.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Test: `entry/src/test/SensitiveDataMigrationPolicy.test.ets`
- Test: `entry/src/test/CloudSyncCoordinatorPolicy.test.ets`

**Interfaces:**
- Produces `transformAllSensitiveData(target: 'encrypted' | 'plaintext'): DataMutationResult`.
- Produces `wipeAllSensitiveData(): DataMutationResult`.

- [ ] **Step 1: Add a complete sensitive-location inventory test**

The test must fail if a new sensitive field is added to a model/bucket without being included in transform and wipe policies.

- [ ] **Step 2: Implement atomic disable**

Decrypt `remotehosts.passward` and every other sensitive column/extension in one transaction. Re-read and verify that no value begins with the encrypted prefix before changing `crypto_status` or deleting salt/verifier. If verification fails, roll back and keep the DEK.

- [ ] **Step 3: Implement atomic reset/wipe**

Delete business rows, sensitive local extensions, secure Pro credentials, transfer-staging secrets, retry records containing sensitive table state, and crypto parameters in a defined sequence. Non-sensitive preferences may remain. Notify services only after completion.

- [ ] **Step 4: Protect remote reset**

A cloud `reset` signal applies only after a successful confirmed cloud-first `cryptoparams` operation. Failure to clear any local sensitive store leaves the app in a blocked recovery state, not an apparently empty usable state.

- [ ] **Step 5: Verify interruption recovery**

Simulate failure after transform, before status write, after status write, and before cloud push. On restart, a transition journal must resume or roll back without losing the only decryptable copy.

- [ ] **Step 6: Commit Task 5 files**

```powershell
git add -- entry/src/main/ets/services/DataCrypto.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/CloudSyncCoordinator.ets entry/src/main/ets/pages/HostListPage.ets entry/src/test/SensitiveDataMigrationPolicy.test.ets entry/src/test/CloudSyncCoordinatorPolicy.test.ets
git commit -m "fix(security): make encryption transitions atomic"
```

---

### Task 6: Complete RDP credential and Pro credential persistence without cloud-schema changes

**Files:**
- Create: `entry/src/main/ets/services/RdpCredentialCloudEnvelope.ets`
- Create: `entry/src/main/ets/services/SecureCredentialStore.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/CloudTableAdapter.ets`
- Modify: `entry/src/main/ets/services/RustDeskProCredentialStore.ets`
- Modify: `entry/src/main/ets/services/RustDeskProSyncService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- Test: `entry/src/test/RdpCredentialCloudEnvelope.test.ets`
- Create: `entry/src/test/SecureCredentialStorePolicy.test.ets`

**Interfaces:**
- Produces `encodeRdpCredentialEnvelope(username, password): string` with prefix `rdcred:1:` and Base64URL JSON payload.
- Produces backward-compatible `decodeRdpCredentialEnvelope(value): { username; password; legacy }`.
- Produces `SecureCredentialStore.save/get/delete` returning typed results; ciphertext is bound to the app/device keystore.

- [ ] **Step 1: Test legacy and v1 credential envelopes**

Cover Unicode usernames, empty domain/user, malformed payload, legacy password-only values, encrypted outer values, and no secret content in logs.

- [ ] **Step 2: Add a rollout compatibility gate**

Before first envelope upload, show that older app versions may not understand the combined value. Record a local migration version and preserve legacy reads. Do not rewrite all credentials merely on startup; migrate on successful edit or explicit upgrade confirmation.

- [ ] **Step 3: Move Pro secrets to secure storage**

Store access token, device UUID/ID, and any refresh material in `SecureCredentialStore`; keep only account ID, relay ID, endpoint, username, display name, and status metadata in ordinary Preferences/cloud metadata.

- [ ] **Step 4: Propagate persistence errors to UI**

Login is not considered durable until secure storage succeeds. If persistence fails after remote login, attempt logout/revoke when supported, keep the add sheet open, and display a retryable error.

- [ ] **Step 5: Verify backup and logout boundaries**

Unencrypted backups exclude secure credentials. Encrypted backups include them only after explicit user opt-in. Logout deletes secure credentials before removing metadata and reports partial failure.

- [ ] **Step 6: Commit Task 6 files**

```powershell
git add -- entry/src/main/ets/services/RdpCredentialCloudEnvelope.ets entry/src/main/ets/services/SecureCredentialStore.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/CloudTableAdapter.ets entry/src/main/ets/services/RustDeskProCredentialStore.ets entry/src/main/ets/services/RustDeskProSyncService.ets entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/pages/RustDeskRelayPage.ets entry/src/test/RdpCredentialCloudEnvelope.test.ets entry/src/test/SecureCredentialStorePolicy.test.ets
git commit -m "fix(credentials): secure Pro tokens and complete RDP sync"
```

---

### Task 7: Harden cloud mutation journaling, conflict handling, and manual operations

**Files:**
- Modify: `entry/src/main/ets/services/CloudSyncCoordinator.ets`
- Modify: `entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/HostSyncMergePolicy.ets`
- Modify: `entry/src/main/ets/services/CloudSyncSelectionPolicy.ets`
- Modify: `entry/src/test/CloudSyncCoordinatorPolicy.test.ets`
- Modify: `entry/src/test/HostSyncMergePolicy.test.ets`

**Interfaces:**
- Produces durable `CloudMutationJournalEntry { table; recordId; operation; localRevision; createdAt; attempt }`.
- Produces cloud operation receipt containing direction, selected tables, start/end time, and failed tables without secret values.

- [ ] **Step 1: Test add/update/delete coalescing by record revision**

Verify `add→update` uploads latest row, `update→update` keeps latest revision, `add→delete` produces no phantom row, and `delete→add` creates a new current revision.

- [ ] **Step 2: Persist dirty intent in the same local transaction**

If the app is killed after local commit but before cloudSync starts, startup must upload the dirty revision before cloud-first pull. Clear journal entries only after the terminal successful progress callback for that revision.

- [ ] **Step 3: Remove extension side effects from row decoding**

Decoding cloud `displayconfig` must return a candidate extension and must not write it immediately. Merge and persistence occur only after conflict policy accepts the cloud snapshot.

- [ ] **Step 4: Strengthen manual download rollback**

Snapshot selected tables, dependent extensions, settings, journal, and secure metadata references. A failed table restores all of them and emits no intermediate UI snapshot.

- [ ] **Step 5: Strengthen manual upload protection**

Display selected-table row counts and block all-empty upload. Require encryption-ready state for sensitive tables. Manual upload must not bypass the mutation journal or table selection.

- [ ] **Step 6: Commit Task 7 files**

```powershell
git add -- entry/src/main/ets/services/CloudSyncCoordinator.ets entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/services/HostSyncMergePolicy.ets entry/src/main/ets/services/CloudSyncSelectionPolicy.ets entry/src/test/CloudSyncCoordinatorPolicy.test.ets entry/src/test/HostSyncMergePolicy.test.ets
git commit -m "fix(sync): journal durable record mutations"
```

---

### Task 8: Replace backup v2 with bounded authenticated backup v3

**Files:**
- Create: `entry/src/main/ets/services/BackupCryptoPolicy.ets`
- Create: `entry/src/main/ets/services/BoundedDocumentIo.ets`
- Modify: `entry/src/main/ets/services/LocalBackupPolicy.ets`
- Modify: `entry/src/main/ets/services/LocalBackupService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Create: `entry/src/test/BackupCryptoPolicy.test.ets`
- Create: `entry/src/test/BoundedDocumentIo.test.ets`
- Modify: `entry/src/test/LocalBackupPolicy.test.ets`

**Interfaces:**
- Produces backup v3 envelope with `format`, `version`, `createdAt`, `appVersion`, `scope`, `kdf`, `cipher`, `nonce`, `ciphertext`, and `sha256`.
- Uses a memory/work factor approved by API 23 availability; if only PBKDF2 is available, use a separate random salt, at least the project-approved iteration count, and AES-256-GCM.
- Produces `readDocumentFully(uri, maxBytes)` and `writeDocumentFully(uri, bytes)` that loop until complete.

- [ ] **Step 1: Add failing v3 crypto and tamper tests**

Cover correct passphrase, wrong passphrase, changed nonce/ciphertext/tag, truncated file, unsupported version, maximum size, v1/v2 compatibility, and no plaintext secret substring in encrypted output.

- [ ] **Step 2: Define backup scope explicitly**

The default encrypted backup includes business tables, local extensions, syncable/local personalization settings, lock metadata, and Pro account metadata. Secure Pro tokens/device identity require a separate explicit checkbox and are never included in plaintext mode.

- [ ] **Step 3: Add independent backup encryption UX**

Default to encrypted backup with passphrase confirmation. Plain JSON export remains available only behind an explicit warning that names passwords, private keys, TOTP secrets, and relay credentials.

- [ ] **Step 4: Implement bounded complete I/O**

Cap backup input at 32 MiB unless measured production data justifies a documented higher limit. Verify every write count, close, reopen, read header/checksum, and report cancellation separately from invalid/corrupt/unsupported files.

- [ ] **Step 5: Validate semantic integrity before restore**

Reject duplicate primary keys, unknown tables/extension table names, orphan references, invalid integer values, malformed extension payloads, and mismatched scope/checksum. Produce a preview report with counts and excluded secure items.

- [ ] **Step 6: Restore atomically and suppress upload**

Restore into temporary tables/snapshot, verify row counts and references, replace in one transaction, clear stale in-memory models, publish one snapshot, and retain a durable `restored_not_uploaded` state until the user explicitly uploads.

- [ ] **Step 7: Commit Task 8 files**

```powershell
git add -- entry/src/main/ets/services/BackupCryptoPolicy.ets entry/src/main/ets/services/BoundedDocumentIo.ets entry/src/main/ets/services/LocalBackupPolicy.ets entry/src/main/ets/services/LocalBackupService.ets entry/src/main/ets/pages/HostListPage.ets entry/src/test/BackupCryptoPolicy.test.ets entry/src/test/BoundedDocumentIo.test.ets entry/src/test/LocalBackupPolicy.test.ets
git commit -m "feat(backup): add bounded encrypted backup v3"
```

---

### Task 9: Unify and validate all file imports

**Files:**
- Modify: `entry/src/main/ets/services/SshKeyImportService.ets`
- Modify: `entry/src/main/ets/services/TotpImportService.ets`
- Modify: `entry/src/main/ets/services/AtsfTotpImportParser.ets`
- Modify: `entry/src/main/ets/services/RustDeskRelayImportService.ets`
- Modify: `entry/src/test/SshKeyImportService.test.ets`
- Modify: `entry/src/test/TotpImportService.test.ets`
- Create: `entry/src/test/RustDeskRelayImportService.test.ets`

**Interfaces:**
- Consumes `BoundedDocumentIo` from Task 8.
- Produces shared import result codes: `cancelled`, `empty`, `too_large`, `partial_read`, `unsupported_format`, `invalid_content`, `duplicate`, `ok`.

- [ ] **Step 1: Replace duplicated picker readers**

Each import service declares its own maximum size and accepted extensions but delegates complete reading, BOM handling, URI filename decoding, and cancellation to the common helper.

- [ ] **Step 2: Validate TOTP consistently**

CSV, TXT, JSON, and ATSF must all validate Base32, digits, period, algorithm, issuer/account limits, duplicate identity, and generated-code feasibility before persistence.

- [ ] **Step 3: Validate SSH and relay imports before preview**

Require native SSH inspection or explicit encrypted-key state. Validate relay host/IPv4/IPv6/domain, ports 1–65535, API URL scheme, key length, and official reversed-Base64/JSON structure without exposing key material in errors.

- [ ] **Step 4: Make batch persistence atomic where the UI promises all-or-nothing**

If a 2FA import preview selects N entries, either save all selected rows in one transaction or show an exact partial-result report with retryable failed entries; never silently drop invalid rows after confirmation.

- [ ] **Step 5: Run import tests and commit**

```powershell
git add -- entry/src/main/ets/services/SshKeyImportService.ets entry/src/main/ets/services/TotpImportService.ets entry/src/main/ets/services/AtsfTotpImportParser.ets entry/src/main/ets/services/RustDeskRelayImportService.ets entry/src/test/SshKeyImportService.test.ets entry/src/test/TotpImportService.test.ets entry/src/test/RustDeskRelayImportService.test.ets
git commit -m "fix(import): validate and bound credential files"
```

---

### Task 10: Make UI refresh revision-driven and exactly once

**Files:**
- Create: `entry/src/main/ets/services/DataSnapshotRevisionPolicy.ets`
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/services/KeyVaultService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/pages/KeyVaultPage.ets`
- Modify: `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- Create: `entry/src/test/DataSnapshotRevisionPolicy.test.ets`
- Modify: `entry/src/test/HostSyncMergePolicy.test.ets`

**Interfaces:**
- Produces `DataSnapshot<T> { revision: number; signature: string; items: T[] }`.
- Service listeners receive the snapshot/revision instead of an untyped `() => void` reload signal.

- [ ] **Step 1: Add failing notification-count tests**

Assert: initial ready snapshot = one event; unchanged cloud callback = zero; one edit = one; edit-sheet cancel = zero; local commit followed by matching cloud response = zero additional; restore = one.

- [ ] **Step 2: Remove startup double-load path**

`HostListPage.aboutToAppear()` subscribes first and awaits a single `whenReadySnapshot()`. Remove the parallel immediate `load()` plus `whenReady().then(load)` combination.

- [ ] **Step 3: Stop unchanged KeyVault refreshes**

Apply the same stable signature/revision comparison used for hosts to SSH keys, 2FA, credentials, relays, settings, and Pro metadata.

- [ ] **Step 4: Preserve ArkUI card reconstruction only when needed**

Use `id:revision` keys only when the item content revision changed. Unrelated counters or sheet lifecycle changes must not rebuild every card.

- [ ] **Step 5: Verify Phone/Pad/PC surfaces**

Every add/edit/delete must update external cards, expanded details, counts, selection lists, and settings cards in the same frame without page-wide double animation.

- [ ] **Step 6: Commit Task 10 files**

```powershell
git add -- entry/src/main/ets/services/DataSnapshotRevisionPolicy.ets entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/services/KeyVaultService.ets entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/pages/KeyVaultPage.ets entry/src/main/ets/pages/RustDeskRelayPage.ets entry/src/test/DataSnapshotRevisionPolicy.test.ets entry/src/test/HostSyncMergePolicy.test.ets
git commit -m "fix(ui): publish one revision per data change"
```

---

### Task 11: Repair transfer staging, streaming, and live-task cleanup

**Files:**
- Create: `entry/src/main/ets/services/TransferStagingService.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/services/FileTransferLiveTaskService.ets`
- Modify: `entry/src/main/ets/services/TransferSessionPolicy.ets`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `rustdesk_ffi/src/connector.rs`
- Modify: `rustdesk_ffi/src/protocol/session.rs`
- Modify: `entry/src/main/cpp/test/transfer_runtime_status_test.cpp`
- Create: `entry/src/test/TransferStagingService.test.ets`
- Modify: `entry/src/test/TransferSessionPolicy.test.ets`

**Interfaces:**
- Produces unique staged filenames preserving extension and adding deterministic ` (2)`-style suffixes.
- Produces transfer journal states `staging`, `published`, `remote_reading`, `completed`, `failed`, `expired`.
- Produces exactly-once `finish(taskId, outcome)` cleanup.

- [ ] **Step 1: Test name collision and cleanup policy**

Cover same basename from different directories, reserved names, `.`/`..`, Unicode, failed partial copy, disconnect, app restart, remote completion, and TTL expiry.

- [ ] **Step 2: Centralize staging ownership**

Create per-transfer directories, write to `.partial`, verify byte count, rename to final, journal ownership, and recursively delete only paths proven to remain under the app transfer root.

- [ ] **Step 3: Add startup and teardown cleanup**

Delete failed/expired partial files at startup. Keep RDP published files only while the native clipboard may read them, then clear on replacement, confirmed completion, disconnect, or bounded TTL.

- [ ] **Step 4: Stream RustDesk files**

Replace the 100 MB single ArrayBuffer with bounded chunks. If the current FFI only accepts one buffer, add `begin/sendChunk/finish/cancel` APIs with transfer ID and offset validation. Partial native writes must be retried or fail with an exact offset.

- [ ] **Step 5: Finish every live task exactly once**

RustDesk confirmed success calls `complete`; failure/cancel calls `fail`; timeout enters a bounded monitor and eventually completes/fails. Disconnect drains all active tasks. `activeTasks` must be empty after each terminal path.

- [ ] **Step 6: Run native/Rust/ArkTS transfer tests and commit**

Use the native and Rust verification commands in Task 13 before committing any ABI change.

```powershell
git add -- entry/src/main/ets/services/TransferStagingService.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/services/FileTransferLiveTaskService.ets entry/src/main/ets/services/TransferSessionPolicy.ets entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/cpp/rustdesk/rustdesk_bridge.h entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp entry/src/main/ets/types/rdpnapi.d.ts rustdesk_ffi/src/connector.rs rustdesk_ffi/src/protocol/session.rs entry/src/main/cpp/test/transfer_runtime_status_test.cpp entry/src/test/TransferStagingService.test.ets entry/src/test/TransferSessionPolicy.test.ets
git commit -m "fix(transfer): stream files and clean staging state"
```

---

### Task 12: Remove alternate persistence paths and align settings writes

**Files:**
- Delete after no-caller proof: `entry/src/main/ets/services/CloudSyncService.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
- Modify: `entry/src/test/CloudSyncSettingsPolicy.test.ets`

**Interfaces:**
- Produces one `SettingsRepository.set(key, value, scope)` path with scopes `cloud`, `device`, and `session`.

- [ ] **Step 1: Prove the legacy REST service has no callers**

Run `rg -n "CloudSyncService" entry/src/main/ets entry/src/test`. Delete it only when the class definition is the sole result; otherwise migrate each caller first.

- [ ] **Step 2: Route all setting mutations through one repository**

Settings changed from `RemoteDesktop` and settings pages must have identical persistence and cloud behavior. Cloud-scoped keys write Preferences/AppStorage/usersettings transactionally; device/session keys never enter cloud payload.

- [ ] **Step 3: Add scope-table tests**

Every settings key must appear exactly once in the scope registry. Tests fail for unknown keys and for session coordinates, temporary auth choices, or active-session state entering cloud payload.

- [ ] **Step 4: Commit Task 12 files**

```powershell
git add -- entry/src/main/ets/services/CloudSyncService.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/services/CloudSyncSettingsPolicy.ets entry/src/test/CloudSyncSettingsPolicy.test.ets
git commit -m "refactor(data): remove alternate sync and settings paths"
```

---

### Task 13: Full migration, device, fault-injection, and release verification

**Files:**
- Add or update only exact integration tests required by failed gates.
- Update after verification: `C:\Users\14288\.codex\projects\C--Users-14288\memory\CURRENT.md`
- Update after verification: `C:\Users\14288\.codex\projects\C--Users-14288\memory\QUEUE.md`

**Interfaces:**
- Consumes all earlier tasks.
- Produces a traceable migration/verification report without user secrets.

- [ ] **Step 1: Run static and ArkTS gates**

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --daemon
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify_open_source_release.ps1 -Mode Light
```

Expected: every command exits 0 with no new warnings attributable to this work.

- [ ] **Step 2: Run native and Rust gates when transfer ABI changed**

```powershell
cargo test --manifest-path rustdesk_ffi/Cargo.toml --all-features
& 'C:\tmp\remotedesk-native-tests\rdp_native_tests.exe'
```

Expected: all tests pass; rebuild both OHOS Rust targets before `assembleHap`.

- [ ] **Step 3: Validate migration copies**

Use sanitized copies representing: pre-extension database, current v2 extension database, encrypted/unlocked, encrypted/locked, stale password shadow, duplicate RDP credentials, and restored backup. Verify row counts, ID sets, ciphertext hashes, and canonical values before and after two consecutive startups.

- [ ] **Step 4: Validate remembered RustDesk password on device 38451**

Test Pro direct and relay: enter password, remember on/off, successful/failed auth, persistence failure injection, disconnect, kill app, cold start, connect again, manual upload, second-device download. The password must persist only after successful auth and explicit remember; failures must be visible.

- [ ] **Step 5: Validate cloud CRUD and conflict matrix**

For hosts, RDP credentials, relays/Pro metadata, SSH keys, 2FA, and settings: add/edit/delete, offline edit then kill, startup retry, manual upload/download, same-record two-device conflict, deselected table, encryption locked, cloud unavailable, and terminal callback failure. Verify no unconfirmed delete or stale rollback.

- [ ] **Step 6: Validate encryption fault matrix**

Enable, lock, background, edit attempt, unlock, disable, reset, wrong password, interrupted migration, cross-device status change, and backup restore. Inspect RDB only through redacted/hash diagnostics and confirm no plaintext secret is present when encryption is enabled.

- [ ] **Step 7: Validate backup matrix**

Encrypted v3 correct/wrong passphrase, plaintext warning, v1/v2 import, corrupt/truncated/oversized file, duplicate IDs, orphan extensions, partial write, restore rollback, restored-not-uploaded state, explicit upload, and secure-token include/exclude choices.

- [ ] **Step 8: Validate import and transfer matrix**

SSH plain/encrypted keys, ATSF/TXT/JSON/CSV, official RustDesk server config, invalid secrets/ports, same-name multi-file RDP paste, disconnect during copy, app restart cleanup, RustDesk 100 MB boundary, remote timeout, and live-task cleanup.

- [ ] **Step 9: Validate exactly-once UI refresh**

Record refresh revisions for cold start, opening/canceling edit sheets, successful save, failed save, cloud callback, restore, and unlock. Each semantic state change increments once; no-op and sheet close increment zero times.

- [ ] **Step 10: Perform final secret and scope audit**

Search logs, Preferences, backup samples, mutation journals, cloud payload builders, and test fixtures. Confirm no real secrets, tokens, signing files, user data, `.appanalyzer/`, unrelated plans, or generated signed artifacts are staged.

- [ ] **Step 11: Commit verification records and complete branch workflow**

Use exact-file staging, push the current `codex/...` branch, open a PR, wait for required `open-source-compliance`, merge only after device acceptance, return to synchronized `main`, and update `CURRENT.md`/`QUEUE.md`.

---

## 4. Mandatory Acceptance Criteria

The remediation is complete only when all conditions below are true:

- Remembered RustDesk passwords survive cold start and cross-device sync without a shadow override.
- A failed local or extension write is visible and cannot be reported as saved.
- Configured-but-locked encryption causes an unlock request, never plaintext fallback.
- Enabling, disabling, resetting, restoring, and cloud-changing encryption are atomic and interruption-safe.
- No encrypted model is cached as if it were usable plaintext; unlock produces one decrypted snapshot.
- RDP credentials are either complete across devices or clearly marked device-incomplete before connection.
- Pro tokens are stored in protected device-local storage and excluded from cloud metadata.
- Sensitive cloud tables cannot upload plaintext without an explicit informed policy decision.
- Backup v3 is bounded, authenticated, restorable, and independently encrypted by default.
- Backup restore never automatically uploads and rolls back completely on failure.
- SSH, 2FA, and relay imports reject invalid or incomplete content before persistence.
- RDP/RustDesk transfer staging has collision-safe names, bounded lifetime, and no orphan background task.
- One data mutation produces one UI snapshot revision; no-op/cancel produces none.
- Existing Huawei cloud table schemas remain unchanged.
- Existing v1/v2 backups and legacy databases retain all recoverable data.
- Automated gates and the complete device `38451` matrix pass with sanitized evidence.

## 5. Stop/rollback conditions

Stop the implementation and restore the pre-task local snapshot if any of these occur:

- Migration changes row count or primary-key set without an explicit documented deletion.
- A secret becomes undecipherable while its previous decryptable copy has already been removed.
- Cloud table binding reports a schema change or unknown-column error.
- A cloud-first operation causes local deletion without a validated complete snapshot/user confirmation.
- Backup restore cannot roll back after an injected failure.
- Encryption-enabled tests find plaintext in RDB, local extensions, Preferences, backup output, logs, or cloud-bound buckets.
- Three consecutive fixes reveal new independent state owners; pause and redesign the ownership boundary before a fourth patch.

## 6. Recommended execution checkpoints

1. Tasks 1–3: canonical storage and transaction checkpoint; run device migration read-only verification.
2. Tasks 4–5: encryption checkpoint; do not continue until plaintext scans and interruption tests pass.
3. Tasks 6–7: credential/cloud checkpoint; verify two-device edits before touching backup.
4. Tasks 8–9: backup/import checkpoint; preserve v1/v2 fixtures permanently.
5. Tasks 10–12: refresh/file/settings checkpoint.
6. Task 13: full acceptance, PR, and merge.

Do not combine all checkpoints into one commit. Every checkpoint must be independently reviewable and must leave the app capable of reading the previous on-device database.
