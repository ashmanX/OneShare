# Phase 4 Implementation Plan: Authenticated Control, Shared Lifecycle Lock & Race-Safe Cancellation

**Date:** 2026-09-03  
**Status:** Revised & Detailed (Ready for Execution)  
**Objective:** Make post-handshake control actions authenticated, idempotent, race-safe, and coordinated with transfer lifecycle cleanup.  

---

## 1. Scope & Invariants

Phase 4 focuses strictly on:
- **Shared per-transfer lifecycle lock in `TransferService`** coordinating:
  - Incoming control processing
  - Full-transfer cancellation
  - Single-file cancellation
  - Session destruction & resource cleanup
- **Strict post-handshake authentication** for `/cancel` and `/cancel-file` with exact response mapping (400, 401, 404, 409).
- **Atomic control verification, execution, sequence advancement, and caching**.
- **Explicit failure & retry semantics** for control actions.
- **Fail-closed unknown-transfer handling** (no blind cleanup).
- **Clean cancellation ordering** with guaranteed finalization.
- **Race safety** between single-file cancellation and full-transfer cancellation.

**Strict Scope Exclusions (Deferred to Later Phases):**
- HTTP body-size limits and stream frame limits (Phase 5).
- Nonce counter hardening (Phase 5).
- Logging refactoring (Phase 6).
- Store release and production signing (Phase 7/8).

---

## 2. Technical Architecture & Lifecycle Coordination

### 2.1 Shared Per-Transfer Lifecycle Lock in `TransferService`
Currently, `ControlMessageChannel` operates independently of `TransferService._cleanupTransferState()`. To prevent cleanup from tearing down a session while a control message is verifying, executing, or updating sequence numbers, `TransferService` will maintain a shared asynchronous mutex per transfer:

```dart
final Map<String, Completer<void>> _transferLocks = {};

Future<T> synchronizedTransfer<T>(String transferId, Future<T> Function() block) async {
  while (_transferLocks.containsKey(transferId)) {
    await _transferLocks[transferId]!.future;
  }
  final completer = Completer<void>();
  _transferLocks[transferId] = completer;
  try {
    return await block();
  } finally {
    _transferLocks.remove(transferId);
    completer.complete();
  }
}
```

This shared lifecycle lock guards:
1. Incoming control message processing (`processIncomingControlMessage`)
2. `cancelTransfer()` (both initiator and peer notification)
3. `cancelSingleFile()` (both initiator and peer notification)
4. `_cleanupTransferState()`

---

### 2.2 Strict Cleanup Synchronization & Ordering

When full-transfer cancellation is initiated or received, all operations must follow this strict sequence inside `synchronizedTransfer(transferId)`:

```dart
await synchronizedTransfer(transferId, () async {
  // 1. Determine whether already cleaning up or terminal
  if (_isTerminalOrCancelled(transferId)) {
    return; // Idempotent no-op
  }
  _markCancelling(transferId);

  // 2. Process accepted control action / business callback
  // (if incoming control message)

  // 3. Record replay response and advance sequence
  // (only on business callback success)

  // 4. Abort local I/O (sockets, sinks, active streams, delete partial temp files)
  _abortLocalTransferIO(transferId);

  // 5. Clean up session and transfer state
  _cleanupTransferState(transferId);
});
```

#### Invariants:
- **Idempotence:** Repeated cleanup calls detect the terminal marker under the lock and immediately return cleanly without duplicate deletions, exceptions, or state corruption.
- **No Destruction During Execution:** A control callback will never experience its session keys being zeroized or its channel destroyed while executing.

---

### 2.3 Race-Safe `cancelSingleFile()`

1. **Under the Shared Lock:**
   - Acquires `synchronizedTransfer(transferId)`.
   - Checks if full transfer is already cancelled or terminal:
     ```dart
     if (isTransferCancelled(transferId)) return;
     ```
   - If the transfer is still active, authenticates notification (if post-handshake), aborts active file stream for that specific `fileId`, updates `PerFileTransferState` to `cancelled`, records sequence advancement, and caches response.
