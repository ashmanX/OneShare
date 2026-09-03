# OneShare Security, Environment Isolation, and Store-Readiness Planning Brief 

**Document purpose:** Give AI Model one complete, authoritative brief from which to audit the repository and prepare an implementation plan.  
**Requested output from Model:** A reconciled, implementation-ready plan.  
**Current request:** Plan and prepare changes first. Do not begin broad implementation until the plan is reviewed and approved.  
**Repository:** `/Users/ashmaanmainali/Projects/oneshare`  
**Platforms:** Android and macOS  
**Future distribution:** Google Play and the macOS App Store  
**Current priority:** Continue local testing safely; store submission is not immediate.  
**Publishing hold:** Phase 7 (staging validation) is complete. Phase 8 is split: **8a** (production-ready code, no accounts required) proceeds now; **8b** (account-bound enrollment and submission) stays on hold until Google Play / Apple Developer accounts exist and the human lifts the hold.

---

## 1. Instructions:

You are acting as a senior security architect and Flutter/platform engineer. Work from the actual repository, not from assumptions in this document.

### Required first phase: read-only audit

Before changing files:

1. Inspect the current repository, including uncommitted changes.
2. Identify which findings in this document are still present and which have already been fixed.
3. Compare the actual code to the approved E2EE v2 protocol below.
4. Check all platform configuration relevant to Android and macOS.
5. Run appropriate read-only tests and static analysis where practical.
6. Produce a reconciled implementation plan with file-level changes, new folders/files, dependencies, migration behavior, test changes, and risks.
7. Identify contradictions or unsafe assumptions in this brief.
8. Stop for human approval before making security-sensitive implementation changes.

Do not silently “fix” the plan by weakening requirements. If a requirement is technically incompatible with the existing protocol, explain the conflict and propose alternatives.

### Editing constraints

- Preserve the approved E2EE v2 protocol unless an explicit protocol change is approved.
- Do not weaken trust verification or introduce automatic trust promotion.
- Do not introduce plaintext file transfer in protocol v2.
- Do not silently regenerate a persistent identity after storage failure.
- Do not use production credentials, signing keys, or production secure storage during local development.
- Do not commit secrets.
- Do not overwrite unrelated user changes.
- Keep release-only configuration separate from development behavior.
- Use existing project conventions where possible.
- Avoid duplicating the whole application for each environment.
- Prefer shared code with explicit environment configuration and isolated storage namespaces.
- Run focused tests after each approved implementation slice, then the full suite before completion.

### Required planning output

Return a plan containing:

- Current-state findings, marked confirmed, already fixed, or unverified.
- Threat model and security assumptions.
- Architecture and dependency changes.
- Exact code paths and files to modify.
- Any new folders/files and why they are needed.
- Development, test, staging, and production isolation design.
- Identity and trust migration policy.
- Android and macOS platform/release work.
- Detailed test matrix and expected results.
- CI/CD checks.
- Rollback and recovery behavior.
- Security review checkpoints.
- Explicit “do now” versus “defer until release preparation” classification.
- Open decisions that require human approval.
- Definition of done and release acceptance gates.

Do not claim that a change is secure merely because a package provides a cryptographic primitive. Verify the integration, lifecycle, authentication, persistence, error handling, and platform behavior.

---

## 2. Product and Timing Context

OneShare is a local-network file-transfer application with Android and macOS clients. The application currently uses HTTP over the LAN for discovery and transfer orchestration. File data is intended to be protected by an application-level E2EE v2 protocol.

The application is eventually intended for Google Play and the macOS App Store, but it is not being submitted immediately. Remaining local and staging testing is expected.

Therefore:

- Security correctness work should be planned and implemented before more functionality builds on unsafe behavior.
- Production code readiness (Phase 8a: frozen IDs, release-signing wiring with a locally held key, prod namespaces, entitlements, transport policy) proceeds now and must not be deferred merely because publishing is on hold.
- Only account-bound enrollment and submission (Phase 8b: Play App Signing enrollment, App Store Connect records, distribution provisioning, TestFlight/rollout) may be deferred until paid accounts exist.
- Development and staging isolation must be established before production configuration is introduced.
- Local LAN testing must continue to work in development.
- Release-only restrictions must not break debug/test workflows.
- Development and test identities/trust records must never contaminate production state.

---

## 3. Current Repository Anchors

The repository is a Flutter application with these relevant areas:

```text
lib/
  main.dart
  config/
  models/
  services/
    device_identity_service.dart
    transfer_service.dart
    oneshare_http_server.dart
    oneshare_discovery_service.dart
    crypto/
      canonical_encoding.dart
      control_message_channel.dart
      crypto_key_storage.dart
      e2ee_handshake.dart
      e2ee_session.dart
      encrypted_stream.dart
      sas_verification.dart
  widgets/

test/
  canonical_encoding_test.dart
  control_message_channel_test.dart
  device_identity_service_test.dart
  e2ee_handshake_test.dart
  encrypted_stream_test.dart
  security_adversary_test.dart
  transfer_handshake_flow_test.dart
  transfer_service_test.dart
  trust_store_test.dart
  trust_ui_test.dart

android/
  app/build.gradle.kts
  app/src/main/AndroidManifest.xml

macos/
  Runner/
    DebugProfile.entitlements
    Release.entitlements
```

Important current implementation anchors to verify, not blindly trust:

