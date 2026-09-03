# OneShare Environment Isolation and Store-Readiness Rollout Plan

**Date:** 2026-09-03  
**Audience:** Engineering, security, QA, release engineering, and product owners  
**Purpose:** Define how to introduce security and store-readiness changes safely across development, staging, and production

## 1. Goal

Introduce the E2EE security fixes and store-readiness configuration without contaminating local test data, invalidating production identities, or allowing development-only behavior into store builds.

The rollout has four environments:

| Environment | Purpose | Distribution | Trust/storage policy |
|---|---|---|---|
| Unit test | Fast deterministic tests | None | In-memory or temporary fixtures |
| Development | Daily local development | Local debug/profile builds | Isolated development storage |
| Staging | Release-like validation | Internal Android/macOS artifacts | Isolated staging storage and signing |
| Production | Store users | Google Play/App Store | Stable production storage and signing |

The same Android and macOS production applications communicate with each other. “Isolation” means their credentials, persistent identity data, trust records, logs, and release configuration are not shared with test or staging environments.

## 2. Rules Before Any Changes

1. Do not use a personal production Keychain/Keystore while developing.
2. Do not point tests at the production trust store.
3. Do not migrate existing development identity data directly into production.
4. Do not use production signing keys in local development or CI logs.
5. Do not change the production application ID, bundle ID, signing identity, or secure-storage namespace after the first public release.
6. Do not make a runtime storage error generate a new identity automatically.
7. Do not enable a development plaintext storage fallback in a production artifact.
8. Keep protocol/security changes independent from final store credentials.
9. Record the exact configuration used for every test artifact.
10. Preserve the existing approved E2EE v2 protocol and security invariants.

## 3. Environment Matrix

### 3.1 Unit tests

Use:

- `InMemoryKeyStorage` for identity and trust tests.
- Temporary directories for file and migration tests.
- Mock HTTP/network services.
- Deterministic test identities only where test vectors require them.
- Unique transfer IDs per test.

Never use:

- The developer’s real Keychain.
- The developer’s real Android Keystore.
- Production trust records.
- Production signing keys.

### 3.2 Development

Purpose: fast local debugging and two-device LAN testing.

Use:

- Debug signing.
- A development Android application ID or clearly isolated debug variant.
- A development macOS bundle identifier and Keychain service/account namespace.
- Development identity and trust records.
- Verbose logs with mandatory credential redaction.
- LAN HTTP only if required by current local testing.
- A deliberate development identity-reset action.

Development identity changes are acceptable. Development trust records may be cleared freely.

### 3.3 Staging

Purpose: release-like testing before production configuration is used.

Use:

- Staging Android application ID and macOS bundle identifier.
- Staging secure-storage namespace.
- Staging identity keys and trust records.
- Release-like logging and error handling.
- Staging signing keys, never production keys.
- Production-like protocol and validation behavior.
- A controlled test LAN or test devices.

Staging must exercise Keychain/Keystore behavior, identity migration, app update, cancellation, hostile input, and release packaging.

### 3.4 Production

Purpose: public store distribution.

Use:

- Final Android application ID and namespace.
- Final macOS bundle identifier.
- Production Google Play/App Store signing chain.
- Platform secure storage only.
- Stable production storage namespace.
- No ordinary-file identity-key fallback.
- Redacted operational diagnostics.
- Final LAN transport policy.

Production identity and trust records must survive process death, app restart, and supported app updates.

## 4. Configuration Model

Create one explicit environment configuration consumed by identity storage, trust storage, logging, networking, and release checks.

The configuration should define at least:

- Environment name: `test`, `development`, `staging`, or `production`.
- Storage namespace.
- Android application ID.
- macOS bundle identifier.
- Keychain service/account identifiers.
- Logging mode.
- Whether development fallback storage is permitted.
- Whether LAN cleartext HTTP is permitted.
- Maximum HTTP body sizes.
- Protocol version.
- Release-signing expectations.

The environment must be selected at build time or through an explicit, validated flavor configuration. Do not select production by accident because a variable is missing. Do not select a development fallback merely because a secure-storage operation throws an exception.

### 4.1 Suggested namespaces

These are examples; final names must be reviewed before implementation:

```text
oneshare.test
oneshare.development
oneshare.staging
oneshare.production
```

Apply the namespace consistently to:

- Device ID.
- Device name where persisted.
- Ed25519 identity seed.
- Trust-store record keys.
- Trust-store index.
- Keychain service/account values.
- Migration markers.

### 4.2 Required namespace properties

