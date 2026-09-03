# Phase 1: Environment and Dependency Injection Foundation Report (Updated)

**Execution Date:** 2026-09-03  
**Status:** Completed & Verified  
**Scope:** Environment isolation, storage namespaces, compile-time flag resolution, fail-closed validation, and dependency injection foundation.  
**Platform Status Note:** **macOS Keychain storage is NOT implemented in Phase 1.** In Phase 1, macOS desktop in `development` mode continues to use the existing sandboxed application support file under `oneshare.dev.`, while `staging` and `production` modes strictly fail closed when fallback is requested (`isFallbackPermitted: false`). Implementation of macOS Keychain via `flutter_secure_storage` is deferred to Phase 2.

---

## 1. Summary of Changes

### 1.1 New Files
- **[`lib/config/app_environment.dart`](lib/config/app_environment.dart)**:
  - Defines `EnvironmentType`: `unitTest`, `development`, `staging`, `production`.
  - Defines distinct immutable storage namespace prefixes:
    - Unit test: `oneshare.test.`
    - Development: `oneshare.dev.`
    - Staging: `oneshare.staging.`
    - Production: `oneshare.prod.`
  - Enforces fail-closed compile-time flag resolution via `AppEnvironment.resolveFromEnvironment()`.
  - Prohibits fallback storage (`isFallbackPermitted: false`) in `staging` and `production`.

### 1.2 Modified Files
- **[`lib/services/crypto/crypto_key_storage.dart`](lib/services/crypto/crypto_key_storage.dart)**:
  - Added `namespacePrefix` and `allowFallback` parameters to `CryptoKeyStorage` and `InMemoryKeyStorage`.
  - Added `_namespacedKey()` helper that automatically prepends the environment's storage prefix.
  - **Fixed Android/iOS `deleteAll()`**: Replaced unrestricted `_secureStorage.deleteAll()` with selective prefix-scoped deletion (`readAll()` followed by filtered `delete()`) so `deleteAll()` in one environment can never destroy keys belonging to another environment.
  - In `write()`, `read()`, `delete()`, `containsKey()`, and `deleteAll()`, explicitly asserts `_allowFallback` before accessing plaintext file storage on macOS. If `allowFallback` is `false` (in staging/production), throws a `StateError` (fails closed).
- **[`lib/main.dart`](lib/main.dart)**:
  - Calls `AppEnvironment.resolveFromEnvironment()` at application startup before initializing `DeviceIdentityService`.

### 1.3 Preserved Baseline Changes
The tracked trust fixes in the working tree were preserved intact:
- `lib/main.dart`: Uses canonical `session.peerFingerprint` and `session.peerDeviceId` for SAS dialog.
- `lib/services/crypto/e2ee_session.dart`: Exposes `peerFingerprint` and `peerDeviceId`.
- `lib/services/transfer_service.dart`: Tracks `session.peerFingerprint` and records peer encounters on valid handshakes.

---

## 2. Verification & Test Results

### 2.1 Static Analysis
```bash
flutter analyze
```
**Result:** `No issues found!` (0 errors, 0 warnings).

### 2.2 Phase 1 Isolation & Storage Security Tests
```bash
flutter test test/environment_isolation_test.dart
```
**Result:** All 9 tests passed:
- `AppEnvironment defaults to development in debug mode` (Passed)
- `All environments define distinct, non-overlapping namespace prefixes` (Passed)
- `Staging and production strictly forbid fallback plaintext file storage` (Passed)
- `InMemoryKeyStorage automatically prefixes keys with active environment namespace` (Passed)
- `Isolated storage instances with different namespaces cannot see each other data` (Passed)
- `CryptoKeyStorage rejects fallback file access when allowFallback is false` (Passed)
- `Compile-time resolver rejects unknown ENV strings` (Passed)
- `Shared backend namespace partitioning prevents cross-environment reads and deletions` (Passed)
- `Storage failure policy: read and write errors fail closed with StateError when fallback is prohibited` (Passed)

### 2.3 Full Test Suite
```bash
flutter test
```
**Result:** All **108 tests passed** (99 baseline + 9 environment isolation tests), 0 failures.

---

## 3. Storage Isolation & Namespace Guarantee

1. **Namespace Separation:**
   - Development keys: `oneshare.dev.<key>` (e.g. `oneshare.dev.oneshare_device_id`).
   - Staging keys: `oneshare.staging.<key>`.
   - Production keys: `oneshare.prod.<key>`.
   - Unit tests: `oneshare.test.<key>` using isolated `InMemoryKeyStorage`.
2. **Cross-Environment Deletion Protection:**
   - Both macOS and Android/iOS `deleteAll()` implementations selectively target only keys prefixed with `_namespacePrefix`.
   - Calling `deleteAll()` in `development` will not purge `production` or `staging` records stored on the same shared backend.
3. **Current Storage Status by Platform:**
   - **Android:** Active storage uses hardware-backed Android Keystore via `flutter_secure_storage` with prefix-isolated keys.
   - **macOS:** Active storage in `development` mode uses isolated sandboxed file storage under `oneshare.dev.`. In `staging` and `production` modes, fallback file storage is strictly prohibited and fails closed. **Native macOS Keychain storage is deferred to Phase 2.**

---

## 4. Configuration Examples

### Local Development (Default in debug mode):
```bash
flutter run
# Or explicitly:
flutter run --dart-define=ENV=development
```

### Staging:
```bash
flutter run --release --dart-define=ENV=staging
```

### Production:
```bash
flutter build macos --release --dart-define=ENV=production
flutter build appbundle --release --dart-define=ENV=production
```
*(Requires explicit `ENV=production`. Missing flags in release mode fail closed).*