- Identity initialization: `lib/services/device_identity_service.dart`
- Trust persistence: `lib/services/crypto/trust_store.dart`
- Platform storage: `lib/services/crypto/crypto_key_storage.dart`
- Handshake and key derivation: `lib/services/crypto/e2ee_handshake.dart`
- Session lifecycle: `lib/services/crypto/e2ee_session.dart`
- Encrypted streaming: `lib/services/crypto/encrypted_stream.dart`
- Control authentication: `lib/services/crypto/control_message_channel.dart`
- HTTP routing and body parsing: `lib/services/oneshare_http_server.dart`
- Transfer lifecycle: `lib/services/transfer_service.dart`
- Discovery: `lib/services/oneshare_discovery_service.dart`
- SAS UI and transfer UI: `lib/main.dart`, `lib/widgets/sas_verification_dialog.dart`

There are pre-existing tracked changes in the working tree from the trust-persistence fix. Do not revert them. Audit them in place and distinguish them from new work.

---

## 4. Approved E2EE v2 Protocol Baseline

The following protocol decisions are approved and must be preserved unless a human explicitly approves a protocol revision.

### 4.1 Primitives

- Key agreement: X25519 ephemeral key pairs.
- Persistent identity signatures: Ed25519.
- Key derivation: HKDF-SHA256.
- File encryption: ChaCha20-Poly1305 AEAD.
- Control authentication: HMAC-SHA256.
- Persistent identity storage: platform secure storage in production.

Separate Ed25519 and X25519 keys are intentional. Do not add Ed25519-to-X25519 conversion unless the protocol is formally revised.

### 4.2 Persistent identity

Each app installation has a persistent Ed25519 identity key pair and persistent device ID.

- Ed25519 private seed is generated once on a fresh installation.
- The seed is stored securely and restored across app restarts and supported updates.
- Public key bytes are 32 bytes.
- Identity fingerprint is `SHA-256(raw Ed25519 public key)` represented as lowercase hexadecimal.
- Fingerprint is the trust anchor.
- Device name and device ID are metadata only and have no cryptographic authority.
- Identity reset must be explicit and user-confirmed.
- Storage failure must not silently generate a new identity.

### 4.3 Canonical encoding

All signatures, manifests, transcripts, and MAC inputs use unambiguous length-prefixed encoding:

```text
encode_bytes(b)  = 4-byte big-endian byte length || b
encode_string(s) = encode_bytes(UTF-8(s))
encode_uint64(v) = 8-byte big-endian unsigned integer
encode_uint32(v) = 4-byte big-endian unsigned integer
encode_uint16(v) = 2-byte big-endian unsigned integer
encode_byte(v)   = one byte
```

### 4.4 Manifest hash

Sort files by `fileId` lexicographically by byte/order-compatible string comparison. For each file, encode:

```text
encode_string(fileId)
encode_string(fileName)
encode_uint64(fileSize)
```

Then hash:

```text
encode_string("oneshare-manifest-v2")
encode_uint32(fileCount)
manifestEntries
```

The manifest hash must bind file IDs, names, sizes, count, and ordering-independent file membership.

### 4.5 Message 1: sender to receiver

The transfer request contains an `e2ee` object:

```json
{
  "version": 2,
  "manifestHash": "base64(32 bytes)",
  "senderIdentityPubKey": "base64(32 bytes)",
  "senderEphemeralPubKey": "base64(32 bytes)",
  "senderEphemeralSig": "base64(64 bytes)",
  "intendedReceiverIdentityPubKey": "base64(32 bytes) or null"
}
```

The sender signature covers:

```text
encode_string("oneshare-e2ee-v2-msg1-initiator")
encode_string(transferId)
encode_bytes(manifestHash)
encode_bytes(senderEphemeralPubKey)
encode_bytes(intendedReceiverIdentityPubKey or empty bytes)
```

### 4.6 Message 2: receiver to sender

The transfer accept response contains:

```json
{
  "version": 2,
  "receiverIdentityPubKey": "base64(32 bytes)",
  "receiverEphemeralPubKey": "base64(32 bytes)",
  "receiverEphemeralSig": "base64(64 bytes)"
}
```

The receiver signature covers:

```text
encode_string("oneshare-e2ee-v2-msg2-responder")
encode_string(transferId)
encode_bytes(manifestHash)
encode_bytes(tokenHash)
encode_bytes(receiverEphemeralPubKey)
encode_bytes(senderEphemeralPubKey)
encode_bytes(senderIdentityPubKey)
```

`tokenHash = SHA-256(UTF-8(transferToken))`.

Both directions must enforce protocol version 2 and validate field lengths before cryptographic operations.

### 4.7 Transcript and keys

The transcript contains protocol version, transfer ID, manifest hash, token hash, both identity public keys, and both ephemeral public keys using canonical encoding. Its SHA-256 result is the transcript hash.

Derive:

- Session master key from X25519 shared secret using HKDF-SHA256 with transcript hash as salt.
- Sender file base key.
- Receiver file base key.
- Sender control key.
- Receiver control key.
- SAS material.

Use direction-separated HKDF info strings exactly as specified by the protocol. Do not reuse keys across directions or sessions.

### 4.8 Per-file encryption

Derive each file key from the directional file base key, transcript hash, and canonical info containing:

