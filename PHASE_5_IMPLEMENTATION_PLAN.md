# Phase 5 Implementation Plan: Protocol, Input, and Resource Hardening

## Overview & Background
Phase 5 focuses on hardening OneShare's input handling, cryptographic boundaries, and resource consumption against adversarial, malformed, downgraded, or resource-exhausting inputs. 

This phase guarantees that OneShare fails closed safely, returns proper HTTP status codes (such as `413 Payload Too Large`, `400 Bad Request`, `401 Unauthorized`), validates all decoded cryptographic structures before use, bounds file counts and metadata, prevents nonce overflow, and guarantees zero-leak cleanup on all failure paths.

---

## User Review Required

> [!IMPORTANT]
> **Key Architecture Decisions & Proposed Limits:**
> 1. **Bounded HTTP JSON Body Parsing:**
>    - Current behavior: `_readJsonBody` reads unlimited bytes with `utf8.decoder.bind(request).join()` and silently returns `{}` on parse failure.
>    - Hardened behavior: Reads chunks up to endpoint-specific byte limits. If the limit is exceeded, immediately terminates with HTTP 413 (`PAYLOAD_TOO_LARGE`). If JSON is malformed, throws/returns HTTP 400 (`MALFORMED_JSON`), never converting bad input into `{}`.
>    - **Endpoints and Limits:**
>      - `/api/v1/transfer/request`: **64 KB** (supports up to 100 files with metadata and Base64 cryptographic parameters).
>      - `/api/v1/transfer/accept`: **16 KB** (msg2 response).
>      - `/api/v1/transfer/reject`: **4 KB**.
>      - `/api/v1/transfer/cancel` & `/cancel-file`: **4 KB**.
> 2. **Transfer Resource Limits:**
>    - Maximum file count per transfer batch: **100 files**.
>    - Maximum filename length: **255 characters**.
>    - Path sanitization: Strict rejection or sanitization of path traversal (`../`, `/`, `\`, null bytes).
>    - Maximum declared file size: **100 GB** (reasonable ceiling for LAN peer transfer).
>    - Unknown-size transfer cap: Unknown size files (e.g. cloud streams with size 0) capped at **2 GB** by default to prevent disk exhaustion.
> 3. **Cryptographic Field & Type Validation:**
>    - Strict validation of `version == 2` as an integer on both msg1 and msg2.
>    - Exact byte-length checks for decoded keys:
>      - Ed25519 identity keys: exactly **32 bytes**.
>      - X25519 ephemeral keys: exactly **32 bytes**.
>      - SHA-256 hashes: exactly **32 bytes**.
>      - Ed25519 signatures: exactly **64 bytes**.
>      - HMAC-SHA256 control tags: exactly **32 bytes**.
>    - Strict Base64 validation before passing to cryptographic libraries.
> 4. **Nonce Overflow & Stream Frame Hardening:**
>    - Encrypted stream chunk counter max: **$2^{64}-1$** check (fails closed if `_chunkCounter >= 0xFFFFFFFFFFFFFFFF`).
>    - Parser buffer max cap: Maximum accumulated frame buffer **128 KB** (twice max frame size) to prevent unbounded buffering on malformed chunk streams.
>    - Max frame count per file: **$2^{32}$ frames** (~256 TB).

---

## Proposed Changes

### 1. HTTP Server Hardening ([`lib/services/oneshare_http_server.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart))

#### [MODIFY] [oneshare_http_server.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart)
- Replace `_readJsonBody(HttpRequest request)` with bounded parsing:
  ```dart
  Future<Map<String, dynamic>> _readBoundedJsonBody(
    HttpRequest request, {
    required int maxBytes,
  })
  ```
- If streamed bytes exceed `maxBytes`:
  - Abort stream read immediately.
  - Return HTTP 413 `Payload Too Large` with JSON `{ 'error': 'Payload exceeds maximum limit of $maxBytes bytes', 'code': 'PAYLOAD_TOO_LARGE' }`.
- If JSON parsing fails (`FormatException`):
  - Do not treat as `{}`.
  - Return HTTP 400 `Bad Request` with JSON `{ 'error': 'Malformed JSON payload', 'code': 'MALFORMED_JSON' }`.
- Apply endpoint-specific byte limits to each POST route:
  - `transferRequestPath`: 65,536 bytes (64 KB).
  - `transferAcceptPath`: 16,384 bytes (16 KB).
  - `transferRejectPath`: 4,096 bytes (4 KB).
  - `transferCancelPath`: 4,096 bytes (4 KB).
  - `transferCancelFilePath`: 4,096 bytes (4 KB).

---

### 2. Protocol & Cryptographic Parameter Validation ([`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart), [`lib/services/crypto/e2ee_handshake.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/e2ee_handshake.dart))

