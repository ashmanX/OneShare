# OneShare Store-Readiness Security Implementation Specification

**Date:** 2026-09-03  
**Audience:** Security developers, platform developers, release engineers, and reviewers  
**Repository:** OneShare Flutter application  
**Protocol baseline:** End-to-End Encryption for OneShare, revised plan v6  
**Status:** Implementation specification; no application code changes are included in this document

## 1. Objective

Prepare OneShare for production distribution through the macOS App Store and Google Play while preserving the approved E2EE v2 protocol:

- X25519 ephemeral key agreement
- Ed25519 persistent device identity
- HKDF-SHA256 transcript-bound key derivation
- ChaCha20-Poly1305 authenticated file encryption
- Fingerprint-keyed trust persistence
- Explicit out-of-band SAS verification for untrusted identities
- Authenticated and sequenced post-handshake control messages

This work must not introduce plaintext file fallback, automatic trust promotion, silent protocol downgrade, or identity replacement after a key change.

## 2. Current Security Baseline

The main cryptographic primitives and encrypted stream format are implemented in:

- [e2ee_handshake.dart](lib/services/crypto/e2ee_handshake.dart)
- [encrypted_stream.dart](lib/services/crypto/encrypted_stream.dart)
- [control_message_channel.dart](lib/services/crypto/control_message_channel.dart)
- [e2ee_session.dart](lib/services/crypto/e2ee_session.dart)

Persistent identity and trust are implemented in:

- [device_identity_service.dart](lib/services/device_identity_service.dart)
- [crypto_key_storage.dart](lib/services/crypto/crypto_key_storage.dart)
- [trust_store.dart](lib/services/crypto/trust_store.dart)

Transfer and HTTP integration is implemented in:

- [transfer_service.dart](lib/services/transfer_service.dart)
- [oneshare_http_server.dart](lib/services/oneshare_http_server.dart)
- [oneshare_discovery_service.dart](lib/services/oneshare_discovery_service.dart)

The existing security review identified four protocol/integration defects and several release blockers. This specification defines the required remediation and evidence for closing them.

## 3. Non-Negotiable Security Invariants

The implementation is acceptable only if all of the following remain true:

1. File bytes are never sent in plaintext in protocol v2.
2. A v2 peer cannot silently downgrade to v1 or omit the E2EE handshake.
3. An identity fingerprint is always `SHA-256(raw Ed25519 public key)` in lowercase hexadecimal.
4. A peer marked `manuallyVerified` remains trusted only while the exact identity public key is unchanged.
5. A changed identity never overwrites the existing verified record.
6. Discovery data is an unauthenticated hint and never establishes trust.
7. First-contact and previously seen peers remain untrusted until explicit SAS confirmation.
8. Only an explicit user confirmation can create `manuallyVerified`.
9. Post-handshake control actions require the correct directional HMAC and sequence.
10. Duplicate control messages cannot execute the business action twice.
11. Nonce reuse is impossible within a file key.
12. Session keys are destroyed on completion, cancellation, failure, and timeout as far as Dart permits.
13. Private identity seeds are stored with platform secure storage in production artifacts.
14. Debug and diagnostic logs contain no bearer tokens, private keys, session keys, or complete authentication payloads.
15. Store builds are signed with production signing identities and use final application identifiers.

## 4. Workstream A: Identity Pinning and Trust Enforcement

### A.1 Pin known receiver identity in msg1