2. **Session Preservation:**
   - File cancellation **never** destroys the `E2eeSession` or calls `_cleanupTransferState()`.
3. **Race Interlock with Full Cancellation:**
   - If `cancelTransfer()` executes concurrently with `cancelSingleFile()`, the per-transfer lock serializes them. If full cancellation executes first, `cancelSingleFile()` observes the cancelled state and exits without advancing sequence or mutating state. If file cancellation executes first, it records its state, and full cancellation subsequently cleans up the remaining transfer.

---

### 2.4 Control Message Processing & Failure Semantics

In `ControlMessageChannel.processIncomingControlMessage(...)` (coordinated under the lifecycle lock):

1. **Pre-Execution Validation (Steps 1–5):**
   - Verify presence of `e2ee_ctrl` block.
   - Verify direction matches channel expectation.
   - Verify HMAC-SHA256 in constant time.
   - Check `_recentHandledCache`:
     - If `seq` is cached and MAC matches: return `ControlMessageEvaluation.idempotentReplay(cached.response)` (HTTP 200).
     - If `seq` is cached but MAC differs: return `ControlMessageEvaluation.invalidMac()` (HTTP 401 `INVALID_CONTROL_MAC`).
   - Check sequence progression:
     - If `seq < _expectedNextSeq`: return `ControlMessageEvaluation.duplicateOrExpired()` (HTTP 409 `DUPLICATE_OR_EXPIRED_SEQUENCE`).
     - If `seq > _expectedNextSeq`: return `ControlMessageEvaluation.sequenceGap()` (HTTP 400 `SEQUENCE_GAP`).
   - *If any step fails, the business callback is NOT called.*
2. **Business Action Execution:**
   - Execute callback: `final response = await businessAction();`
3. **Post-Execution Commit (Only on Callback Success):**
   - Insert `(seq, mac, response)` into `_recentHandledCache` (FIFO capped at 16 entries).
   - Advance `_expectedNextSeq = seq + 1`.
4. **Callback Failure / Exception Behavior:**
   - If `businessAction()` throws an error or exception:
     - **Do NOT** insert into `_recentHandledCache`.
     - **Do NOT** advance `_expectedNextSeq`.
     - The channel remains in the state `_expectedNextSeq == seq`, keeping the sequence retryable.
     - Release lock.
     - Return a safe redacted server error response (HTTP 500) to the peer.

---

### 2.5 Unknown-Transfer and Pre-Handshake Policy

In `OneShareHttpServer`:

1. **Unknown Transfer IDs:**
   - If `transferId` is unknown and not found in active sessions, incoming requests, or terminal records:
     - Return **HTTP 404 Not Found** (`TRANSFER_NOT_FOUND`) or **HTTP 400 Bad Request** (`INVALID_TRANSFER_ID`).
     - **No cleanup or state mutation is performed.**
2. **Pre-Handshake vs. Post-Handshake Classification:**
   - `TransferService` explicitly tracks transfer lifecycle state (`preHandshake`, `handshakeComplete`, `terminal`).
   - **Pre-Handshake:** A transfer currently waiting in `incomingRequestNotifier` or `_outgoingRequests` before `msg2` exchange. Unauthenticated cancellation is accepted.
   - **Post-Handshake:** Any transfer that completed key derivation. **Authentication (`e2ee_ctrl`) is strictly mandatory.**
   - **Destroyed / Completed Post-Handshake Sessions:** If a transfer completed handshake and subsequently terminated/cleaned up, unauthenticated cancellation is **rejected** with HTTP 401 (`MISSING_CONTROL_AUTH`) or HTTP 409, never misinterpreted as pre-handshake.

---

### 2.6 Preserved Control Response Codes

- **HTTP 200 OK**:
  - Valid new control execution (`{'status': 'cancellation_acknowledged'}`).
  - Valid idempotent replay within 16-entry cache with identical MAC.