#### [MODIFY] [transfer_service.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- **Message 1 Validation (`handleIncomingRequest`):**
  - Verify `e2ee['version']` is an integer and equals `2`. If absent or not `2`, return HTTP 409 / `PROTOCOL_VERSION_MISMATCH`.
  - Validate field types: `manifestHash`, `senderIdentityPubKey`, `senderEphemeralPubKey`, `senderEphemeralSig` must be non-empty `String`.
  - Decode and enforce strict byte lengths:
    - `manifestHash`: exactly 32 bytes.
    - `senderIdentityPubKey`: exactly 32 bytes.
    - `senderEphemeralPubKey`: exactly 32 bytes.
    - `senderEphemeralSig`: exactly 64 bytes.
    - `intendedReceiverIdentityPubKey` (if present): exactly 32 bytes.
    - If target peer's own public key is specified in `intendedReceiverIdentityPubKey`, verify that it matches this receiver's identity public key; if mismatched, reject with `RECEIVER_IDENTITY_MISMATCH`.
  - Validate file list constraints:
    - Number of files: $1 \le \text{count} \le 100$.
    - File names: non-empty, length $\le 255$, sanitized (no path traversal).
    - File sizes: $\ge 0$ and $\le 100 \text{ GB}$.
- **Message 2 Validation (`handleAcceptResponse`):**
  - Verify `e2ee['version']` is an integer and equals `2`. If missing or invalid, complete outgoing request with failure.
  - Decode and enforce strict byte lengths:
    - `receiverIdentityPubKey`: exactly 32 bytes.
    - `receiverEphemeralPubKey`: exactly 32 bytes.
    - `receiverEphemeralSig`: exactly 64 bytes.
  - Fail closed without crashing or unhandled format exceptions.

---

### 3. Stream & Nonce Overflow Hardening ([`lib/services/crypto/encrypted_stream.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/encrypted_stream.dart))

#### [MODIFY] [encrypted_stream.dart](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/encrypted_stream.dart)
- **Nonce Overflow Check:**
  - In `EncryptedStreamWriter.encryptChunk` and `writeSentinel`:
    - Check if `_chunkCounter >= 0xFFFFFFFFFFFFFFFF`.
    - If exceeded, throw `EncryptedStreamException('Nonce counter overflow: cannot encrypt further chunks under current file key')`.
  - In `EncryptedStreamReader`:
    - Enforce the same upper bound on chunk count.
- **Parser Buffer & Resource Caps:**
  - In `EncryptedStreamReader.processStream`:
    - Cap `buffer.length`: if unparsed bytes in `buffer` exceed `maxCiphertextChunkSize * 2` (131,104 bytes), abort stream immediately with `EncryptedStreamException('Encrypted stream buffer overflow: invalid framing')`.
    - Enforce maximum total received ciphertext size vs. declared plaintext size + tags.

---

### 4. Verification Plan

#### Automated Tests
Create [`test/protocol_and_resource_hardening_test.dart`](file:///Users/ashmaanmainali/Projects/oneshare/test/protocol_and_resource_hardening_test.dart) to test:
1. **HTTP Body Limits:**
   - Body exceeding 64 KB on `/api/v1/transfer/request` returns HTTP 413 `PAYLOAD_TOO_LARGE`.
   - Body exceeding 4 KB on `/api/v1/transfer/cancel` returns HTTP 413 `PAYLOAD_TOO_LARGE`.
   - Body exceeding 16 KB on `/api/v1/transfer/accept` returns HTTP 413 `PAYLOAD_TOO_LARGE`.
2. **Malformed JSON:**
   - Malformed JSON string (`{"transferId": ... invalid`) returns HTTP 400 `MALFORMED_JSON` (does not become `{}`).
3. **Protocol Version Enforcement:**
   - Missing version on msg1 returns `PROTOCOL_VERSION_MISMATCH`.
   - Version 1 or 3 on msg1 returns `PROTOCOL_VERSION_MISMATCH`.
   - Non-integer version (e.g. string `"2"`) returns `PROTOCOL_VERSION_MISMATCH`.
   - Version mismatch on msg2 accept rejects transfer cleanly.
4. **Cryptographic Parameter Lengths:**
   - 31-byte or 33-byte public key returns `INVALID_HANDSHAKE`.
   - 63-byte signature returns `INVALID_HANDSHAKE`.
   - Invalid Base64 strings return `INVALID_HANDSHAKE`.
5. **Transfer Resource Limits:**
   - Batch of 101 files rejected with `EXCESSIVE_FILE_COUNT`.
   - Filename with 256 characters or path traversal characters rejected/sanitized.
   - File size exceeding 100 GB rejected.
6. **Nonce Counter & Stream Buffer Safety:**
   - Nonce counter overflow throws `EncryptedStreamException`.
   - Excessive unparsed stream data in buffer triggers buffer overflow protection.
   - Reader cleanup on truncated stream removes temporary file and closes sink.

#### Full Suite Regression
- Run `flutter analyze` (0 issues).
- Run full `flutter test` (all 146+ tests passing).
