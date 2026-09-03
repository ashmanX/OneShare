# Phase 7 Implementation Plan: Staging and Release-Like Validation

## 1. Overview & Objectives
The primary objective of **Phase 7** ("Staging and Release-Like Validation") is to validate the complete security, cryptographic, and storage architecture in isolated, release-like environments prior to production store distribution (Phase 8).

Phase 7 proves that:
1. **Isolated Staging Environment**: The application strictly enforces `EnvironmentType.staging` with `oneshare.staging.` storage namespaces, zero fallback to unencrypted files, and release-level diagnostic configurations.
2. **Platform Secure Storage Enforcement**:
   - **macOS Keychain**: Operates under strict Keychain access without fallback permissions (`isFallbackPermitted == false`). Staging storage failures fail closed rather than degrading to unencrypted application support files.
   - **Android Encrypted Storage**: Runs under isolated secure storage (`FlutterSecureStorage` with Android Keystore encryption), ensuring identities and trust stores survive application lifecycle without plaintext leaks into shared preferences.
3. **Cross-Environment Non-Contamination**: Staging identities, disposable test keys, and staging peer trust records never contaminate or cross-pollinate development (`oneshare.dev.`) or production (`oneshare.prod.`) storage partitions.
4. **Release-Like Transport & LAN Policies**: Cleartext HTTP traffic across local LAN operates securely strictly over authenticated E2EE v2 channels, while public APIs and packaging configurations are verified against release entitlement requirements.
5. **Adversarial & Regression Verification**: High-concurrency transfers, mid-stream connection abortions, and corrupt cryptographic inputs fail safely in release-mode configurations.

---

## 2. User Review Required

> [!IMPORTANT]
> **Key Architectural Assertions for Phase 7:**
> 1. **Staging Fails Closed on Storage Failure**:
>    - In `EnvironmentType.staging`, `CryptoKeyStorage.allowFallback` is strictly `false`. If the platform Keychain / Keystore cannot be reached or is locked, the application must throw `StorageUnavailableException` and fail closed. Under no circumstance should a temporary filesystem file be created.
> 2. **Explicit Migration & Cross-Namespace Isolation**:
>    - `CryptoKeyStorage` namespace prefixes (`oneshare.staging.`, `oneshare.dev.`, `oneshare.prod.`) must be strictly segregated. Writing to staging must never touch dev or production keys.
> 3. **Release Entitlements & Packaging Verification**:
>    - macOS Release entitlements ([`macos/Runner/Release.entitlements`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner/Release.entitlements)) must retain App Sandbox (`com.apple.security.app-sandbox`), client/server network capabilities, and user file access while omitting debug JIT entitlements (`com.apple.security.cs.allow-jit`).
>    - Android cleartext traffic (`android:usesCleartextTraffic="true"`) is confirmed for LAN socket bindings while all application payload data is protected via XChaCha20-Poly1305 AEAD streaming.

---

## 3. Scope of Implementation & Workstreams

### 3.1 Workstream A: Staging Environment Enforcement & Configuration
- **Files**:
  - [`lib/config/app_environment.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/config/app_environment.dart)
  - [`lib/services/crypto/crypto_key_storage.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/crypto_key_storage.dart)
- Verify `AppEnvironment.staging`:
  - `storageNamespacePrefix == 'oneshare.staging.'`
  - `isFallbackPermitted == false`
  - `isVerboseLoggingEnabled == false`
  - `isCleartextLanPermitted == true`
- Ensure strict fail-closed behavior when Keychain access fails in staging mode.

### 3.2 Workstream B: Platform Storage Integrity & Keychain Validation
- **Files**:
  - [`lib/services/crypto/crypto_key_storage.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/crypto_key_storage.dart)
  - [`lib/services/device_identity_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/device_identity_service.dart)
  - [`lib/services/crypto/trust_store.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/trust_store.dart)
- Verify multi-environment key namespace isolation:
  - Assert that an identity initialized in `staging` creates keys with `oneshare.staging.` prefix and cannot read or overwrite `oneshare.dev.` keys.
  - Verify that legacy file fallback migration logic safely imports old keys only when explicitly invoked and does not create fallback files when running in staging.
  - Verify that trust store indexes in staging use `oneshare.staging.oneshare_trust_index_fingerprints`.

### 3.3 Workstream C: Release Entitlements & Packaging Integrity
- **Files**:
  - [`macos/Runner/Release.entitlements`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner/Release.entitlements)
  - [`android/app/build.gradle.kts`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/build.gradle.kts)
  - [`android/app/src/main/AndroidManifest.xml`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/AndroidManifest.xml)
- Validate:
  - macOS `Release.entitlements` has proper App Sandbox, Network Client/Server, and Downloads folder permissions.
  - Android Manifest permissions (`INTERNET`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `ACCESS_NETWORK_STATE`).
  - Strict logging silence in staging/release (verifying `LogSanitizer` operates and verbose logs are disabled).

### 3.4 Workstream D: Adversarial, Concurrency, and Lifecycle Test Suite
- **File:** `test/staging_and_release_validation_test.dart`
- New dedicated staging test harness to execute:
  1. **Staging Environment Lock**: Assert that setting `AppEnvironment.staging` enforces non-fallback rules and staging prefix.
  2. **Namespace Collision & Isolation Test**: Ensure simultaneous operations under test, dev, and staging namespaces do not leak keys or trust records across environments.
  3. **Fail-Closed Storage Simulation**: Simulate Keychain/Keystore throwing platform exceptions in staging and verify that identity initialization fails closed (`StorageUnavailableException`) without writing unencrypted fallback files.
  4. **Multi-File Batch Concurrency & Abortion in Staging Mode**: Stress test transfer pipelines under staging configuration with concurrent simulated clients, verify clean resource teardown and zero memory retention.
  5. **Compromise Recovery under Staging**: Verify `DeviceIdentityService.resetIdentity` in staging purges all staging-namespaced keys and trust records cleanly.

---

## 4. Verification Plan

### Automated Tests
- Run new targeted staging tests:
  ```bash
  flutter test test/staging_and_release_validation_test.dart
  ```
- Run static analysis:
  ```bash
  dart analyze lib/ test/
  ```
- Run full regression suite:
  ```bash
  flutter test
  ```

### Manual & Platform Verification
- Verify build capability in release configuration:
  ```bash
  flutter build macos --release
  ```
- Inspect entitlements and configuration parameters for staging correctness.

---

## 5. Phase 7 Deliverables & Exit Criteria
1. Complete implementation of any staging guards and namespace enforcement.
2. New test suite `test/staging_and_release_validation_test.dart` passing with 100% success.
3. Zero static analysis warnings (`dart analyze`).
4. All existing unit and integration tests passing.
5. `PHASE_7_IMPLEMENTATION_REPORT.md` documenting staging validation evidence, platform isolation findings, and readiness for Phase 8.