```text
encode_string("oneshare-e2ee-v2-file-key")
encode_string(fileId)
```

Each file starts its own chunk counter at zero.

Frame format:

```text
4-byte big-endian ciphertext length
ciphertext plus 16-byte Poly1305 tag
...
4-byte length
16-byte authenticated sentinel ciphertext
EOF
```

Data frame:

- Plaintext maximum: 65,536 bytes.
- Nonce: four zero bytes followed by 8-byte big-endian counter.
- AAD: `OS2|transferId|fileId|D|counter`.

Sentinel frame:

- Empty plaintext.
- Next nonce counter.
- AAD: `OS2|transferId|fileId|F|counter|totalPlaintextBytes`.

Receiver must reject malformed lengths, oversized frames, invalid tags, empty data chunks, missing sentinel, duplicate/trailing data, and size mismatches.

### 4.9 Authenticated control messages

After handshake completion, control messages require directional HMAC-SHA256.

MAC input:

```text
encode_string("oneshare-e2ee-v2-ctrl")
encode_string(transferId)
encode_string(direction)
encode_uint64(sequence)
encode_string(canonicalJson(bodyWithoutE2eeCtrl))
```

Control state is per transfer and direction:

- Sequence starts at 1.
- Recent handled cache holds up to 16 entries.
- Same sequence and same MAC within cache returns the original response without re-executing.
- Same sequence with different MAC is rejected.
- Old sequence outside cache is rejected.
- Future sequence gap is rejected.
- Wrong direction is rejected.
- Missing authentication after handshake is rejected.

Atomicity must cover verification, sequence decision, business action, cache update, and sequence advancement.

### 4.10 Trust model

Trust levels:

- `untrusted`: encrypted, first contact/not yet recorded.
- `unverifiedSeen`: identity seen before but never SAS-verified.
- `manuallyVerified`: explicit out-of-band SAS confirmation.

Rules:

- Discovery keys are untrusted hints only.
- First contact requires SAS to establish trust.
- Merely seeing a key never promotes trust.
- Only explicit user confirmation creates `manuallyVerified`.
- A manually verified identity remains trusted only while the exact public key is unchanged.
- A changed key never overwrites the old verified record.
- Each device stores trust independently.

### 4.11 Known-peer identity pinning

For a peer with a stored manually verified identity:

1. Resolve the selected discovery candidate to the stored peer record.
2. Bind the stored raw Ed25519 public key in msg1 as `intendedReceiverIdentityPubKey`.
3. Receiver rejects if its identity does not match.
4. Sender rejects msg2 if receiver identity does not match the pinned key.
5. Unknown peers may use null binding and require SAS.
6. Previously seen but unverified peers remain untrusted.

The plan must define the resolution algorithm. Do not use device name or device ID as the ultimate trust anchor.

---

## 5. Findings and Required Security Work

must verify these against the current code and mark each as confirmed or resolved.

### Finding 1: Identity pinning

Previously verified peers were not cryptographically pinned in msg1. The required work is:

- Resolve a selected peer to its stored identity record.
- Bind the stored public key for manually verified peers.
- Validate the returned msg2 identity against the pinned key.
- Handle changed identities explicitly and safely.
- Preserve the old record.
- Do not automatically promote new keys.

### Finding 2: macOS secure storage

The existing macOS implementation has used an application-support JSON fallback containing sensitive values. Production must use macOS Keychain through the secure-storage plugin.

Required work:

- Remove or disable plaintext identity-key fallback in production.
- Verify exact plugin and entitlement requirements instead of guessing entitlement names.
- Define migration or explicit-reset policy for legacy data.
- Fail closed on ambiguous Keychain errors.
- Never regenerate silently after read failure.
- Test Debug, Profile, Release, and App Store-signed behavior separately.
- Keep development storage isolated from production storage.

### Finding 3: cancellation ordering

The implementation previously cleaned up the E2EE session before signing/sending cancellation. Required work:

- Capture session/control channel first.
- Sign post-handshake cancellation before cleanup.
- Send notification.
- Abort local I/O.
- Destroy session and clean up.
- Ensure cleanup still occurs if notification delivery fails.
- Test handshake-pending, upload, receive, between-file, peer-race, and cleanup-race cases.

### Finding 4: atomic control verification

Async HMAC verification and later business-action execution can race across concurrent HTTP requests. Required work:

- Lock per active transfer and direction/session.
- Include HMAC verification, replay decision, business action, cache update, and sequence advancement in one atomic operation.
- Prevent cleanup from destroying state during accepted action execution.
- Test concurrent duplicates and cache behavior.

### Finding 5: protocol/version and field validation

Required work:

- Enforce v2 on msg1 and msg2.
- Reject absent, non-integer, or unsupported versions.
- Validate all decoded key, signature, hash, ID, size, and sequence fields.
- Validate strict Base64 and exact cryptographic field lengths.
- Reject malformed input before session creation or UI exposure.
- Do not expose cryptographic internals in peer-facing errors.

### Finding 6: HTTP body/resource limits

Required work:

- Bound JSON body reads before complete buffering.
- Return `413 Payload Too Large` for oversized bodies.
- Do not convert malformed/oversized input into `{}`.
- Use justified endpoint-specific limits.
- Bound file count, filenames, metadata, declared sizes, unknown-size files, frame count, and parser buffers.
- Preserve streaming and avoid whole-file memory growth.