- Test namespaces are disposable.
- Development and staging namespaces are different.
- Production namespace is stable forever after release.
- Android and macOS production may use platform-specific storage identifiers but must preserve their own device identity across updates.
- A namespace change must be treated as an identity migration event, not a transparent rename.

## 5. Phase 0: Inventory and Baseline

Before modifying implementation:

1. Record current Git status and preserve unrelated user changes.
2. Record Flutter/Dart versions and dependency lock state.
3. Record current Android application ID, namespace, signing mode, and manifest network settings.
4. Record current macOS bundle identifier, entitlements, and secure-storage behavior.
5. Identify every constructor or singleton that creates `CryptoKeyStorage`, `TrustStore`, `DeviceIdentityService`, HTTP clients, and log output.
6. Record all current storage keys and legacy fallback-file locations.
7. Run the complete current test suite and save the result.
8. Create a baseline two-device development transfer test.
9. Capture baseline identity fingerprints only for disposable development devices.
10. Confirm that no production credentials are present in the repository or CI configuration.

Deliverables:

- Baseline test output.
- Current configuration inventory.
- Storage-key inventory.
- Disposable development-device identities.
- Decision log for unresolved transport and platform questions.

## 6. Phase 1: Establish Dependency and Configuration Isolation

Implement the environment boundary before changing production behavior.

### 6.1 Dependency injection

Make storage and trust dependencies injectable at service boundaries:

- `KeyStorage`.
- `TrustStore`.
- Device identity storage/service.
- HTTP client or transport policy where practical.
- Logging/redaction policy.

Tests must be able to inject in-memory or temporary implementations. Production must construct platform-backed implementations through the production environment configuration.

### 6.2 Build variants

Define explicit variants for Android and macOS:

- Development/debug.
- Staging/release-like.
- Production/release.

Each variant must declare its environment and identifiers. Validate at startup that the runtime environment matches the compiled application identity.

### 6.3 Isolation tests

Add tests proving:

- Development and staging storage keys differ.
- Staging and production storage keys differ.
- A development trust record cannot be read by production configuration.
- Production code cannot select a file fallback.
- Test code never instantiates default production storage.

## 7. Phase 2: Identity and Trust Migration Design

Do not change storage implementation until migration behavior is approved.

### 7.1 Identity states

Define these startup states:

1. `freshInstall`: secure storage is readable and contains no identity.
2. `identityLoaded`: existing identity restored successfully.
3. `storageUnavailable`: secure storage read failed or returned an ambiguous result.
4. `legacyDataAvailable`: legacy fallback data exists and has not been migrated.
5. `migrationRequired`: legacy data was validated and is ready for deliberate migration.
6. `identityResetRequired`: old data cannot be safely imported.

Only `freshInstall` may generate a new identity automatically.

### 7.2 Migration options

Choose and document one path before implementation:

**Validated migration:**

1. Detect the legacy development/macOS file.
2. Validate JSON structure and identity seed length.
3. Recompute the public key and fingerprint.
4. Validate trust records and fingerprint consistency.
5. Copy the identity and trust data into the intended secure namespace.
6. Verify a read-back match.
7. Mark migration complete.
8. Remove or quarantine legacy plaintext data after successful migration.

**Explicit reset:**

1. Detect data that cannot be validated or imported.
2. Stop identity-dependent services.
3. Notify the user.
4. Require explicit reset confirmation.
5. Generate a new identity only after confirmation.
6. Explain that prior peer trust must be re-established.

Never silently generate a replacement identity after a Keychain/Keystore error.

### 7.3 Environment-specific migration

A development or staging migration must never write to production storage. Production migration must be tested with a copy or synthetic fixture, never with the only live production data.

## 8. Phase 3: Implement Security Fixes in Development First

Implement protocol changes against development namespaces and disposable peer devices before staging.

### 8.1 Identity pinning

- Resolve discovered peers to trust records using stored public keys/fingerprints.
- Use discovery only as an untrusted lookup hint.
- Include `intendedReceiverIdentityPubKey` for known manually verified peers.
- Reject a mismatched pinned receiver before file transfer.
- Show identity-change warnings for changed sender identities.
- Preserve the old verified record.
- Require explicit untrusted continuation for changed identities.
- Keep first-contact peers untrusted until SAS confirmation.

### 8.2 Control messages

- Authenticate post-handshake cancel and cancel-file messages.
- Ensure cancellation is signed before session cleanup.
- Make sequence verification, action execution, cache update, and sequence advancement atomic.
- Test concurrent duplicate requests and cleanup races.

