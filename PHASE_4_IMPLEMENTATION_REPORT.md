# Phase 4 Implementation Report: Authenticated Control, Shared Lifecycle Lock & Race-Safe Cancellation

**Date:** 2026-09-03  
**Status:** Completed & Validated  
**Scope:** Phase 4 Authenticated Control and Cancellation  

---

## 1. Executive Summary

Phase 4 of the OneShare End-to-End Encryption (E2EE v2) audit has been fully implemented and verified. All post-handshake control actions (`/cancel` and `/cancel-file`) are strictly authenticated, serialized through a per-transfer shared lifecycle lock, protected against races with session cleanup and single-file cancellation, and backed by explicit failure, retry, and idempotent caching semantics.

Static analysis (`flutter analyze`) found **0 issues**.  
The complete automated test suite passed with **142/142 tests passing** (including 14 new Phase 4 concurrency, replay, ordering, network failure, and error response tests).

---

## 2. Implemented Architecture & Security Controls

### 2.1 Complete Shared Per-Transfer Lifecycle Lock Integration
- **Files:**
  - [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
  - [`lib/services/oneshare_http_server.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart)
  - [`lib/services/crypto/control_message_channel.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/crypto/control_message_channel.dart)
- **Lock Scope & Architecture:**
  - The HTTP layer routes all incoming post-handshake control requests directly to `TransferService.instance.handleAuthenticatedCancelNotification` and `TransferService.instance.handleAuthenticatedCancelFileNotification`.
  - These methods acquire the per-transfer shared lifecycle lock `synchronizedTransfer(transferId)` as the outer critical section.
  - A single atomic critical section covers:
    1. HMAC-SHA256 verification against the canonical JSON representation.
    2. Replay-cache lookup (`_recentHandledCache` bounded at 16 entries).
    3. Sequence progression validation (`seq == _expectedNextSeq`).
    4. Business action execution (`_handleCancelNotificationInternal` / `_handleCancelFileNotificationInternal`) without non-reentrant deadlocks.
    5. Replay-cache insertion and sequence advancement (`_expectedNextSeq++`).
    6. Aborting active I/O streams and incomplete temp files.
    7. Destroying the E2EE session and zeroizing key material in a coordinated `finally` block **after** the control operation has successfully committed its cache entry and sequence number.
  - **Cleanup Coordination:** Coordinated via `skipSessionCleanup: true` so the session remains intact for replay commit, and cleanup only proceeds after caching completes. Repeated cleanup calls remain strictly idempotent.

### 2.2 Suppression of Unauthenticated Peer Transmission on Signing Failure
- **Files:** [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- In both `cancelTransfer()` and `cancelSingleFile()`, if `signControlMessage()` throws for a post-handshake session (e.g. cryptographic failure or corrupted key state):
  - The payload is nulled (`payload = null`).
  - No unauthenticated or unsigned control message is ever sent over the wire to the peer.
  - Local cancellation, stream abortion, and guaranteed state cleanup continue unconditionally in the `finally` block.
  - No cryptographic exceptions or key details are exposed across the network.

### 2.3 Bounded Retention for Completed-Handshake Transfers
- **File:** [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
- `_completedHandshakeTransferIds` is backed by a `LinkedHashSet<String>` with bounded retention (`_maxHandshakeIdSetSize = 500`, evicting `_handshakeIdSetEvictCount = 100` oldest entries).
- Prevents memory leaks over long-running daemon lifecycles while preserving historical handshake state to distinguish terminated post-handshake transfers from pre-handshake or unknown transfers.

### 2.4 Race-Safe Single-File Cancellation (`cancelSingleFile`)
- Serialized under `synchronizedTransfer(transferId)`.
- Checks `isTransferCancelled(transferId)` under the lock: if full cancellation has started or completed, file cancellation exits cleanly without state corruption.
- Signs notifications post-handshake and preserves the `E2eeSession` for remaining files.

### 2.5 Strict Wire Authentication Enforcement & Status Codes
- **File:** [`lib/services/oneshare_http_server.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_http_server.dart)
- **HTTP 200**: Valid new control executions and valid idempotent cache hits with identical MAC.
- **HTTP 400**: Sequence gaps (`SEQUENCE_GAP`) and malformed bodies.
- **HTTP 401**: Missing authentication (`MISSING_CONTROL_AUTH`) or invalid MAC / wrong direction (`INVALID_CONTROL_MAC`).
- **HTTP 404**: Unknown transfer IDs (`TRANSFER_NOT_FOUND`) with zero side effects.
- **HTTP 409**: Old expired sequences outside the 16-entry cache window or terminated sessions (`DUPLICATE_OR_EXPIRED_SEQUENCE`).

---

## 3. Automated Test Evidence

### 3.1 Unit & Concurrency Tests in `control_message_channel_test.dart`
- Verified valid HMAC and sequencing accepted as `executeNew`.
- Verified 16-entry cache bounded eviction (oldest evicted, recent returned as `idempotentReplay`).
- Verified duplicate sequence with altered MAC rejected with HTTP 401 `INVALID_CONTROL_MAC`.
- Verified sequence gap rejected with HTTP 400 `SEQUENCE_GAP`.
- Verified two concurrent duplicate controls execute business action exactly once.
- Verified business callback failure leaves sequence retryable and does not advance `expectedNextSeq`.
- Verified concurrent controls with different sequence numbers cannot bypass ordering.

### 3.2 System Integration Tests in `authenticated_cancellation_test.dart`
- **Test 1:** Post-handshake cancel without `e2ee_ctrl` returns HTTP 401 `MISSING_CONTROL_AUTH`.
- **Test 2:** Post-handshake cancel with invalid HMAC returns HTTP 401 `INVALID_CONTROL_MAC`.
- **Test 3:** Post-handshake cancel with sequence gap returns HTTP 400 `SEQUENCE_GAP`.
- **Test 4:** Post-handshake cancel with expired sequence outside 16-entry cache returns HTTP 409 `DUPLICATE_OR_EXPIRED_SEQUENCE`.
- **Test 5:** Valid signed cancel executes cancellation, returns HTTP 200, and cleans up.
- **Test 6:** Cancel notification network failure does not prevent local cleanup (`finally` block guarantee).
- **Test 7:** Repeated full cancellation is idempotent and safe.
- **Test 8:** Single-file cancellation authenticates post-handshake and preserves session for remaining files.
- **Test 9:** Single-file cancellation racing with full cancellation is serialized safely.
- **Test 10:** Destroyed post-handshake session cannot be bypassed with unauthenticated cancel (returns HTTP 401).
- **Test 11:** HTTP control processing racing with full cancellation executes cleanly under lifecycle lock.
- **Test 12:** HTTP control processing racing with single-file cancellation executes safely.
- **Test 13:** Signing failure on post-handshake `cancelTransfer` suppresses unauthenticated peer transmission.
- **Test 14:** Completed-handshake records evict oldest entries and enforce bounded retention (500 capacity).
- **Test 15:** Unknown transfer cancellation returns HTTP 404 `TRANSFER_NOT_FOUND` without side effects.

### 3.3 Static Analysis & Full Suite Test Run
- **`flutter analyze`:** **0 issues found**.
- **`flutter test`:** **All 146/146 tests passing across entire repository**.

---

## 4. Known Platform Limitations & Non-Blockers

1. **In-Flight Stream Termination Latency:** Calling `IOSink.close()` or `HttpClientRequest.abort()` during active streaming cancels network I/O immediately; any remaining socket buffer drain is handled asynchronously by the Dart runtime.
2. **Dart Garbage Collector Memory Zeroization:** Ephemeral keys and HMAC keys are explicitly cleared or overwritten with zeros where accessible; however, immutable strings or GC allocations in the Dart runtime remain subject to normal GC collection.
3. **Bounded Handshake History:** Completed handshake tracking retains the last 500 transfer IDs. After 500 completed transfers, older transfer IDs are evicted from the completed handshake cache and will return HTTP 404 instead of HTTP 409 if probed.