### Finding 7: logging

Required work:

- Redact Authorization headers and bearer tokens.
- Redact transfer tokens, signatures, HMACs, private seeds, session/file keys, and complete handshake bodies.
- Review file paths and metadata for privacy.
- Add automated redaction tests.

### Finding 8: identity mismatch handling

Required work:

- Do not overwrite a manually verified record after a new key appears.
- Show identity-change warning with appropriate old/new fingerprint information.
- Reject by default.
- Allow continuation only through explicit “Proceed as Untrusted” behavior if that policy is approved.
- Never mark the new identity verified automatically.

### Finding 9: nonce and key lifecycle

Required work:

- Add explicit 64-bit nonce counter overflow checks before use/increment.
- Ensure no counter reuse under a file key.
- Preserve per-file/session isolation.
- Invoke cleanup on every terminal path.
- Document Dart GC limitations for deterministic zeroization.

### Finding 10: store configuration

Required work before actual store submission (split into 8a now / 8b on account hold):

**Phase 8a — do now, no accounts required:**

- Freeze final Android application ID / namespace and final macOS (+ iOS) bundle identifier(s).
- Wire production release signing to a locally held key outside the repository; remove debug signing from every release variant.
- Android cleartext LAN policy decision and scoping.
- macOS release entitlements and permissions review.
- No production plaintext storage fallback.
- Update / reinstall / persistence testing with locally signed `--release --dart-define=ENV=production` builds.

**Phase 8b — deferred until paid accounts exist:**

- Google Play App Signing enrollment and upload-key registration.
- macOS App Store / App Store Connect distribution signing and provisioning.
- Store submission setup, TestFlight / staged rollout, and store-side verification.

Only 8b may remain deferred while local testing continues; 8a configuration boundaries must be implemented now so a later ID or signing change cannot orphan `oneshare.prod.*` trust data.

---

## 6. Environment Isolation Requirements

Isolation means keeping test, development, staging, and production security state and release settings separate. It does not mean preventing the Android and macOS production applications from communicating.

### 6.1 Environment model

```text
Unit tests  -> in-memory/temp storage, mocked network
Development -> debug build, development identity/trust, LAN HTTP allowed for testing
Staging     -> release-like build, staging identity/trust, staging signing
Production  -> store build, platform secure storage, production signing and stable identity
```

### 6.2 Storage isolation

Each environment must have a distinct namespace for:

- Device ID.
- Device name.
- Ed25519 private seed.
- Trust-store records.
- Trust-store index.
- Keychain service/account identifiers.
- Migration markers.

Example names, subject to review:

```text
oneshare.test
oneshare.development
oneshare.staging
oneshare.production
```

Production namespace must remain stable across supported updates. Debug and staging data must never be read as production data.

### 6.3 Application/signing isolation

Where practical use separate identifiers:

```text
Android debug:   com.example.oneshare.debug
Android staging: com.example.oneshare.staging
Android release: com.example.oneshare

macOS debug:     com.example.oneshare.debug
macOS staging:   com.example.oneshare.staging
macOS release:   com.example.oneshare
```

Final values must be chosen before production signing. Do not change store identifiers after first public release.

### 6.4 Configuration isolation

Each build environment must define explicitly:

- Environment marker.
- Storage namespace.
- Application/bundle identifier.
- Logging policy.
- LAN cleartext policy.
- Whether development fallback storage is permitted.
- Expected protocol version.
- Release-signing expectation.

Missing configuration must fail closed rather than defaulting to production or silently enabling an insecure fallback.

### 6.5 Test isolation

Tests must:

- Inject `InMemoryKeyStorage` or temporary storage.
- Avoid real developer Keychain/Keystore.
- Reset trust state between tests.
- Use unique transfer IDs.
- Use disposable identities.
- Include integration fixtures for pinned, untrusted, previously seen, verified, and changed identities.

### 6.6 Local testing compatibility

Security changes must not unnecessarily break development:

- Development LAN HTTP can remain enabled until transport policy is finalized.
- Debug builds may use debug signing.
- Development-only reset tools may exist outside production.
- Production-only signing and store provisioning remain deferred.
- Development storage must be isolated and never used as a production fallback.

---

## 7. Phased Execution Plan

The implementation must be planned and executed as separate phases. Do not combine all phases into one large change. Each phase has a narrow objective, permitted scope, required validation, and an explicit gate. The next phase must not begin until its gate passes and the resulting changes are reviewed.

### Phase 0: Read-Only Audit and Baseline

**Objective:** Establish the actual current state before editing.

**Permitted work:** Repository inspection, dependency inspection, static analysis, existing tests, platform configuration review, and documentation updates only.

**Required outputs:**

- Confirmed, resolved, and unverified findings.
- Current working-tree change inventory.
- Current identity/trust storage map.
- Current Android/macOS build and signing map.
- Current protocol and transfer-flow map.
- List of contradictions between this brief and the repository.
- Proposed file/folder change list.
- Proposed environment and namespace model.

**Gate:** Human approval of the reconciled implementation plan. No security-sensitive code changes begin before this gate.

### Phase 1: Test and Environment Isolation Foundation

**Objective:** Make it possible to test changes without touching production-like state.

**Scope:**