### 8.3 Validation and resource safety

- Enforce version 2 on both handshake messages.
- Validate all decoded key, signature, hash, ID, size, and sequence fields.
- Cap JSON request bodies before buffering.
- Keep encrypted stream frame and unknown-file resource limits.
- Add nonce-overflow checks.
- Ensure all terminal paths destroy session state.

### 8.4 Logging

- Redact tokens, Authorization headers, signatures, public keys where policy requires, private seeds, session keys, and complete bodies.
- Ensure error responses do not expose internal cryptographic or filesystem details.
- Add automated tests for redaction.

## 9. Phase 4: Development Verification

Run the following in development before staging:

### 9.1 Functional matrix

- Fresh device to fresh device transfer.
- Repeat transfer after SAS verification.
- Repeat transfer without SAS verification.
- Changed peer identity.
- Sender and receiver in both directions.
- Multiple files.
- Empty file.
- Large file.
- Mid-stream cancellation.
- Per-file cancellation.
- Peer disconnect.
- Concurrent send and receive.
- App background/foreground transition.
- Process death and restart.

### 9.2 Adversarial matrix

- Modified manifest.
- Modified filename or declared size.
- Modified ephemeral key.
- Invalid signature.
- Invalid token hash binding.
- Wrong intended receiver identity.
- Wrong protocol version.
- Wrong key/signature length.
- Malformed Base64.
- Oversized JSON body.
- Oversized encrypted frame.
- Missing or duplicate sentinel.
- Trailing encrypted data.
- Wrong-direction control message.
- Replay, gap, and concurrent duplicate controls.
- Storage read/write failure.

### 9.3 Evidence

Save:

- Test output.
- Sanitized protocol traces.
- Identity fingerprints for disposable devices only.
- Memory/resource observations for large transfers.
- Redacted logs.
- Results of process-death and update tests.

## 10. Phase 5: Staging Validation

Promote only after development gates pass.

### 10.1 Staging artifact requirements

- Staging identifiers are distinct from development and production.
- Staging uses secure platform storage, not test memory storage.
- Staging uses release-like optimization and error handling.
- Staging does not contain production signing keys.
- Staging logs are redacted.
- Staging can be reset without affecting production.
- Staging has the final protocol version and validation rules.

### 10.2 Staging test sequence

1. Fresh install on macOS and Android.
2. Generate identities and record fingerprints in a secure test ledger.
3. Complete first-contact SAS verification.
4. Confirm repeat transfer is trusted.
5. Restart both apps and confirm identities/trust remain stable.
6. Update both artifacts and confirm identities/trust remain stable.
7. Test changed identities and confirm rejection/warning policy.
8. Test cancellation and concurrent control messages.
9. Test malformed and oversized requests.
10. Test app backgrounding, process death, and network interruption.
11. Confirm no secrets occur in logs.
12. Reset staging data and repeat clean-install tests.

### 10.3 Staging exit criteria

- All security tests pass.
- No production namespace is read or written.
- No debug signing is present in staging release-like artifacts.
- Secure storage survives restart and update.
- Changed identity policy is demonstrated.
- Release configuration review is complete.

## 11. Phase 6: Production Preparation

Do this only after staging passes. Production credentials must be provisioned separately and never committed.

### 11.1 Android

- Set the final application ID and namespace.
- Create the production signing/upload-key process.
- Enable Google Play App Signing.
- Remove debug signing from all release variants.
- Decide and document backup/restore behavior for identity and trust data.
- Decide and test cleartext LAN HTTP policy.
- Ensure development `usesCleartextTraffic` settings do not leak into production unintentionally.
- Verify release manifest and permissions.
- Build an internal-test artifact signed through the production release process.
- Test install, update, uninstall, and restore scenarios.

### 11.2 macOS

- Set the final bundle identifier.
- Use Keychain-backed secure storage.
- Verify required entitlements for the exact secure-storage plugin and App Store signing setup.
- Remove unnecessary Debug/JIT entitlements from Release.
- Verify network client/server and file-access entitlements.
- Build an App Store-signed or distribution-signed test artifact.
- Test Keychain persistence across restart, update, reinstall, and account changes.
- Confirm no ordinary-file identity fallback exists in the store artifact.

### 11.3 Production namespace lock

Before the first public release, record and approve:

- Android application ID.
- Android namespace.
- macOS bundle identifier.
- Production storage namespace.
- Keychain service/account identifiers.
- Protocol version.
- Signing certificate fingerprints.
- Backup/restore policy.
- LAN transport policy.

