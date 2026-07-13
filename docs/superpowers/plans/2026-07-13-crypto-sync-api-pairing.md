# CryptoFramework Sync API Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the emulator native AES-GCM crash by pairing the CryptoFramework synchronous initialization and finalization APIs correctly.

**Architecture:** `CloudStore` remains synchronous and continues to call `DataCrypto.encrypt()` while constructing RDB value buckets. `DataCrypto` keeps the existing AES-256-GCM payload format and pairs `initSync()` with `doFinalSync()` in both encryption and decryption. The two raw secret loaders also treat `#_deleted_flag` as optional because ordinary `querySync()` results do not expose that cursor-only field.

**Tech Stack:** ArkTS, HarmonyOS API 23 CryptoArchitectureKit, Hypium, DevEco hvigor.

## Global Constraints

- Work in `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop` on the existing `codex/rdp-rustdesk-video-performance` branch; do not create a worktree.
- Preserve `1:base64(iv):base64(ciphertext+tag)`, 12-byte IV, 16-byte tag, AES256-GCM-PKCS7, and empty-AAD behavior.
- Do not change CloudStore schemas, cloud synchronization behavior, HDS floating bar, or unrelated uncommitted files.
- Use API 23’s paired synchronous Cipher calls: `initSync()` and `doFinalSync()`.

---

### Task 1: Establish the device regression case

**Files:**
- Modify: `entry/src/ohosTest/ets/test/DataCrypto.test.ets:39-54`

**Interfaces:**
- Consumes: `DataCrypto.encrypt(plaintext: string): string` and `DataCrypto.decrypt(wrapped: string): string`.
- Produces: a focused short-plaintext AES-GCM round-trip test that exercises the synchronous CryptoFramework path used by the crashing CloudStore insert.

- [x] **Step 1: Write the failing test**

```ts
it('encrypt_decrypt_short_password_should_restore_plaintext', 0, () => {
  const plaintext = 'testpass';
  const encrypted = crypto.encrypt(plaintext);
  expect(encrypted.startsWith('1:')).assertTrue();
  expect(crypto.decrypt(encrypted)).assertEqual(plaintext);
});
```

- [x] **Step 2: Record the pre-fix crash evidence**

Observed: the user crash log terminates in `ossl_gcm_stream_update` → `EVP_EncryptUpdate` → `libcryptoframework_napi` directly after `DataCrypto.setMasterPassword()` and a CloudStore encrypted insert. This establishes that the native provider received a finalization request before the asynchronous Cipher initialization was ready.

- [x] **Step 3: Keep the test as a permanent regression case**

The test must remain in `DataCrypto_GCM`, with no mock CryptoFramework implementation, so it executes the platform bridge.

### Task 2: Pair synchronous Cipher lifecycle APIs

**Files:**
- Modify: `entry/src/main/ets/services/DataCrypto.ets:254-256,674-675`

**Interfaces:**
- Consumes: `cryptoFramework.Cipher.initSync(opMode, key, params): void`.
- Produces: `DataCrypto.encrypt()` and `DataCrypto.decrypt()` whose Cipher contexts are initialized before `doFinalSync()` reaches the native OpenSSL provider.

- [x] **Step 1: Apply the minimal implementation**

```ts
// encrypt
cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
const encryptData = cipher.doFinalSync(plainData);

// decryptGcmPayload
cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
return cipher.doFinalSync({ data: ct });
```

- [x] **Step 2: Verify GREEN with the focused device regression**

Ran the selected test class after compiling and installing the fresh production and test HAPs:

```powershell
hdc -t 127.0.0.1:5555 shell aa test -b com.example.remotedesktop -m entry_test `
  -s unittest /ets/testrunner/OpenHarmonyTestRunner `
  -s class DataCrypto_GCM -s timeout 15000 -s coverage false
```

Observed: `Tests run: 3, Failure: 0, Error: 0, Pass: 3, Ignore: 0`. This covers the new short-text reproduction, the existing mixed UTF-8 round trip, and GCM authentication-tag rejection without a native process termination.

### Task 3: Make raw secret queries resilient to absent deleted flags

**Files:**
- Modify: `entry/src/main/ets/services/CloudStore.ets:1981-1987,2021-2027`
- Test: `entry/src/ohosTest/ets/test/DataCrypto.test.ets:69-129` (existing `DataCrypto_CloudStore_RawFields` integration regression)

**Interfaces:**
- Consumes: `ResultSet.getColumnIndex()` returning a negative value for a column that is absent from an ordinary RDB query result.
- Produces: raw SSH-key and TOTP loaders that only inspect `#_deleted_flag` when the field is present, preserving normal decryption/raw mapping behavior.

- [x] **Step 1: Reproduce the RDB failure**

The existing raw sensitive-field device test failed before this guard with `CloudStore` errors `{\"code\":\"14800013\"}`. The code is the RDB column-index-out-of-range error caused by calling `getLong(-1)` for `#_deleted_flag`.

- [x] **Step 2: Apply the narrow guard**

```ts
const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
while (rs.goToNextRow()) {
  if (dfIdx >= 0 && rs.getLong(dfIdx) === 1) { continue; }
  result.push(decrypt ? this.rowToSshKey(rs) : this.rowToSshKeyRaw(rs));
}
```

The same guard is used by `loadAllTotpEntriesInternal`. It does not change schemas, values, encryption, or cloud synchronization.

- [x] **Step 3: Verify the raw integration regression**

```powershell
hdc -t 127.0.0.1:5555 shell aa test -b com.example.remotedesktop -m entry_test `
  -s unittest /ets/testrunner/OpenHarmonyTestRunner `
  -s class DataCrypto_CloudStore_RawFields -s timeout 15000 -s coverage false
```

Observed: `Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0` after installing the fresh HAPs.

### Task 4: Compile, build, and record evidence

**Files:**
- Modify: `docs/superpowers/plans/2026-07-13-crypto-sync-api-pairing.md` (check completed tasks and record exact verification output)

**Interfaces:**
- Consumes: API 23 ArkTS compile target and production `assembleHap` task.
- Produces: build evidence for the repaired app without widening scope.

- [x] **Step 1: Run ArkTS test compilation**

Run `default@OhosTestCompileArkTS` with the project DevEco Node/hvigor command.

Observed: `default@OhosTestCompileArkTS` completed with `BUILD SUCCESSFUL in 13 s 730 ms`.

- [x] **Step 2: Run the signed production build**

Run `assembleHap` with the project DevEco Node/hvigor command.

Observed: `assembleHap` completed with `BUILD SUCCESSFUL in 24 s 243 ms`.

The fresh signed production HAP and the signed test HAP were installed on `127.0.0.1:5555` before the device results above.

- [x] **Step 3: Inspect scope and commit**

`git diff --cached --check` completed without whitespace errors. Only the three production/test files above and this plan were staged; unrelated `.planning/`, AGPL plan, and `logs/` files remained untracked. Committed as `fix(crypto): pair synchronous cipher lifecycle`.