- Define explicit test, development, staging, and production environment configuration.
- Introduce dependency injection for storage, identity, trust, transport, and logging where required.
- Define and validate environment-specific storage namespaces.
- Ensure unit tests use in-memory or temporary storage.
- Ensure development LAN testing remains functional.
- Add CI checks preventing production namespace or credentials in tests.

**Required validation:** Existing test suite passes. Isolation tests prove that test/development/staging storage cannot read production storage and that development fallback behavior cannot be selected by production configuration.

**Gate:** Security review confirms that the remaining phases can be implemented and tested without production credentials or production trust data.

### Phase 2: Persistent Identity and Trust State

**Objective:** Establish stable identity and correct trust-state behavior before pinning depends on it.

**Scope:**

- Verify persistent Ed25519 identity restoration and fingerprint derivation.
- Define secure-storage failure states and explicit identity-reset behavior.
- Verify trust-store persistence, reload, update, and cleanup behavior.
- Define peer identity resolution from discovery candidates to stored identity records.
- Define legacy-data migration or explicit-reset policy.
- Preserve the three-state trust model and independent per-device trust.

**Required validation:** Fresh install, restart, process death, repeat transfer, trust reload, identity change, storage failure, and reset tests pass in development/test environments.

**Gate:** Identity and trust data are stable, isolated, recoverable, and never silently regenerated or promoted.

### Phase 3: Identity Pinning and Mismatch Enforcement

**Objective:** Bind known verified peers to their persistent identity keys.

**Scope:**

- Populate `intendedReceiverIdentityPubKey` for known manually verified receivers.
- Verify the binding at the receiver.
- Verify msg2 identity against the sender’s pinned key.
- Implement receiver-side changed-identity warning/rejection behavior.
- Preserve the old verified record.
- Require explicit untrusted continuation if that policy is approved.
- Keep discovery keys as untrusted hints only.

**Required validation:** Correct pinned peer succeeds, wrong pinned peer fails before normal acceptance, changed verified identity cannot inherit trust, unknown peers remain untrusted, and SAS verification remains explicit.

**Gate:** Security review confirms peer resolution and changed-key policy are unambiguous and tested.

### Phase 4: Authenticated Control and Cancellation

**Objective:** Make post-handshake control actions authenticated, idempotent, and race-safe.

**Scope:**

- Authenticate post-handshake cancel and cancel-file messages.
- Sign notifications before session cleanup.
- Define the full lock boundary around HMAC verification, sequence decision, business action, cache update, and sequence advancement.
- Protect cleanup races.
- Preserve the approved pre-handshake unauthenticated behavior only where explicitly allowed.

**Required validation:** Valid controls succeed, duplicates execute once, cached responses are stable, gaps and old sequences fail, wrong directions fail, cancellation reaches the peer authenticated, and cleanup races do not duplicate actions.

**Gate:** Concurrency and cancellation tests pass with no unauthenticated post-handshake path.

### Phase 5: Protocol, Input, and Resource Hardening

**Objective:** Reject malformed, oversized, downgraded, and resource-exhausting input safely.

**Scope:**

- Enforce protocol version 2 on msg1 and msg2.
- Validate all decoded cryptographic fields and types before use.
- Implement bounded HTTP body parsing with correct 413 handling.
- Reject malformed JSON rather than treating it as an empty object.
- Bound file count, names, metadata, sizes, unknown-size transfers, encrypted frames, parser buffers, and frame count.
- Add nonce overflow checks.
- Verify complete stream cleanup on all failure paths.

**Required validation:** Adversarial protocol, HTTP, stream, parser, and nonce tests pass. Large transfers do not cause whole-file memory growth.

**Gate:** Input and resource limits are documented, justified, and exercised by automated tests.

### Phase 6: Logging, Diagnostics, and Recovery

**Objective:** Prevent sensitive data leakage and make failures recoverable without identity loss.

**Scope:**

- Centralize redaction for tokens, headers, signatures, keys, bodies, and private metadata.
- Remove unsafe complete-body/header logging.
- Ensure peer-facing errors are generic and safe.
- Verify session destruction on every terminal path.
- Document Dart zeroization limitations.
- Implement storage failure, identity reset, and compromise recovery behavior.

**Required validation:** Automated redaction tests pass; logs contain no credentials or key material; storage failures fail closed; rollback/recovery behavior is tested.

**Gate:** Security review approves diagnostics, recovery behavior, and residual key-memory risk.

### Phase 7: Staging and Release-Like Validation

**Objective:** Validate the complete security implementation in isolated release-like artifacts.

**Scope:**

- Use staging identifiers, signing, storage namespaces, and disposable identities.
- Test macOS Keychain behavior under staging/release-like signing.
- Test Android secure storage under staging/release-like packaging.
- Run full functional, adversarial, concurrency, lifecycle, migration, and update tests.
- Verify local LAN testing and the selected cleartext transport policy.
- Inspect artifacts for debug configuration, fallback storage, unsafe logs, and namespace leakage.

**Required validation:** Staging exit criteria and the complete test/evidence matrix pass on both platforms.

**Gate:** Release engineering and security approve promotion to production preparation.

### Phase 8a: Production-Ready Code Without Accounts

**Objective:** Make the codebase store-submittable without requiring paid Google Play / Apple Developer accounts yet. Holding off on publishing must not block this phase.

**Scope (no accounts required):**

