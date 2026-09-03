# Phase 3 Implementation & Verification Report: Cryptographic Identity Pinning & Handshake Mismatch Enforcement

**Execution Date:** 2026-09-03  
**Status:** Completed & Fully Verified  
**Scope:** Phase 3 Known-peer resolution, `intendedReceiverIdentityPubKey` pinning, sender msg2 pinned-key verification, receiver HTTP 403 `IDENTITY_MISMATCH` rejection, preservation of verified trust records, and explicit unverified SAS passthrough.  
**Protocol Impact:** Enforced end-to-end cryptographic peer identity pinning on top of the E2EE v2 wire protocol. Handshake serialization matches existing v2 spec.

---

## 1. Scope & Implementation Summary

### 1.1 Known-Peer Identity Resolution & Pinning in `msg1`
- **File Modified:** [`lib/services/transfer_service.dart`](lib/services/transfer_service.dart), [`lib/main.dart`](lib/main.dart)
- `sendTransferRequest()` accepts optional `targetDeviceId` and `targetDeviceName` forwarded from device discovery.
- Before constructing `msg1`, the sender queries `trustStore.findCandidatePeers(deviceId: targetDeviceId, deviceName: targetDeviceName)`.
- If and only if there is an unambiguous single match with `trustLevel == TrustLevel.manuallyVerified`, the sender sets:
  ```dart
  session.intendedReceiverIdentityPubKey = candidates.first.identityPublicKeyBytes;
  ```
  and encodes this in `e2ee['intendedReceiverIdentityPubKey']`.
- If the peer is unknown, unverified (`unverifiedSeen`), or ambiguous, `intendedReceiverIdentityPubKey` remains `null`.

### 1.2 Sender-Side `msg2` Pinned-Key Verification
- **Files Modified:** [`lib/services/crypto/e2ee_session.dart`](lib/services/crypto/e2ee_session.dart), [`lib/services/transfer_service.dart`](lib/services/transfer_service.dart)
- `E2eeSession` records `intendedReceiverIdentityPubKey`.
- In `handleTransferAccept()` (when processing receiver's `msg2`), if `session.intendedReceiverIdentityPubKey` was pinned in `msg1`, the sender verifies that `receiverIdentityPubKey` returned in `msg2` matches the pinned key byte-for-byte.
- If a mismatch occurs, the sender immediately aborts the handshake with `StateError('Receiver identity mismatch...')`, terminating the transfer before any file data or encrypted streams are exchanged.

### 1.3 Receiver HTTP 403 `IDENTITY_MISMATCH` Rejection
- **Files Modified:** [`lib/services/transfer_service.dart`](lib/services/transfer_service.dart), [`lib/services/oneshare_http_server.dart`](lib/services/oneshare_http_server.dart)
- In `handleIncomingRequest()`, after verifying `msg1` cryptographic signature, the receiver evaluates the peer using `trustStore.evaluatePeer(...)`.
- If `evaluation.hasIdentityMismatchForDeviceName` is true and `evaluation.mismatchedRecord?.trustLevel == TrustLevel.manuallyVerified`:
  1. The receiver destroys the temporary incoming session `_incomingE2eeSessions.remove(transferId)?.destroy()`.
  2. Returns `{'status': 'rejected', 'error': '...', 'code': 'IDENTITY_MISMATCH'}`.
  3. `OneShareHttpServer` maps `IDENTITY_MISMATCH` to **HTTP 403 Forbidden** (rather than generic HTTP 409 Conflict).
  4. The request is **not** pushed to `incomingRequestNotifier` (acceptance dialog is suppressed).
  5. The existing stored `manuallyVerified` trust record is preserved intact without downgrades, overwrites, or modifications.
  6. The altered key is rejected and **not** recorded into `TrustStore`.

### 1.4 Unverified & Unseen Peer Passthrough
- If an unseen or unverified peer initiates a transfer without conflicting with a verified identity, the request proceeds normally with status `pending`, triggers `incomingRequestNotifier`, and records the encounter as `TrustLevel.unverifiedSeen`.

---

## 2. Test Verification & Results

### 2.1 Static Analysis
```bash
flutter analyze
```
**Result:** `No issues found!` (0 errors, 0 warnings).

### 2.2 Phase 3 Focused Test Suite
```bash
flutter test test/identity_pinning_and_mismatch_test.dart
```
**Result:** All **5 tests passed**, 0 failures:
- `Sender resolves and pins intendedReceiverIdentityPubKey for single manuallyVerified peer` (Passed)
- `Sender does NOT pin intendedReceiverIdentityPubKey for unverifiedSeen or ambiguous peer` (Passed)
- `Receiver rejects changed identity for known manually verified peer with HTTP 403 IDENTITY_MISMATCH` (Passed)
- `Sender msg2 verification aborts transfer if receiver identity public key does not match pinned key` (Passed)
- `Unverified and unseen peers pass through to SAS flow without identity mismatch rejection` (Passed)

### 2.3 Full Project Test Suite
```bash
flutter test
```
**Result:** All **128 tests passed** (99 baseline + 9 environment isolation tests + 15 Phase 2 tests + 5 Phase 3 tests), 0 failures.

---

## 3. Working Tree Status
- Baseline changes in `lib/main.dart`, `lib/services/crypto/e2ee_session.dart`, and `lib/services/transfer_service.dart` were preserved and properly integrated.
- Phase 1 compile-time environment isolation rules and Phase 2 persistent identity/trust-store invariants remain active and unmodified.
- No changes made to cancellation, control-message mutexes, HTTP body limits, nonce hardening, or release signing.