**Problem:** The sender currently sends msg1 with `intendedReceiverIdentityPubKey: null` even when the receiver was previously verified. See [transfer_service.dart](lib/services/transfer_service.dart#L832-L846).

**Required behavior:**

1. The selected discovered peer must be resolved to a persistent identity record before sending msg1.
2. The lookup must use the stored Ed25519 public key or its SHA-256 fingerprint, never `transferId`, ephemeral keys, device name alone, or a new session key.
3. If the peer has a `manuallyVerified` record, populate `intendedReceiverIdentityPubKey` with that record’s raw public key.
4. If the peer is known only as `unverifiedSeen`, the connection remains untrusted. The implementation may bind the known key if available, but must not promote trust automatically.
5. If no identity record exists, send `null` and require SAS verification before trust can be established.
6. The receiver must reject msg1 when a non-null intended receiver public key does not equal its own persistent public key.
7. The sender must reject msg2 if the returned receiver identity does not equal the intended receiver key.

The discovery service must not mark its `/info` or mDNS key as trusted. If discovery advertises a public key, it may be used as a lookup hint only until the signed handshake validates it.

### A.2 Enforce known sender identity on the receiver

The receiver currently computes a fingerprint and evaluates trust, but a conflicting identity can still create a session. See [trust_store.dart](lib/services/crypto/trust_store.dart#L78-L124) and [transfer_service.dart](lib/services/transfer_service.dart#L1610-L1631).

Required behavior for an incoming sender:

- Exact fingerprint found and `manuallyVerified`: continue as trusted.
- Exact fingerprint found and `unverifiedSeen`: continue as unverified.
- New fingerprint with no conflict: create an untrusted/unverified record according to the trust-state policy.
- New fingerprint conflicting with a previously verified device identity: preserve the old record, show an identity-change warning, and do not silently treat the new key as the same peer.
- Any “proceed as untrusted” action must be explicit and must not alter or downgrade the old verified record.

Do not compare device name as a cryptographic identity. Device name and device ID are only mismatch signals and display metadata.

### A.3 Store the canonical peer identity on the session

The active `E2eeSession` must contain:

- `peerIdentityPubKey`
- `peerFingerprint`, calculated as SHA-256 of that public key
- `peerDeviceId`, copied from transport metadata only
- `trustLevel`, loaded from `TrustStore` before the relevant transfer UI is displayed

The UI must never reconstruct a fingerprint by hex-encoding raw public-key bytes. The SAS dialog must receive the session’s canonical fingerprint and actual device ID. See [main.dart](lib/main.dart#L2313-L2358).

### A.4 Trust-store persistence and migration

The trust record must be stored under a fingerprint-derived key and the index must survive a process restart. Verify:

- `manuallyVerified` survives transfer cleanup.
- `manuallyVerified` survives application restart.
- The same identity public key produces the same fingerprint across devices and sessions.
- A changed public key produces a different fingerprint.
- Trust lookup completes before incoming request UI or transfer progress UI renders.
- Records are not deleted by `_cleanupTransferState()`.
- A record write and index update cannot leave a verified identity undiscoverable after a crash. Prefer a recoverable index or startup reconciliation for orphaned per-fingerprint records.

Any migration from the current macOS fallback must preserve the existing identity only after integrity and ownership have been established. Do not generate a new identity silently during migration if the old identity can be securely imported. If import is impossible, explicitly notify the user that the device identity changed and that prior peer trust must be re-established.

## 5. Workstream B: macOS Secure Keychain Storage

### B.1 Remove production plaintext fallback

[crypto_key_storage.dart](lib/services/crypto/crypto_key_storage.dart#L21-L70) currently writes a JSON file in application support on macOS. This is not equivalent to Keychain storage because it contains the Ed25519 private seed in a readable file.

For the store build:

1. Use `flutter_secure_storage` backed by macOS Keychain.
2. Configure the required macOS Keychain entitlements and signing configuration.
3. Test Debug, Profile, Release, and App Store-signed builds separately.
4. Confirm the same Keychain item is accessible after app relaunch and app update.
5. Confirm uninstall/reinstall behavior is understood and documented.
6. Ensure Keychain accessibility is appropriate for the application’s threat model.
7. Do not use a plaintext fallback silently when Keychain access fails.

If a development-only fallback is retained, it must be disabled in store builds and clearly labeled as non-production.

### B.2 Key-storage failure policy

Keychain read/write failures must fail closed for identity-dependent operations:

- Do not generate a new identity merely because a read temporarily failed.
- Do not start advertising a new identity until the storage state is known.
- Do not overwrite existing identity material after an ambiguous storage error.
- Surface a user-visible recovery state and provide a deliberate identity-reset flow.
- Preserve the old trust store when the identity cannot be loaded.

### B.3 Android secure storage

Verify that Android release artifacts use the secure-storage plugin with the production application ID and signing configuration. Test:

- Fresh install identity generation.
- Process death and restart.
- App update with the same signing identity.
- Device backup and restore behavior.
- Lock-screen and keystore state changes.
- Key invalidation and recovery behavior.

The private seed must not be copied into SharedPreferences, ordinary files, logs, crash reports, or backup data unless the storage is explicitly protected by the platform keystore policy.

## 6. Workstream C: Authenticated Cancellation and Control Messages

### C.1 Fix full-transfer cancellation ordering

`cancelTransfer()` currently invokes `_cleanupTransferState()` before attempting to find the session and sign the cancellation. See [transfer_service.dart](lib/services/transfer_service.dart#L417-L420) and [transfer_service.dart](lib/services/transfer_service.dart#L526-L540).

Required ordering:

1. Capture the relevant session and outgoing control channel.
2. Construct the cancellation payload.
3. Add `e2ee_ctrl` when the session has completed the handshake.
4. Send the notification and process the response without exposing secrets in logs.
5. Abort local file I/O.
6. Destroy the session and invoke `_cleanupTransferState()`.

If the peer notification fails, local cleanup must still occur. The failure must not cause keys to remain indefinitely in memory.

Pre-handshake cancellation may remain unauthenticated only for the explicitly approved pre-handshake state. It must not be used after keys are derived.

### C.2 Make control processing atomic

The current channel performs asynchronous HMAC verification before sequence state is committed. See [control_message_channel.dart](lib/services/crypto/control_message_channel.dart#L163-L220).

The critical section must include:

1. Parse and validate the control envelope.
2. Verify the correct direction.
3. Verify the HMAC.
4. Check cached sequence entries.
5. Check `expectedNextSeq`.
6. Execute the business action exactly once.
7. Store the response and MAC in the bounded cache.
8. Advance the expected sequence.

A mutex per active `(transferId, direction)` is acceptable. Locking only the HMAC calculation or only the sequence check is insufficient. The channel must also be protected against cleanup racing with an in-flight control request.

Required behavior:

- Same sequence and same MAC within the cache: return the cached response without executing again.
- Same sequence and different MAC: reject with invalid MAC.
- Older sequence outside cache: reject as duplicate/expired.
- Future sequence: reject as a gap.
- Wrong direction: reject.
- Missing authentication after handshake: reject.

### C.3 Control endpoint coverage

Audit all control endpoints, including cancel, cancel-file, reject, and any future control endpoint. The endpoint must know whether the transfer is pre-handshake, handshake-pending, or post-handshake. It must not infer authentication state solely from whether a session object happens to exist.

Reject and cancellation semantics must be documented because pre-handshake controls are intentionally vulnerable to denial of service on the plaintext LAN transport. The UI must not report an unauthenticated peer as trusted.

## 7. Workstream D: Protocol, Type, and Resource Validation

### D.1 Enforce v2 on both handshake messages

The receiver checks msg1 version, but sender msg2 processing must also require `e2ee.version == OneShareConfig.protocolVersion`. See [transfer_service.dart](lib/services/transfer_service.dart#L1880-L1908).

Reject with a generic protocol mismatch error when:

- `e2ee` is missing.
- Version is absent, non-integer, or unsupported.
- Required fields are missing.
- A v1 or unknown version is received.

There must be no silent plaintext fallback.

### D.2 Validate all decoded handshake fields

Before cryptographic operations, validate:

- Ed25519 public keys are exactly 32 bytes.
- X25519 public keys are exactly 32 bytes.
- Ed25519 signatures are exactly 64 bytes.
- Manifest hash is exactly 32 bytes.
- Token hash is exactly 32 bytes.
- Intended receiver key is either absent/null or exactly 32 bytes.
- Base64 fields decode strictly and do not contain unbounded input.
- Transfer ID and file IDs meet expected length and character constraints.
- File count is bounded.
- File names and metadata have bounded lengths.
- File sizes are non-negative and within application policy.
- Transfer token is present, correctly scoped, and not expired.

Malformed input must fail before creating session state or showing an accept dialog.

### D.3 Cap HTTP body sizes before buffering

`_readJsonBody()` currently reads the complete body with `join()`. See [oneshare_http_server.dart](lib/services/oneshare_http_server.dart#L331-L340).

Implement endpoint-specific limits for request, accept, reject, cancel, and cancel-file bodies. The cap must be enforced while reading, before the entire body is retained in memory. Oversized requests must be rejected and the connection closed or drained safely.

The limit must account for:

- Maximum file count.
- Maximum file name length.
- Maximum metadata length.
- Public keys and signatures.
- JSON overhead.

Do not use a limit large enough to permit arbitrary memory growth.

### D.4 Encrypted stream resource limits

The reader already rejects zero-length and oversized frames, but also verify:

- Total decrypted bytes cannot exceed the signed/declared file size when known.
- A policy limit exists for unknown-size files.
- Number of chunks is bounded by the nonce counter policy.
- Buffer growth is bounded when a peer sends large transport chunks.
- A frame cannot be accepted after the sentinel.
- Exactly one sentinel is required.
- The destination temporary file is deleted on every parse, authentication, cancellation, and finalization failure.

The stream parser must not retain the entire encrypted file in memory.

## 8. Workstream E: Nonce and Key Lifecycle Hardening

### E.1 Nonce bounds

Before every data or sentinel encryption/decryption operation:

- Ensure the counter is within unsigned 64-bit range.
- Ensure it has not already been used for another frame under the same file key.
- Ensure the counter cannot wrap.
- Fail the transfer before emitting a reused nonce.

The sentinel consumes the next counter value and must be included in the overflow policy.

### E.2 Session isolation

Verify that each transfer has independent:

- Ephemeral key pair.
- Transcript hash.
- Session master key.
- Directional file keys.
- Directional control keys.
- Control sequence counters and replay cache.
- Cancellation state.

Concurrent send and receive operations must never share mutable crypto state.

### E.3 Zeroization

Keep the current best-effort zeroization behavior, but document its limitations:

- Dart garbage collection does not guarantee memory erasure.
- `SecretKey` objects may retain material after references are dropped.
- Native FFI would be required for stronger deterministic guarantees.

Ensure `destroy()` is called on every terminal path, including handshake rejection, request timeout, peer disconnect, file authentication failure, finalization failure, and app shutdown.

## 9. Workstream F: Logging and Diagnostics

### F.1 Mandatory redaction

Remove or redact the following from all logs:

- `Authorization` headers.
- `transferToken`.
- `e2ee` payloads containing public keys, signatures, or tokens.
- HMAC values.
- Private identity seed material.
- Session keys and file keys.
- Full file paths where privacy policy does not permit them.
- Complete request/response bodies.

Relevant current logging includes HTTP headers and accept JSON bodies in:

- [transfer_service.dart](lib/services/transfer_service.dart#L2030-L2044)
- [oneshare_http_server.dart](lib/services/oneshare_http_server.dart#L109-L114)

Use structured event names and safe identifiers such as truncated transfer IDs. Redaction must be tested, not performed only by developer convention.

### F.2 Error responses

Peer-facing errors must not reveal cryptographic internals, stack traces, key values, storage paths, or detailed parser state. Detailed diagnostics may remain local, subject to redaction.

## 10. Workstream G: Store Release Configuration

### G.1 Android production identity and signing

The current release build uses the debug signing configuration and a placeholder application ID. See [build.gradle.kts](android/app/build.gradle.kts#L7-L29).

Before Google Play publication:

1. Set the final unique application ID and namespace.
2. Configure production release signing outside the repository.
3. Use Google Play App Signing and a protected upload key.
4. Remove debug signing from every release variant.
5. Verify CI does not print signing credentials.
6. Confirm the final application ID before any production trust data is created.
7. Test app updates using the same signing chain.

Changing the application ID or signing identity after release breaks update continuity and may isolate or invalidate stored identity/trust data.

### G.2 Android cleartext transport policy

The manifest globally enables cleartext traffic:

- [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml#L4-L10)

The current LAN protocol uses HTTP, so disabling cleartext globally may break discovery or transfer. The release decision must therefore be explicit:

- Prefer authenticated TLS or another authenticated local transport if feasible.
- If HTTP remains necessary for LAN compatibility, scope and document the exception as narrowly as the platform permits.
- Do not rely on E2EE as protection for metadata, control messages, or availability.
- Test behavior against captive portals, hostile Wi-Fi, rogue peers, and altered discovery responses.
- Ensure no unrelated application traffic is permitted to use cleartext.

This is a transport-layer release concern, separate from file-content encryption.

### G.3 macOS App Store configuration

Before macOS submission:

1. Replace the plaintext storage fallback with Keychain-backed storage.
2. Verify App Sandbox entitlements for network client/server operation.
3. Verify Keychain behavior under the App Store signing identity.
4. Keep file access limited to user-selected files and the intended downloads location.
5. Remove unnecessary debug entitlements from Release, especially JIT-related entitlements if not required by the final product.
6. Confirm the app’s network-server behavior is compatible with App Store review and clearly documented.
7. Test update, reinstall, backup, and Keychain persistence scenarios.

## 11. Application Lifecycle Requirements

At startup:

1. Initialize secure storage.
2. Load or generate the persistent device identity exactly once.
3. Fail closed if identity storage is unavailable or ambiguous.
4. Load the trust store before starting discovery, advertising, or transfer UI.
5. Start network services only after identity initialization completes.

At foreground/background transitions:

- Do not regenerate identity keys.
- Do not clear trust records.
- Do not expose stale session trust state for a new transfer.
- Stop or pause active transfer I/O according to the transfer policy.
- Destroy abandoned sessions after timeout.

At identity reset:

- Require explicit confirmation.
- Explain that all prior peer trust becomes invalid.
- Delete or archive old identity material securely.
- Clear trust records only as an explicit consequence of reset.
- Never perform this operation automatically after a transient storage failure.

## 12. Required Test Plan

### 12.1 Identity and trust

- Same stored seed restores the same Ed25519 public key and fingerprint.
- Trust survives a fresh `TrustStore` instance.
- Trust survives app restart on Android.
- Trust survives app restart and update on macOS App Store-signed builds.
- Verified peer remains verified across a second transfer.
- Changed peer key is never considered verified.
- Existing verified record is not overwritten by a changed key.
- Discovery-provided keys never create trusted records.
- UI uses SHA-256 fingerprint, not raw-key hex.
- Each device must independently complete SAS verification.

### 12.2 Identity pinning

- Known verified receiver is included in msg1 intended receiver binding.
- Correct receiver accepts the binding.
- Wrong receiver rejects it.
- Sender rejects msg2 from a receiver whose key differs from the pinned key.
- Unknown peer remains untrusted and requires SAS.
- Previously seen but unverified peer is not auto-promoted.

### 12.3 Control messages

- Cancellation after handshake includes a valid HMAC.
- Peer receives and applies authenticated cancellation.
- Cancellation before handshake follows the explicitly approved unauthenticated path.
- Two concurrent copies of one control message execute the action once.
- Cached retransmission returns the original response.
- Modified duplicate sequence is rejected.
- Wrong direction, gap, and expired sequence are rejected.
- Cleanup racing with a control request cannot execute an action twice.

### 12.4 Input and resource limits

- Oversized JSON request is rejected before unbounded allocation.
- Malformed Base64 is rejected.
- Wrong key/signature lengths are rejected.
- Wrong protocol version is rejected on msg1 and msg2.
- Excessive file count, file name length, metadata length, and declared size are rejected.
- Oversized encrypted frame is rejected.
- Frame truncation, authentication failure, missing sentinel, duplicate sentinel, and trailing bytes are rejected.
- Large files stream without proportional memory growth.

### 12.5 Key and storage security

- No identity seed appears in logs.
- No transfer token appears in logs.
- macOS production build uses Keychain rather than the fallback file.
- Android release build uses the production signing key.
- App update retains secure-storage access.
- Storage read failure does not silently generate a new identity.
- Key and session cleanup runs on every terminal path.

## 13. Review Evidence Required Before Release

Security reviewers should receive:

- The final protocol implementation diff.
- Threat model and transport decision for local HTTP.
- Keychain entitlement and plugin configuration evidence.
- Android signing and Play App Signing configuration evidence without secrets.
- macOS and Android release artifact hashes and signing verification output.
- Test results for all cases in Section 12.
- A redacted diagnostic log proving credential redaction.
- Results from a fresh-install, upgrade, process-death, and reinstall matrix.
- Confirmation that no plaintext fallback path is present in store builds.
- Confirmation that protocol version 1 is rejected.

## 14. Release Acceptance Gates

The build must not be submitted if any of these are true:

- A store build writes identity seeds to an ordinary file.
- A verified peer can be replaced without an identity-change warning or rejection policy.
- Post-handshake cancellation is unauthenticated.
- Concurrent duplicate control messages can execute twice.
- msg2 version is not enforced.
- HTTP JSON bodies can be buffered without a size limit.
- Tokens or private material appear in logs.
- Nonce overflow is not handled.
- Android release artifacts use debug signing.
- The final Android application ID is not set.
- macOS production entitlements and Keychain behavior have not been tested.
- Existing verified trust survives neither update nor restart.
- Any automatic identity regeneration can occur after ambiguous storage failure.

## 15. Recommended Implementation Order

1. Finalize production application IDs and signing strategy before migration testing.
2. Implement and test macOS Keychain storage and identity migration policy.
3. Implement identity lookup, msg1 receiver pinning, and changed-identity enforcement.
4. Fix authenticated cancellation ordering.
5. Introduce atomic control-message processing with concurrency tests.
6. Add msg2 validation, field-length validation, and HTTP body limits.
7. Add nonce bounds, stream resource limits, and complete terminal-path cleanup.
8. Redact logs and add automated redaction tests.
9. Run platform persistence, update, reinstall, and release-artifact verification.
10. Obtain security review sign-off against the acceptance gates.

## Final Assessment

The current implementation has a sound cryptographic foundation but is not yet store-ready. Completing the work in this specification should address the identified protocol and integration defects while preserving the approved E2EE design. Store readiness additionally depends on secure platform key storage, production signing, final application identity, a documented cleartext LAN transport decision, and evidence that identity and trust persist safely across real release lifecycles.