- Freeze final Android application ID / namespace and final macOS (+ iOS) bundle identifier(s). Replace all `com.example.droplan` values. Do this before any `oneshare.prod.*` identity is created.
- Remove `signingConfigs.getByName("debug")` from every release variant. Wire release signing to a local upload key / self-managed keystore held outside the repository (never committed). Document key custody and rotation without pasting secrets.
- Verify `flutter build ... --release --dart-define=ENV=production` succeeds locally on Android and macOS and runs against disposable prod-namespace identities.
- Confirm production Keychain / Keystore namespaces (`oneshare.prod.*`), no plaintext fallback in prod, fail-closed storage errors, and preserved trust across restart / update with the final IDs.
- Finalize Android cleartext LAN policy decision and scope, release entitlements, permissions (`INTERNET`, multicast, `NEARBY_WIFI_DEVICES` / `POST_NOTIFICATIONS` where applicable), backup/restore policy, file-access review, and update/reinstall behavior.
- Draft store metadata without submitting: Data Safety / privacy labels text, permission justifications (`NSLocalNetworkUsageDescription`, `NSBonjourServices`), icons, versioning, and release notes.
- Produce the security evidence package and store artifacts for review (hashes, signing verification output with secrets redacted, test matrix results).

**Required validation:** Local production-flagged release artifacts pass identifier, signature-config, entitlement, storage, update, migration, logging, and protocol checks. No store submission occurs in this phase.

**Gate:** Security + release-engineering approval that the tree is production-freezable: IDs frozen, debug signing gone from release, prod namespace stable, evidence package complete. Paid accounts are explicitly not required to pass this gate.

### Phase 8b: Account-Bound Store Enrollment and Submission

**Objective:** Enroll, sign with store authority, and submit only after 8a is approved and paid accounts exist. Publishing remains on hold until the human explicitly lifts it.

**Prerequisites:** Google Play Console account and Apple Developer Program membership; app records created; final IDs from 8a reserved and unchanged.

**Scope (accounts required):**

- Google Play: create app, enroll in Play App Signing, register the 8a upload key, configure release track, Data Safety form, content rating, store listing, and staged rollout.
- Apple: create App Store Connect record(s), issue distribution provisioning profiles, configure App Store distribution signing, notarization (macOS) / TestFlight, privacy nutrition labels, and review notes (notably LAN server + Bonjour / local-network justification).
- Re-verify production Keychain / Keystore behavior under the real store signing identities (not just local release keys). Re-run the update / reinstall / backup matrix on store-signed builds.
- Confirm no identifier, signing-identity, or namespace change slipped in between 8a approval and submission. Any such change restarts 8a verification because it can orphan `oneshare.prod.*` trust data.
- Submit / stage rollout only on explicit human approval.

**Required validation:** Store-signed artifacts pass the full 8a check suite plus store-side verification (signature chain, entitlement, identifier, and persistence under store identity). Review submissions are traceable to the approved 8a commit.

**Gate:** Formal security and release approval for store submission, plus human lift of the publishing hold.

### Phase transition rules

- A failed phase is fixed within that phase and revalidated before proceeding.
- Do not mix production signing or production storage into development or staging work.
- Do not change protocol semantics while fixing environment or release configuration without an explicit protocol review.
- Keep each phase’s changes separately reviewable and revertible.
- Record test results, configuration values, and known residual risks at every gate.

## 8. Required Workstreams to Plan

### Workstream A: Environment/configuration foundation

Plan:

- Environment configuration object and build selection.
- Dependency injection for storage, trust store, identity, transport, and logging.
- Namespace generation and validation.
- Build variants/flavors.
- Static/CI checks preventing configuration leakage.
- New folders/files only when they remove real duplication or match project conventions.

### Workstream B: Identity and trust

Plan:

- Persistent identity loading/generation.
- Secure-storage failure state machine.
- Trust persistence and startup loading.
- Peer identity resolution.
- Identity pinning.
- Changed-key policy.
- Explicit SAS verification.
- Trust migration and reset behavior.

### Workstream C: macOS Keychain and Android secure storage

Plan:

- Exact plugin configuration and platform behavior.
- Entitlements and signing requirements.
- Debug/staging/production storage separation.
- Legacy fallback migration or explicit reset.
- Backup/update/reinstall behavior.
- Failure and recovery UI.

### Workstream D: Protocol and transfer security

Plan:

- Handshake state machine enforcement.
- msg1/msg2 validation and version negotiation.
- Transcript/key derivation verification.
- Encrypted stream limits and nonce bounds.
- Session cleanup and best-effort zeroization.
- Control-message authentication, locking, sequencing, and cleanup races.
- Cancellation ordering.

### Workstream E: HTTP and resource hardening

Plan:

- Bounded request-body parsing.
- Endpoint-specific limits.
- Correct 400/401/409/413/415/422/500 behavior as appropriate.
- No malformed-input-to-empty-map behavior.
- Request concurrency and cleanup behavior.
- File/frame/unknown-size limits.

### Workstream F: Logging and observability

Plan:

- Central redaction policy.
- Safe structured diagnostics.
- No secrets in logs, errors, crash reports, or analytics.
- Automated regression tests for redaction.

### Workstream G: Android and macOS release readiness

Plan in two slices (8a now, 8b on account hold):

**8a — production-ready code (no accounts):**