Any later change requires a migration and compatibility review.

## 12. Phase 7: Production Rollout

Use a controlled rollout:

1. Produce signed artifacts from a clean CI workspace.
2. Verify artifact identifiers and signatures.
3. Run static checks for debug signing, development namespaces, plaintext fallback, and unsafe logs.
4. Distribute to internal testers first.
5. Monitor only redacted diagnostics.
6. Release through staged rollout where supported.
7. Keep rollback artifacts signed with the same production chain.
8. Do not roll back to an artifact that changes the storage namespace or protocol behavior incompatibly.
9. Record the production release version and identity/storage compatibility.

## 13. Rollback and Recovery

### 13.1 Code rollback

A rollback must preserve:

- Production application ID/bundle ID.
- Production signing chain.
- Secure-storage namespace.
- Identity key format.
- Trust-record format.

If a rollback cannot read newer trust records, stop transfer services and provide a migration path. Never silently reset identity.

### 13.2 Key-storage failure

On secure-storage failure:

- Stop advertising and transfer services.
- Do not generate a replacement identity.
- Preserve trust data.
- Show a recovery message.
- Log only a redacted error category.
- Require deliberate user action for identity reset.

### 13.3 Compromise response

If a production identity key is suspected compromised:

1. Define whether the identity can be revoked in the protocol.
2. Notify users that a reset is required.
3. Provide an explicit identity reset flow.
4. Treat all previous trust relationships as invalid.
5. Record the new identity and require SAS re-verification.
6. Rotate any affected release or service credentials.

The current protocol has no remote revocation mechanism; this limitation must be documented.

## 14. CI/CD Gates

Every pull request should run:

- Unit and integration tests.
- Static analysis.
- Dependency and license checks.
- Secret scanning.
- Log-redaction tests.
- Protocol downgrade tests.
- Body-limit and parser tests.
- Concurrent control-message tests.
- Storage namespace isolation tests.

Release CI must additionally verify:

- Final application IDs.
- Correct environment marker.
- No debug signing in release artifacts.
- No development namespace in production artifacts.
- No plaintext identity fallback in production artifacts.
- Expected entitlements.
- Redacted logging.
- Artifact signatures and hashes.
- Upgrade compatibility.

CI must fail closed if required signing or storage configuration is missing.

## 15. Security Review Checkpoints

### Checkpoint 1: Architecture

Approve:

- Environment model.
- Storage namespace model.
- Identity migration policy.
- LAN transport threat model.
- Production application identifiers.

### Checkpoint 2: Development implementation

Approve:

- Identity pinning.
- Mismatch handling.
- Atomic control processing.
- Validation and limits.
- Log redaction.

### Checkpoint 3: Staging

Approve:

- Platform secure-storage persistence.
- Update and process-death behavior.
- Release-like artifact configuration.
- Adversarial results.

### Checkpoint 4: Production release

Approve:

- Signing and entitlements.
- Final identifiers.
- Store artifact inspection.
- Migration/rollback readiness.
- Security evidence package.

## 16. Definition of Done

The rollout is complete only when:

- Development, staging, and production storage are isolated.
- Production identity survives restart and supported updates.
- Trust records survive restart and supported updates.
- The E2EE protocol remains v2 without plaintext fallback.
- Previously verified identities are pinned.
- Changed identities cannot silently inherit trust.
- Authenticated controls are atomic and race-safe.
- Inputs and resources are bounded.
- Nonces cannot wrap or repeat.
- Logs contain no secrets.
- macOS uses production Keychain storage.
- Android uses production signing and final identifiers.
- The cleartext LAN transport decision is documented and tested.
- Required automated and manual tests pass.
- Security reviewers approve the evidence package.

## 17. Immediate Next Actions

Before changing implementation:

1. Review and approve this environment model.
2. Choose final environment names and namespaces.
3. Decide whether development will use platform Keychain/Keystore or an isolated development adapter.
4. Decide validated migration versus explicit reset for legacy macOS data.
5. Define the peer identity resolution algorithm for pinning.
6. Define the full control-message lock boundary.
7. Define exact endpoint body limits.
8. Define Android cleartext LAN policy for staging and production.
9. Define final Android and macOS application identifiers before release work begins.
10. Create disposable development and staging test identities.
11. Add the CI isolation checks before provisioning production credentials.

## Final Recommendation

Implement and validate the isolation boundary first, then apply security fixes in development, promote to staging, and only afterward configure production signing and store credentials. This allows local testing to continue while preventing development state or release configuration from becoming production state.
