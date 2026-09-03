# Phase 2 Revised Remediation Plan: Persistent Identity, Trust State & macOS Keychain

**Date:** 2026-09-03  
**Status:** Pending Human Approval (No code modified)  
**Target Scope:** Phase 2 only (`CryptoKeyStorage`, `DeviceIdentityService`, `TrustStore`, and dedicated migration/failure tests).

---

## 1. Confirmed Blockers & Current vs. Desired Behavior

| # | Blocker | Current Code Behavior | Required Remediation Behavior |
|---|---|---|---|
| **1** | **macOS Keychain Routing** | `CryptoKeyStorage` branches on `_isMacDesktop` to file fallback (`allowFallback == true`) or throws `StateError` (`allowFallback == false`). Never executes Keychain. | When `allowFallback == false` (or in staging/production), `CryptoKeyStorage` routes all reads/writes directly to `_secureStorage` backed by macOS Keychain (`MacOsOptions()`). Fallback file is restricted to local development only. |
| **2** | **Existing Phase 1 Identity Backfill** | Phase 1 identities lack a commit marker. A strict new requirement would treat all valid existing Phase 1 identities as corrupted. | Define a deterministic backfill rule: If `kDeviceIdKey`, `kDeviceNameKey`, and `kIdentityPrivateKeyKey` are present, non-empty, and decode to a valid 32-byte Ed25519 seed, backfill `kIdentityCommittedKey = 'true'` automatically on first load. |
| **3** | **Keychain-Only Migration Destination** | Development migration previously wrote through `write()`, which on macOS wrote back into the same application support file. | Migration explicitly targets `_secureStorage` (Keychain), never the fallback file. The legacy file is only deleted after writing to Keychain and verifying round-trip public key / fingerprint derivation. |
| **4** | **Per-Attempt Migration Rollback** | Recovery previously risked deleting other environment keys if broad cleanup were attempted. | Track the exact list of keys written during the migration attempt. If any step fails, delete *only* those tracked keys from the active namespace. Never call `deleteAll()`. |
| **5** | **Fail-Closed TrustStore on Corruption & Storage Errors** | `TrustStore.load()` catches all exceptions and silently sets `_isLoaded = true` (empty trust store). | Throw typed `TrustStorageException` on storage errors and `TrustCorruptedException` on malformed JSON, corrupted fingerprints (not 64 hex chars), invalid public keys, or mismatched hashes. Never treat corruption as an empty store. |
| **6** | **Transactional & Idempotent Identity Reset** | `resetIdentity()` only deleted identity keys and left trust records intact. | `resetIdentity({required KeyStorage storage, TrustStore? trustStore})` purges identity keys and invalidates all trust records. A fresh identity never inherits old trust relationships. |
| **7** | **Pre-init Access Guard** | `DeviceIdentityService.identity` lazily generates an ephemeral in-memory identity. | In staging and production, accessing `.identity` before `initialize()` throws `StateError` (fails closed). Ephemeral fallback is restricted to debug/development or explicit unit tests. |
| **8** | **Partial-Write Recovery** | If writing identity keys is interrupted midway, leftover orphan keys corrupt subsequent boot. | Enforce write sequence: `PrivKey` -> `DeviceId` -> `DeviceName` -> `IdentityCommitted`. On startup, if any field is missing or uncommitted and does not meet the backfill criteria, fail closed with `IdentityCorruptedException`. |
| **9** | **Injectable Migration Filesystem** | Migration depended on `getApplicationSupportDirectory()`, preventing realistic file tests. | Accept an optional `File? legacyFileOverride` in migration methods so tests run with temporary directories without touching the user's real filesystem. |
| **10** | **Exception Cause Redaction** | Exception `toString()` included raw exception objects that could leak sensitive paths/keys. | Public exception strings expose sanitized, high-level messages. Technical causes are logged internally only to redacted debug logs. |

---

## 2. macOS Keychain & Entitlement Verification

### Backend Details for `flutter_secure_storage: 10.3.1`
- **macOS Backend:** Uses the transitive `flutter_secure_storage_darwin: 0.3.2` package communicating with the native macOS Security Framework (`kSecClassGenericPassword`).
- **Sandboxing & Entitlements:**
  - OneShare has `com.apple.security.app-sandbox` set to `true` in both `DebugProfile.entitlements` and `Release.entitlements`.
  - In a sandboxed macOS application, the native Security Framework automatically scopes generic passwords to the application's unique sandbox container partition without needing `keychain-access-groups`.
  - Adding `keychain-access-groups` without an Apple Developer Team ID causes code-signing failures during unsigned/ad-hoc builds. Therefore, `keychain-access-groups` must **not** be added blindly.
- **MacOsOptions Configuration:**
  - Use `MacOsOptions(accessibility: KeychainAccessibility.unlocked)` to ensure keys are securely stored and accessible while the user session is active.

---

## 3. Startup, Storage & Migration State Machine