- Freeze final identifiers (do not change after first prod identity is created).
- Wire production release signing to a locally held key; remove debug signing from release.
- Entitlements, cleartext LAN policy, permissions and file-access review.
- Backup/restore policy, store-artifact inspection, update/reinstall testing on locally signed release builds.

**8b — store enrollment and submission (accounts required):**

- Google Play App Signing enrollment and upload-key registration.
- macOS App Store / App Store Connect distribution signing and provisioning.
- Store-side artifact verification and staged rollout / submission.

---

## 8. Do Now Versus Defer

### Do now

These affect correctness, security, or future architecture and should not be deferred merely because store submission is later:

- Environment isolation design and injectable dependencies.
- Development/test/staging/production storage namespaces.
- Identity pinning and changed-identity behavior.
- Secure-storage failure semantics.
- Authenticated cancellation ordering.
- Atomic control-message processing.
- msg1/msg2 version and field validation.
- Bounded HTTP body parsing.
- Encrypted-stream resource limits and nonce bounds.
- Log redaction.
- Development/staging persistence and adversarial tests.
- CI checks preventing production configuration leakage.
- Phase 8a production-freeze work (frozen IDs, local release-signing wiring, prod-namespace verification, entitlement and transport review) even while publishing stays on hold.

### Proceed in Phase 8a (publishing hold does not block)

These require decisions but not paid accounts, so they belong in 8a:

- Freeze final public application IDs and bundle identifiers.
- Wire production release signing to a locally held key outside the repository (no secrets committed).
- Final production Keychain / Keystore namespaces (`oneshare.prod.*`).
- Final Android cleartext LAN policy and permission review.
- Release entitlements, backup/restore policy, update/reinstall testing, and evidence package.

### Defer until Phase 8b (paid accounts + explicit human lift of the hold)

Only these require store accounts or submission decisions:

- Google Play App Signing enrollment and upload-key registration.
- macOS App Store / App Store Connect distribution signing and provisioning.
- Production provisioning and store submission / TestFlight / staged rollout setup.
- Store metadata submission and rollout execution.

The plan must still specify how deferred 8b settings will be introduced without changing the frozen 8a production identity, identifiers, or namespaces after release. Any post-8a identifier or signing-identity change restarts 8a verification.

---

## 9. Required Test and Evidence Matrix

### 9.1 Unit and protocol tests

- Canonical encoding vectors.
- Manifest hash is order-independent.
- Modified manifest fails.
- msg1 and msg2 signatures reject altered fields.
- Intended receiver mismatch fails.
- Transcript differs when any bound field differs.
- Both peers derive identical session keys.
- Directional keys differ.
- Per-file keys differ by file ID and direction.
- Unknown peer remains untrusted.
- Previously seen peer remains unverified.
- Explicit SAS confirmation creates manually verified state only.
- Verified state survives fresh store reload.
- Changed identity never inherits trust.

### 9.2 Stream tests

- Single chunk round trip.
- Multi-chunk round trip.
- Empty file sentinel.
- Missing sentinel.
- Duplicate sentinel.
- Reordered frame.
- Tampered ciphertext.
- Wrong AAD.
- Wrong nonce.
- Wrong sentinel byte count.
- Trailing bytes.
- Zero-length frame.
- Oversized frame.
- Large file without whole-file memory growth.
- Unknown-size policy enforcement.
- Nonce overflow before reuse.

### 9.3 Control tests

- Valid HMAC and sequence.
- Wrong direction.
- Invalid HMAC.
- Sequence gap.
- Expired sequence.
- Cached idempotent replay.
- Modified duplicate.
- Concurrent duplicate requests execute once.
- Cleanup race.
- Authenticated post-handshake cancellation.
- Approved unauthenticated pre-handshake behavior.

### 9.4 HTTP/input tests

- 413 oversized body.
- Malformed JSON is rejected.
- Malformed Base64 is rejected.
- Wrong field types are rejected.
- Wrong key/signature lengths are rejected.
- Excessive file count/name/metadata is rejected.
- Negative and excessive file sizes are rejected.
- Protocol downgrade is rejected on both messages.
- Peer-facing errors do not leak internal details.

### 9.5 Platform tests

- Android fresh install.
- Android process death/restart.
- Android update with same signing identity.
- Android backup/restore policy.
- Android secure-storage key invalidation behavior.
- macOS fresh install.
- macOS restart.
- macOS update under App Store signing.
- macOS Keychain read/write failure.
- macOS legacy migration or explicit reset.
- macOS reinstall behavior.
- No ordinary-file private seed in store artifact.

### 9.6 Build and CI tests

- Environment namespace isolation.
- Production artifact contains final identifier.
- Release artifact is not debug-signed.
- Production artifact cannot select development fallback storage.
- Signing secrets are not printed.
- Debug/staging configuration cannot be packaged as production.
- Log-redaction checks pass.
- Dependency/security/license checks pass.
- Full Flutter test and analyzer pass.

---

## 10. Operational Recovery and Rollback

### Storage failure

- Stop advertising and transfer services.
- Do not generate a new identity.
- Preserve trust data.
- Show recovery UI.
- Log only a redacted category.
- Require deliberate identity reset.

### Identity compromise

The current protocol has no remote identity revocation. model must document this limitation and design an explicit recovery flow:

1. Notify the user.
2. Require identity reset.
3. Invalidate prior local trust relationships.
4. Generate a new identity only after explicit confirmation.
5. Require SAS re-verification.

