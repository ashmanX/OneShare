# Phase 6 Implementation Plan: Logging, Diagnostics, and Recovery

## 1. Overview & Objectives
The goal of Phase 6 is to guarantee that sensitive credentials, keys, tokens, signatures, and private metadata never leak into local device logs, console output, or peer-facing wire responses, and to ensure that cryptographic sessions and identities have clean, deterministic destruction and recovery semantics.

---

## 2. User Review Required

> [!IMPORTANT]
> **Key Architecture Decisions for Phase 6:**
> 1. **Centralized Log Redaction Engine (`LogSanitizer`):**
>    - Create a centralized utility `LogSanitizer` that redacts:
>      - Tokens (`transferToken`, `tokenHash`).
>      - Headers (`Authorization`, bearer tokens).
>      - Cryptographic keys and seeds (`seed`, `privateKey`, `secretKey`, `sessionMasterKey`, `senderFileBaseKey`, etc.).
>      - Cryptographic signatures and HMAC tags (`senderEphemeralSig`, `receiverEphemeralSig`, `mac`).
>      - Ephemeral and identity public keys (`senderIdentityPubKey`, `receiverIdentityPubKey`, `senderEphemeralPubKey`, etc.).
>      - Handshake JSON envelopes (suppress whole-body logging, log only high-level events like `transferId` truncated to 8 chars).
>      - Full filesystem paths (sanitize down to basename or `<destination_path>`).
> 2. **Audit & Removal of Raw Body/Header Logging:**
>    - Replace all existing `debugPrint('[OneShare HttpServer] Handshake response ...: $responseJson')` and similar raw prints across [`lib/services/oneshare_http_server.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart), [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart), and [`lib/services/oneshare_discovery_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_discovery_service.dart).
> 3. **Peer-Facing Error Sanitization:**
>    - Peer-facing wire error messages must remain strictly generic (e.g. `HANDSHAKE_ERROR`, `STREAM_ERROR`, `PROTOCOL_VERSION_MISMATCH`).
>    - Never expose internal exception details, internal Dart stack traces, or cryptographic library exceptions over the wire.
> 4. **Session Destruction on Every Terminal Path:**
>    - Audit and verify that `session.destroy()` is called on:
>      - Handshake rejection (`BUSY_OR_DUPLICATE`, `PROTOCOL_VERSION_MISMATCH`, `INVALID_HANDSHAKE`, `IDENTITY_MISMATCH`).
>      - Sender timeout (`410 Gone`).
>      - Mid-stream decryption error or AEAD auth failure.
>      - Single-file completion vs. full-transfer batch termination.
>      - Stream truncation / network socket abrupt close.
> 5. **Documentation of Dart GC Zeroization Boundaries:**
>    - Explicitly document in `E2eeSession.destroy()` and `DeviceIdentityService` the limitations of the Dart VM garbage collector (e.g. immutable strings or intermediate heap buffers cannot be guaranteed to be immediately zeroized by user code without native C/Rust FFI memory pins).
> 6. **Identity Reset & Compromise Recovery:**
>    - Implement `DeviceIdentityService.resetIdentity({required KeyStorage storage})` allowing a user to explicitly reset their local identity upon compromise or security reset.
>    - Ensure that clearing identity also purges all pairing trust records (`TrustStore.clearAll()`).

---

## 3. Proposed Changes

### 3.1 Centralized Redaction Utility
#### [NEW] [lib/services/crypto/log_sanitizer.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/log_sanitizer.dart)
- Implements:
  - `String LogSanitizer.redact(String message)`: Regex-based masking of Base64 cryptographic keys, signatures, hex tokens, and authorization headers.
  - `Map<String, dynamic> LogSanitizer.sanitizeJson(Map<String, dynamic> json)`: Deep sanitization of JSON maps, replacing sensitive fields (`e2ee`, `transferToken`, `e2ee_ctrl`, `mac`) with `'[REDACTED]'`.
  - `String LogSanitizer.truncateId(String id)`: Truncates transferId/deviceId to 8 chars (`abcd1234...`) for safe diagnostic logging.

---

### 3.2 Unsafe Logging Removal & Sanitization
#### [MODIFY] [lib/services/oneshare_http_server.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart)
- Remove raw JSON prints of incoming request bodies and outgoing handshake responses.
- Replace `debugPrint('[OneShare HttpServer] Handshake response: $responseJson')` with high-level event logging: `[OneShare HttpServer] Handshake response sent status=$statusCode transferId=${LogSanitizer.truncateId(transferId)}`.
- Replace raw error logging in catch blocks to ensure no exception messages with cryptographic secrets are returned to the peer.

#### [MODIFY] [lib/services/transfer_service.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- Sanitize error messages in `_sendErrorResponse` and `handleIncomingRequest` catch blocks.
- Remove raw print of token values or full file system paths.

---

### 3.3 Terminal Path Session Destruction Audit & Hardening
#### [MODIFY] [lib/services/transfer_service.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- Verify `session?.destroy()` is invoked in every failure block of:
  - `handleIncomingRequest` (on invalid handshake, manifest hash mismatch, identity mismatch).
  - `handleAcceptResponse` (on signature failure, transcript mismatch, or timeout).
  - `handleIncomingFileUpload` (on pre-finalization mismatch, stream exception, or socket abortion).
- Ensure `_cleanupTransferState` is called on all terminal paths.

---

### 3.4 Identity Reset & Compromise Recovery
#### [MODIFY] [lib/services/device_identity_service.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/device_identity_service.dart)
- Implement `Future<DeviceIdentity> resetIdentity({KeyStorage? storage})`:
  - Atomically deletes stored keys (`kDeviceIdKey`, `kDeviceNameKey`, `kIdentityPrivateKeyKey`, `kIdentityCommittedKey`).
  - Calls `_identity = null`.
  - Generates a fresh identity and commits it.
- In [`lib/services/crypto/trust_store.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/trust_store.dart):
  - Ensure `clearAll()` is cleanly callable to purge all pairings when identity is reset.

---

## 4. Verification Plan

### Automated Tests ([`test/logging_and_recovery_test.dart`](file:///Users/ashmaanmainali/Projects/oneshare/test/logging_and_recovery_test.dart))
1. **Redaction Engine Verification:**
   - Test that `LogSanitizer.sanitizeJson` strips `transferToken`, `e2ee_ctrl`, `mac`, `senderIdentityPubKey`, `receiverEphemeralSig`.
   - Test that `LogSanitizer.redact` strips bearer tokens and Base64 cryptographic signatures from raw strings.
2. **Peer-Facing Error Sanitization:**
   - Test that malformed or cryptographic failures sent to `/api/v1/transfer/request` return generic error codes (`HANDSHAKE_ERROR`, `INVALID_HANDSHAKE`) without stack traces or key leakage.
3. **Session Destruction on Terminal Paths:**
   - Test that handshake rejection (`BUSY_OR_DUPLICATE`, `PROTOCOL_VERSION_MISMATCH`) destroys incoming session and zeroizes memory fields.
   - Test that aborted stream upload triggers `session.destroy()`.
4. **Identity Reset & Compromise Recovery:**
   - Test that `resetIdentity()` successfully purges the old identity, generates a fresh one with a new fingerprint, and invalidates previously verified peer pairings.
5. **Full Suite Regression:**
   - Run `flutter analyze` (0 issues).
   - Run full `flutter test` (all 164+ tests passing).