- **HTTP 400 Bad Request**:
  - Missing transfer ID (`MISSING_TRANSFER_ID`).
  - Unknown transfer ID (`INVALID_TRANSFER_ID`).
  - Sequence gap `seq > _expectedNextSeq` (`SEQUENCE_GAP`).
- **HTTP 401 Unauthorized**:
  - Missing `e2ee_ctrl` on active or completed post-handshake transfer (`MISSING_CONTROL_AUTH`).
  - Invalid HMAC or wrong direction (`INVALID_CONTROL_MAC`).
  - Replayed sequence with mismatched MAC.
- **HTTP 404 Not Found**:
  - Completely unknown transfer ID (`TRANSFER_NOT_FOUND`).
- **HTTP 409 Conflict**:
  - Expired sequence older than the 16-entry cache window (`DUPLICATE_OR_EXPIRED_SEQUENCE`).

---

## 3. Files to Modify & Create

### [MODIFY] [`lib/services/crypto/control_message_channel.dart`](lib/services/crypto/control_message_channel.dart)
- Implement `processIncomingControlMessage(...)` with strict execution order and failure semantics (no sequence advancement or caching on callback throw).

### [MODIFY] [`lib/services/transfer_service.dart`](lib/services/transfer_service.dart)
- Implement `synchronizedTransfer(transferId, ...)` per-transfer lifecycle lock.
- Explicitly track transfer lifecycle state (`preHandshake`, `postHandshake`, `terminal`).
- Coordinate full-transfer cancellation, single-file cancellation, and session cleanup under the lock.
- Enforce cancellation ordering: capture session -> sign -> send notification (with timeout) -> abort local I/O -> guaranteed cleanup in `finally`.
- Make `cancelSingleFile()` authenticated post-handshake and race-safe with full cancellation.

### [MODIFY] [`lib/services/oneshare_http_server.dart`](lib/services/oneshare_http_server.dart)
- Route `/api/v1/transfer/cancel` and `/api/v1/transfer/cancel-file` through the per-transfer lifecycle lock and `processIncomingControlMessage`.
- Enforce HTTP 404/400 for unknown transfers.
- Reject unauthenticated cancel with HTTP 401 on post-handshake transfers.

### [NEW] [`test/authenticated_cancellation_test.dart`](test/authenticated_cancellation_test.dart)
- Comprehensive test suite covering all 10 required test cases.

---

## 4. Phase 4 Verification & Test Plan

### Test Scenarios in `test/authenticated_cancellation_test.dart`:
1. **Concurrent Duplicate Controls:** Two concurrent identical valid control messages execute the business action exactly once; second returns cached response.
2. **Sequence Ordering & Gap Rejection:** Control message with `seq = 2` when `expected = 1` returns HTTP 400 `SEQUENCE_GAP`.
3. **Expired Sequence Rejection:** Control message with `seq < expected` outside the 16-entry cache returns HTTP 409 `DUPLICATE_OR_EXPIRED_SEQUENCE`.
4. **Business Action Failure Retries:** When business callback throws, sequence does NOT advance, response is not cached, and the same `seq` can be retried successfully.
5. **Cleanup Racing with Control Processing:** Ongoing accepted control action completes, caches response, and advances sequence before session destruction.
6. **Full Cancellation Racing with Single-File Cancellation:** File cancellation does not pass check or advance sequence after full cancellation begins; neither operation causes duplicate actions.
7. **Idempotent Repeated Full Cancellation:** Calling `cancelTransfer()` repeatedly is safe and idempotent.
8. **Network Notification Failure Resiliency:** When outgoing cancel notification throws a network exception, local streams abort and session cleans up cleanly in `finally`.
9. **Destroyed Post-Handshake Session Protection:** An unauthenticated cancel arriving after a post-handshake session was destroyed is rejected with HTTP 401, not treated as pre-handshake.
10. **Unknown Transfer Rejection:** Cancellation on a nonexistent transfer ID returns HTTP 404/400 with zero side effects.

### Regression Verification:
- `flutter analyze`: 0 errors, 0 warnings.
- `flutter test`: all 128 existing tests + new Phase 4 tests pass.
