# Phase 5 Implementation Report: Protocol, Input, and Resource Hardening

## 1. Executive Summary
Phase 5 ("Protocol, Input, and Resource Hardening") has been implemented and validated across all endpoints, stream framing layers, and cryptographic validation routines.

OneShare now strictly fails closed on:
- Malformed, oversized, or non-object JSON bodies across all HTTP endpoints (returning `413 Payload Too Large` or `400 Bad Request`).
- Protocol version downgrades or unsupported versions (`version != 2`).
- Invalid cryptographic parameter lengths, types, or non-Base64 encodings.
- Resource exhaustion vectors (batches > 100 files, filenames > 255 chars, path traversal sequences, file sizes > 100 GB, unknown-size files > 2 GB).
- Nonce counter overflows and parser buffer expansion > 128 KB.

All 164 test cases in the test suite passed cleanly.

---

## 2. Hardening Measures Implemented

### 2.1 Bounded HTTP Body Parser with 413 and 400 Status Codes
- **File:** [`lib/services/oneshare_http_server.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart)
- Replaced unbounded buffering `_readJsonBody` with chunked stream counting:
  ```dart
  Future<Map<String, dynamic>> _readBoundedJsonBody(HttpRequest request, {required int maxBytes})
  ```
- **Endpoint Byte Limits:**
  - `POST /api/v1/transfer/request`: **64 KB** (`kMaxRequestJsonBytes = 65536`)
  - `POST /api/v1/transfer/accept`: **16 KB** (`kMaxAcceptJsonBytes = 16384`)
  - `POST /api/v1/transfer/reject`: **4 KB** (`kMaxRejectJsonBytes = 4096`)
  - `POST /api/v1/transfer/cancel`: **4 KB** (`kMaxCancelJsonBytes = 4096`)
  - `POST /api/v1/transfer/cancel-file`: **4 KB** (`kMaxCancelJsonBytes = 4096`)
- **HTTP Status Codes:**
  - Exceeding byte limit: Immediately throws `_PayloadTooLargeException` and returns **HTTP 413** (`PAYLOAD_TOO_LARGE`).
  - Malformed UTF-8, malformed JSON syntax, or top-level JSON array: Immediately throws `_MalformedJsonException` and returns **HTTP 400** (`MALFORMED_JSON`). Never converts bad input into `{}`.

### 2.2 Protocol Version 2 Strict Enforcement
- **Files:** [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- **msg1 (`handleIncomingRequest`):**
  - Requires `e2ee['version']` to be an explicit integer `== 2`.
  - Missing, string versions (`"2"`), or different integer versions return **HTTP 409** with code `PROTOCOL_VERSION_MISMATCH`.
- **msg2 (`handleAcceptResponse`):**
  - Requires `e2ee['version']` to be an explicit integer `== 2`.
  - Rejects transfer on mismatch and completes outgoing request with failure status.

### 2.3 Cryptographic Field Type & Exact Byte-Length Validation
- **File:** [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- Parameters must be non-empty Strings and valid Base64:
  - `manifestHash`: exactly **32 bytes**.
  - `senderIdentityPubKey` / `receiverIdentityPubKey`: exactly **32 bytes**.
  - `senderEphemeralPubKey` / `receiverEphemeralPubKey`: exactly **32 bytes**.
  - `senderEphemeralSig` / `receiverEphemeralSig`: exactly **64 bytes**.
  - `intendedReceiverIdentityPubKey` (if present): exactly **32 bytes**.
- Invalid lengths or corrupt Base64 fail immediately with `INVALID_HANDSHAKE`.

### 2.4 Transfer Metadata & Resource Ceilings
- **File:** [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- **File Count:** $1 \le \text{count} \le 100$. Exceeding 100 files returns `EXCESSIVE_FILE_COUNT`. Empty list returns `EMPTY_FILE_LIST`.
- **File Name:** Length $\le 255$ characters. Rejects filenames with null bytes (`\x00`), `/`, or `\`.
- **File Size Ceiling:** Maximum 100 GB declared file size ceiling (`EXCESSIVE_FILE_SIZE`).
- **Unknown-Size Stream Bound:** Files with unknown size (`fileSize == 0`) capped at **2 GB** (`maxUnknownFileSize`) during streaming to prevent disk exhaustion.

### 2.5 Nonce Overflow & Parser Buffer Defense
- **File:** [`lib/services/crypto/encrypted_stream.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/encrypted_stream.dart)
- **Nonce Counter:** Checked against `maxNonceCounter = 0x7FFFFFFFFFFFFFFF`. Throws `EncryptedStreamException('Nonce counter overflow...')` on overflow in both reader and writer.
- **Parser Buffer Cap:** `EncryptedStreamReader` enforces `maxParserBufferBytes = 131104` (128 KB). If unparsed framing data exceeds 128 KB, throws `EncryptedStreamException('Parser buffer overflow...')` and closes stream.

---

## 3. Automated Test Evidence

### 3.1 Focused Tests in `test/protocol_and_resource_hardening_test.dart`
- **18/18 tests passed:**
  - Request body > 64 KB returns HTTP 413 `PAYLOAD_TOO_LARGE`.
  - Cancel body > 4 KB returns HTTP 413 `PAYLOAD_TOO_LARGE`.
  - Accept body > 16 KB returns HTTP 413 `PAYLOAD_TOO_LARGE`.
  - Malformed JSON returns HTTP 400 `MALFORMED_JSON`.
  - JSON array returns HTTP 400 `MALFORMED_JSON`.
  - Missing version returns `PROTOCOL_VERSION_MISMATCH`.
  - String version `"2"` returns `PROTOCOL_VERSION_MISMATCH`.
  - Non-v2 integer version (1) returns `PROTOCOL_VERSION_MISMATCH`.
  - 31-byte key rejected with `INVALID_HANDSHAKE`.
  - 63-byte signature rejected with `INVALID_HANDSHAKE`.
  - Non-Base64 parameter rejected with `INVALID_HANDSHAKE`.
  - 101 files rejected with `EXCESSIVE_FILE_COUNT`.
  - Empty file list rejected with `EMPTY_FILE_LIST`.
  - 256-char filename rejected with `INVALID_FILE_NAME`.
  - Path traversal characters rejected with `INVALID_FILE_NAME`.
  - >100 GB file size rejected with `EXCESSIVE_FILE_SIZE`.
  - Nonce overflow throws `EncryptedStreamException`.
  - Parser buffer overflow (>128 KB) throws `EncryptedStreamException`.

### 3.2 Static Analysis & Full Regression
- **`flutter analyze`:** **0 issues found** (`No issues found! (ran in 2.9s)`).
- **`flutter test`:** **All 164/164 tests passed across the entire project repository!**

---

## 4. Platform Limitations & Non-Blockers

1. **LAN Streaming Socket Buffering:** Dart's HTTP engine manages kernel-level TCP receive window buffers independently of user-space chunk limits; `sink.flush()` backpressure applied every 2 MB maintains low RAM footprint.
2. **Dart 64-bit Nonce Bound:** In the Dart VM, integers are signed 64-bit values; hence the nonce ceiling is bounded at `0x7FFFFFFFFFFFFFFF` ($9.22 \times 10^{18}$ chunks $\approx 6 \times 10^{11}$ GB per file key), which is practically inexhaustible.
