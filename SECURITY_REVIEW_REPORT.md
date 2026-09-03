# OneShare E2EE Security Review

**Review date:** 2026-09-03  
**Scope:** Current implementation compared with `implementation_plan_Gemini revised.md` (v6)  
**Review type:** Read-only security and protocol review  
**Code changes made during review:** None

## Executive Summary

The implementation correctly applies the main cryptographic primitives: X25519 for ephemeral key agreement, Ed25519 signatures, transcript-bound HKDF-SHA256, ChaCha20-Poly1305 file encryption, per-file subkeys, and fingerprint-based trust persistence.

It is **not yet fully compliant with the approved security architecture**. The most important gaps are identity pinning for previously verified peers, macOS private-key storage, authenticated cancellation, and concurrency-safe control-message sequencing. These issues do not all expose plaintext immediately, but they weaken peer authentication, control-message integrity, or key protection.

For store distribution, the current project should also be treated as pre-release: the Android release build still uses the debug signing key, Android explicitly permits cleartext network traffic, and the macOS secure-storage fallback is not suitable for a production identity key.

## Findings

### 1. High: Previously verified peers are not cryptographically pinned

The sender always creates msg1 with `intendedReceiverIdentityPubKey: null`. The discovery `/info` response does not provide an identity public key, and the sender does not load a verified receiver key from `TrustStore` before constructing msg1.

As a result, a later transfer does not cryptographically bind msg1 to the receiver identity previously verified by SAS. A different identity can complete the handshake. The resulting session may display as untrusted, but the transfer is not rejected automatically as a changed verified identity.

Evidence:

- [transfer_service.dart](lib/services/transfer_service.dart#L832-L846)
- [oneshare_discovery_service.dart](lib/services/oneshare_discovery_service.dart#L300-L355)
- [transfer_service.dart](lib/services/transfer_service.dart#L1960-L1981)

**Required remediation:** Resolve the selected peer to its stored fingerprint/public key before sending msg1. Populate `intendedReceiverIdentityPubKey` for known peers. A changed key must produce a prominent identity-mismatch state and must not silently proceed as the previously verified peer.

The receiver side should apply the equivalent check for a known verified sender where the protocol flow provides a trusted sender key.

### 2. High: macOS fallback stores identity private keys in plaintext

On macOS, `CryptoKeyStorage` bypasses secure storage and writes the identity seed, trust records, and other values to `.oneshare_secure_keys.json` under application support. Sandboxing limits other applications, but the file is not encrypted or protected by Keychain.

An attacker who obtains the application data, backup, or local user-readable files can recover the persistent Ed25519 private key and impersonate the device in future sessions.

Evidence:

- [crypto_key_storage.dart](lib/services/crypto/crypto_key_storage.dart#L21-L70)
- [DebugProfile.entitlements](macos/Runner/DebugProfile.entitlements#L1-L24)
- [Release.entitlements](macos/Runner/Release.entitlements#L1-L23)

**Required remediation:** Use macOS Keychain through the secure-storage plugin with verified Debug and Release entitlements. Do not treat a plaintext application-support file as equivalent secure storage. If a fallback remains, explicitly downgrade the security guarantee and protect the file as strongly as the platform permits.

### 3. High: Full-transfer cancellation loses authenticated control

`cancelTransfer()` calls `_cleanupTransferState()` before constructing the peer cancellation message. Cleanup removes the E2EE session, so the subsequent session lookup cannot find `outgoingCtrlChannel` and the cancellation is sent without `e2ee_ctrl`.

The peer correctly rejects this as an unauthenticated post-handshake control message. Local cancellation works, but remote cancellation synchronization can fail and the peer may continue processing until the transport failure is observed.

Evidence:

- [transfer_service.dart](lib/services/transfer_service.dart#L417-L420)
- [transfer_service.dart](lib/services/transfer_service.dart#L526-L540)
- [transfer_service.dart](lib/services/transfer_service.dart#L594-L618)

**Required remediation:** Construct and send the authenticated cancellation before destroying the session, or defer session cleanup until the control message has been created and transmitted.

### 4. High: Control-message sequence checks are not atomic

`evaluateIncomingControlMessage()` performs asynchronous HMAC calculation before sequence state is checked and recorded. The HTTP server processes requests concurrently.

Two identical messages arriving concurrently can both observe the same `expectedNextSeq` and both return `executeNew`. The business action can therefore execute twice before `recordSuccess()` updates the cache.

Evidence:

- [control_message_channel.dart](lib/services/crypto/control_message_channel.dart#L163-L220)
- [oneshare_http_server.dart](lib/services/oneshare_http_server.dart#L160-L220)

**Required remediation:** Serialize HMAC verification, sequence validation, business-action execution, and cache update for each `(transferId, direction)`. The idempotency decision must be atomic with action execution.

### 5. Medium: Sender does not enforce msg2 protocol version

The receiver rejects msg1 versions other than 2, but the sender does not validate `e2ee.version` in msg2 before processing the response.

Evidence:

- Receiver validation: [transfer_service.dart](lib/services/transfer_service.dart#L1464-L1478)
- Sender msg2 processing: [transfer_service.dart](lib/services/transfer_service.dart#L1880-L1908)

**Required remediation:** Require `e2ee.version == OneShareConfig.protocolVersion` on both handshake messages.

### 6. Medium: Handshake and control JSON bodies are unbounded

`_readJsonBody()` joins the entire request body into memory without a maximum size. The transfer request, accept, reject, and control endpoints are reachable over the local network before cryptographic authentication is established.

A malicious peer can send an oversized body and cause memory pressure or denial of service.

Evidence:

- [oneshare_http_server.dart](lib/services/oneshare_http_server.dart#L331-L340)

**Required remediation:** Enforce endpoint-specific maximum body sizes before buffering and reject oversized requests.

### 7. Medium: Debug logging exposes bearer tokens

Debug logging prints all incoming HTTP headers and complete accept JSON bodies. This exposes `Authorization: Bearer <token>` and `transferToken` in logs.

The token does not decrypt E2EE file data, but it remains a live transport credential for the token lifetime and should be treated as secret material.

Evidence:

- [transfer_service.dart](lib/services/transfer_service.dart#L2030-L2044)
- [oneshare_http_server.dart](lib/services/oneshare_http_server.dart#L109-L114)

**Required remediation:** Redact Authorization headers, transfer tokens, signatures, and other credentials from all logs.

### 8. Medium: Identity mismatch is detected but not consistently enforced

`TrustStore.evaluatePeer()` identifies when a known device name or device ID presents a different fingerprint. The transfer path still creates the session and exposes it to the UI.

This can be acceptable for an explicit “proceed as untrusted” flow, but a changed key must never inherit the old verified status or proceed without clear user acknowledgement.

Evidence:

- [trust_store.dart](lib/services/crypto/trust_store.dart#L78-L124)
- [transfer_service.dart](lib/services/transfer_service.dart#L1610-L1631)

**Required remediation:** Preserve the existing verified record, show an explicit identity-change warning, and require deliberate user acknowledgement before continuing as untrusted.

### 9. Low: No explicit nonce-overflow guard

The encrypted writer increments the chunk counter without an explicit exhaustion check. The practical probability is extremely low, but the approved plan requires nonce-overflow handling.

Evidence:

- [encrypted_stream.dart](lib/services/crypto/encrypted_stream.dart#L21-L27)
- [encrypted_stream.dart](lib/services/crypto/encrypted_stream.dart#L72-L80)

**Required remediation:** Reject before using a counter outside the permitted 64-bit nonce range.

### 10. Low: Derived-key zeroization is best effort only

Ephemeral private-key bytes are overwritten where extractable, but derived `SecretKey` objects are dereferenced rather than deterministically overwritten.

This is a known limitation of Dart garbage collection and is consistent with the plan’s stated limitation, but it should remain documented as residual risk.

Evidence:

- [e2ee_session.dart](lib/services/crypto/e2ee_session.dart#L139-L169)

### 11. High Release Blocker: Android release build uses the debug signing key

The Android `release` build type explicitly assigns `signingConfigs.getByName("debug")`. This is not appropriate for an app intended for Google Play distribution and prevents establishing a proper production signing and update chain.

Evidence:

- [build.gradle.kts](android/app/build.gradle.kts#L25-L29)

**Required remediation:** Configure a protected production upload/release signing key outside the repository, use Play App Signing, and verify that release artifacts are reproducible and signed with the intended application identity.

### 12. Medium Release Concern: Android permits cleartext traffic globally

The Android manifest sets `android:usesCleartextTraffic="true"` for the whole application. The current transfer protocol uses HTTP on the local network, so this is consistent with the transport design, but it permits unencrypted traffic for every network request and leaves metadata and control messages exposed to active network attackers.

E2EE protects file contents, but it does not protect discovery metadata, transfer metadata, control-message confidentiality, or availability. Store distribution does not make this setting acceptable by itself.

Evidence:

- [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml#L4-L10)

**Required remediation:** Scope cleartext permission to the minimum required LAN transport, document the threat model, and consider authenticated TLS or a platform-appropriate secure local transport for production. Do not remove E2EE as a replacement for transport security.

### 13. Medium Release Concern: Placeholder Android application identity

The Android namespace and application ID remain `com.example.droplan`, despite the product being OneShare. This is not a cryptographic vulnerability, but it is a release-management and trust concern because application identity, signing, update continuity, and store ownership must be finalized before production trust data is accumulated.

Evidence:

- [build.gradle.kts](android/app/build.gradle.kts#L7-L18)

**Required remediation:** Set the final unique application ID before release signing and store publication. Treat any pre-release identity-key or trust-store data as non-portable if the application identity changes.

## Areas That Match the Protocol

- Persistent Ed25519 identity keys are restored from a stable stored seed in [device_identity_service.dart](lib/services/device_identity_service.dart#L80-L142).
- Trust records are keyed by SHA-256 identity fingerprint, not `transferId`, session keys, or device name, in [trust_store.dart](lib/services/crypto/trust_store.dart#L56-L64).
- `manuallyVerified` survives a fresh `TrustStore` instance when storage is available.
- Transfer cleanup destroys session keys without deleting persistent trust records.
- Manifest canonicalization and transcript construction match the documented encoding.
- File encryption uses independent per-file HKDF keys and ChaCha20-Poly1305 authenticated frames.
- Truncation, oversized frames, invalid tags, empty data chunks, and trailing bytes are rejected.
- Directional file and control keys are separated.
- Protocol version 2 is required on incoming msg1.

## Trust and Lifecycle Assessment

### Persistence

The trust store persists records under a fingerprint-specific key and maintains a persistent fingerprint index. Existing records preserve their trust level when metadata is updated. This part is structurally correct.

### Transfer cleanup

Session cleanup removes ephemeral/session state only. It does not remove `TrustStore` records. The cleanup behavior is therefore correct for trust persistence, aside from the cancellation ordering issue described above.

### App lifecycle

`main()` awaits `DeviceIdentityService.initialize()` before creating the application UI. Identity keys are therefore normally stable across app launches. The fallback identity returned by `DeviceIdentityService.identity` remains a risk if production code accesses it before initialization.

### Independent device trust

Trust is stored independently on each device. SAS verification on one device does not automatically mark the peer verified on the other device. This is expected and secure.

## Recommended Remediation Order

1. Implement identity pinning for previously manually verified peers.
2. Replace or securely configure the macOS plaintext storage fallback.
3. Fix authenticated full-transfer cancellation ordering.
4. Make control-message evaluation and action execution atomic.
5. Enforce msg2 protocol version and validate handshake field lengths/types.
6. Add request-size limits and redact secrets from logs.
7. Add nonce-overflow handling and expand adversarial integration tests.
8. Configure production store signing, final application identity, and a documented LAN transport policy.

## Test Coverage Gaps

The existing tests cover cryptographic round trips, trust-store reload behavior, manifest handling, and several adversarial cases. They do not adequately cover:

- A real UI-to-TrustStore flow using a computed SHA-256 fingerprint.
- Verified-peer identity pinning across a second transfer.
- Changed identity behavior for a previously verified peer.
- Concurrent duplicate control requests.
- Cancellation after E2EE session establishment.
- macOS Keychain persistence in both Debug and Release builds.
- Oversized JSON requests and secret-redaction guarantees.
- Production-signed Android and macOS artifacts with final store application identities.
- Android cleartext traffic scope and behavior under store release configuration.

## Conclusion

The implementation provides meaningful encrypted file transport and has a sound cryptographic shape, but the current integration should be considered **partially compliant**, not complete. The identity-pinning and macOS key-storage issues are the highest priority because they directly affect long-term peer authentication and protection of the persistent signing key. The cancellation and control sequencing issues should follow because they break approved authenticated-control guarantees.