### Code rollback

A rollback must preserve:

- Application/bundle identifiers.
- Signing chain.
- Production storage namespace.
- Identity key format.
- Trust-record format.
- Protocol compatibility.

If an older version cannot read newer trust data, fail closed with migration/recovery rather than silently resetting identity.

---

## 11. Security Review Checkpoints

### Checkpoint 1: Planning

Review:

- Current-state audit.
- Environment model.
- Namespace design.
- Peer identity resolution.
- Migration policy.
- Mutex scope.
- HTTP limits.
- Android/macOS release strategy.

### Checkpoint 2: Development implementation

Review:

- Security fixes in development namespace.
- Unit/protocol tests.
- Adversarial tests.
- Local two-device transfer behavior.
- No production credential access.

### Checkpoint 3: Staging

Review:

- Release-like artifacts.
- Platform secure storage.
- Process death and update persistence.
- Identity mismatch behavior.
- Control concurrency.
- Resource limits.
- Redacted logs.

### Checkpoint 4a: Production-freeze review (Phase 8a, no accounts)

Review:

- Frozen final identifiers and `oneshare.prod.*` namespace stability.
- Local release-signing wiring (debug signing gone from release; upload key held outside repo).
- Keychain/Keystore behavior on locally signed `--release --dart-define=ENV=production` builds.
- Cleartext transport policy and permission review.
- Store artifact inspection (local), migration/rollback readiness, evidence package.

### Checkpoint 4b: Store enrollment review (Phase 8b, accounts required)

Review:

- Play App Signing enrollment and upload-key registration without secret leakage.
- App Store Connect records, distribution provisioning, and store signing identities.
- Re-verification of Keychain/Keystore persistence under real store identities.
- Confirmation that no identifier, namespace, or signing-identity drift occurred since 4a.

### Checkpoint 5: Release approval (publishing hold must be explicitly lifted)

Review:

- All acceptance gates (8a + 8b).
- Test/evidence package traceable to the approved 8a commit.
- Threat model.
- Security sign-off.
- Operational recovery plan.

---

## 12. Definition of Done

The planning phase is complete when model has produced a plan that:

- Reconciles this brief with the actual repository.
- Separates confirmed findings from already-fixed items.
- Defines identity resolution without trusting discovery as proof.
- Defines changed-identity handling and user-visible policy.
- Places the control mutex around business execution, not only HMAC verification.
- Defines bounded HTTP parsing and correct 413 behavior.
- Defines macOS migration and Keychain failure behavior.
- Defines development/staging/production isolation without breaking local testing.
- Separates immediate security work from deferred store credentials.
- Identifies all new folders/files and their purpose.
- Defines tests for normal, adversarial, concurrent, lifecycle, platform, and release behavior.
- Defines CI checks and security review evidence.
- Stops before implementation for unresolved human decisions.

The implementation phase is complete only when:

- The approved E2EE v2 protocol remains intact.
- Development, staging, and production security state is isolated.
- Production identity and trust survive supported updates.
- Verified identities are pinned and changed identities cannot silently inherit trust.
- Control actions are authenticated and race-safe.
- Inputs, frames, files, and counters are bounded.
- Secrets are absent from logs and ordinary production files.
- macOS production storage uses Keychain.
- Android release artifacts use frozen final identifiers and 8a production-signing wiring (debug signing absent); 8b store signing is verified separately once accounts exist.
- Required tests and security evidence pass for the 8a commit; 8b re-verification is required if identifiers or signing identities change.

---

## 13. Immediate Questions Must Resolve or Escalate

The plan must not mark these as “none” without evidence:

1. How exactly does a discovered peer map to a stored fingerprint/public key?
2. What happens when multiple trust records match the same device metadata?
3. Is a changed verified identity rejected outright or allowed only through explicit untrusted continuation?
4. What exact Keychain entitlement/configuration is required for the selected plugin version and App Store signing mode?
5. How are existing plaintext fallback records migrated or explicitly reset?
6. Does the control lock include business action and cleanup synchronization?
7. What exact body limits are used per endpoint and why?
8. What is the maximum unknown-size file policy?
9. What is the Android backup/restore policy for identity and trust data?
10. Is LAN HTTP acceptable for staging and production, and how is cleartext scoped?
11. What are the frozen final Android application ID and macOS (+ iOS) bundle identifier(s) for Phase 8a, and have they been applied before any prod identity exists?
12. Which release-only settings belong in 8a versus 8b, and how will 8b enrollment avoid changing the frozen 8a production identity, identifiers, or namespaces?
13. How are development, staging, and production Keychain/Keystore namespaces separated?
14. What is the recovery process if secure storage becomes unreadable?

---

## 14. Final Handoff Instruction

Use this document as the single planning brief. Start with a read-only audit of the repository and current working tree. Reconcile every requirement against actual code and platform configuration. Produce the detailed implementation plan, identify unresolved decisions, and wait for approval before modifying security-sensitive code.

The desired outcome is a safe progression:

```text
Read-only audit
    -> reconciled plan
    -> environment/test isolation
    -> development implementation
    -> development verification
    -> staging artifacts and tests (Phase 7 complete)
    -> production-freeze code without accounts (Phase 8a)
    -> account-bound enrollment and submission (Phase 8b, on hold)
    -> store evidence and security approval
```