```
                              [Application Startup]
                                        │
                                        ▼
                         [AppEnvironment.resolve()]
                                        │
                                        ▼
                     [Legacy Migration (if applicable)]
                     ├── Legacy file exists at path?
                     │     ├── YES: Read & Validate 32-byte Ed25519 Seed
                     │     │     ├── Valid:
                     │     │     │     ├── Write keys to _secureStorage (Keychain)
                     │     │     │     ├── Verify round-trip derivation
                     │     │     │     └── If Verified: Delete legacy file
                     │     │     └── Invalid / Corrupted:
                     │     │           ├── Quarantine to .corrupted
                     │     │           ├── Rollback keys written during attempt
                     │     │           └── THROW LegacyMigrationException (HALT)
                     │     └── NO: Proceed to Identity Initialization
                     │
                     ▼
                 [DeviceIdentityService.initialize()]
                     ├── Read: PrivKey, DeviceId, DeviceName, CommittedMarker
                     │
                     ├── Case A: All 4 keys intact & seed decodes to 32 bytes
                     │     └── Restore Ed25519 keypair -> Set _identity (SUCCESS)
                     │
                     ├── Case B: Exactly 0 keys present (Fresh install)
                     │     └── Generate fresh Ed25519 keypair + UUID + DeviceName
                     │     └── Write: PrivKey -> DeviceId -> DeviceName -> CommittedMarker
                     │     └── Set _identity (SUCCESS)
                     │
                     ├── Case C: Valid Phase 1 keys present, missing CommittedMarker
                     │     └── Validate 32-byte seed + non-empty DeviceId + DeviceName
                     │     └── Backfill CommittedMarker = 'true' -> Set _identity (MIGRATION SUCCESS)
                     │
                     ├── Case D: Partial / Inconsistent keys (Interrupted write)
                     │     └── THROW IdentityCorruptedException (HALT)
                     │
                     └── Case E: Storage read error (Keystore/Keychain unavailable)
                           └── THROW IdentityStorageException (HALT)
```

---

## 4. TrustStore Fail-Closed Specification

Storage errors and corrupt records in `TrustStore.load()` will be strictly typed and fail closed:
1. **Typed Exceptions:**
   - `TrustStorageException`: Thrown when underlying `KeyStorage` throws an I/O exception.
   - `TrustCorruptedException`: Thrown when the trust index JSON is malformed, a peer record JSON is unparseable, a fingerprint is not a 64-char hex string, public key bytes are not 32 bytes, or SHA-256 of public key does not match fingerprint.
2. **State Invariant:**
   - On exception, `_isLoaded` remains `false` and `_cache` is cleared.
   - Any subsequent call to `evaluatePeer()` or `getPeer()` calls `load()`, failing closed and halting rather than silently assuming zero trusted peers.

---

## 5. Transactional Identity Reset Specification

`DeviceIdentityService.resetIdentity({required KeyStorage storage, TrustStore? trustStore})`:
1. **Order of Operations:**
   - Step 1: Invalidate trust store (`await trustStore.clearAll()`). Old peer trust records are purged before identity deletion.
   - Step 2: Delete `kIdentityCommittedKey` (uncommits identity).
   - Step 3: Delete `kDeviceIdKey`, `kDeviceNameKey`, and `kIdentityPrivateKeyKey`.
   - Step 4: Clear in-memory singleton: `_identity = null`.
   - Step 5: Invoke `initialize(storage: storage)` to cleanly bootstrap a new identity and commit marker.
2. **Interruption Resilience:**
   - If interrupted between Step 2 and Step 5, the absence of `kIdentityCommittedKey` prevents treating the partially-deleted state as valid on restart.

---

## 6. Pre-Initialization Guard Specification

In `DeviceIdentityService`:
```dart
static DeviceIdentity get identity {
  if (_identity != null) return _identity!;
  if (AppEnvironment.current.type == EnvironmentType.staging ||
      AppEnvironment.current.type == EnvironmentType.production) {
    throw StateError(
      'DeviceIdentityService.identity accessed before initialize() in a secure environment.',
    );
  }
  return _identity ??= _createFallbackIdentity();
}
```

---

## 7. Exact Files to Modify & Create

### Modify:
1. **[`lib/services/crypto/crypto_key_storage.dart`](lib/services/crypto/crypto_key_storage.dart)**:
   - Separate Keychain vs. Fallback routing. When `allowFallback == false`, macOS executes via `_secureStorage` (`MacOsOptions(accessibility: KeychainAccessibility.unlocked)`).
   - Support `legacyFileOverride` in `migrateLegacyFileIfNeeded()`.
   - Implement per-attempt key rollback on migration failure.
2. **[`lib/services/device_identity_service.dart`](lib/services/device_identity_service.dart)**:
   - Add `kIdentityCommittedKey`.
   - Implement Phase 1 identity backfill rule.
   - Implement transactional write sequence (`PrivKey` -> `DeviceId` -> `DeviceName` -> `Committed`).
   - Implement fail-closed `identity` getter in staging/production.
   - Update `resetIdentity()` with trust store invalidation.
   - Sanitize exception `toString()` messages.
3. **[`lib/services/crypto/trust_store.dart`](lib/services/crypto/trust_store.dart)**:
   - Define `TrustStorageException` and `TrustCorruptedException`.
   - Implement strict structural and cryptographic integrity checks in `load()`. Fail closed on error.
4. **[`test/device_identity_service_test.dart`](test/device_identity_service_test.dart)**:
   - Add tests for Phase 1 identity backfill, partial write detection, pre-init access denial in production, and transactional reset with trust purge.
5. **[`test/storage_migration_and_failure_test.dart`](test/storage_migration_and_failure_test.dart)**:
   - Real file migration tests using temporary directories: verified migration, per-attempt rollback, corrupted seed quarantine, and fail-closed trust load tests.

---

## 8. Remaining Decisions for Approval

1. **Phase 1 Backfill Rule:** Do you approve automatically backfilling `kIdentityCommittedKey = 'true'` when an existing valid 3-key identity is loaded without a commit marker?
2. **Migration Quarantine Extension:** Do you approve renaming corrupted legacy files to `.oneshare_secure_keys.json.corrupted` so uncorrupted user data is preserved for manual inspection?
3. **TrustStore Corruption Failure Mode:** Do you approve that any corruption in the stored trust index or peer records throws `TrustCorruptedException` and halts rather than dropping single corrupted records?
