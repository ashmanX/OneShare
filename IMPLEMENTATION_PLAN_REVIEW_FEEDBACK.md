# Store-Readiness Implementation Plan Review Feedback

**Date:** 2026-09-03  
**Audience:** Security developers, platform developers, release engineers, and reviewers  
**Related documents:**

- [SECURITY_REVIEW_REPORT.md](SECURITY_REVIEW_REPORT.md)
- [STORE_READINESS_SECURITY_IMPLEMENTATION_SPEC.md](STORE_READINESS_SECURITY_IMPLEMENTATION_SPEC.md)
- Updated implementation plan: `implementation_plan.md`

## 1. Review Decision

The updated implementation plan is directionally correct and addresses the principal findings, but it is **not yet implementation-ready**. The plan needs several concrete design decisions and acceptance criteria before security developers can implement it without making independent assumptions.

The three highlighted decisions are correct:

1. Production macOS identity storage must use Keychain and fail closed.
2. Previously SAS-verified peers must be identity-pinned.
3. Post-handshake control processing must be atomic.

The remaining sections define the changes required to make those decisions precise and reviewable.

## 2. Required Plan Corrections

### 2.1 Define peer identity resolution before implementing pinning

The plan says that `sendTransferRequest()` should query `TrustStore` for the target device, but the current discovered-device data is based primarily on device ID, device name, host, and port. The plan must specify how that data resolves to a persistent Ed25519 public key.

Required design:

1. Discovery metadata is untrusted and cannot establish identity.
2. A discovered device ID may locate candidate trust records, but it is not the trust anchor.
3. The trust anchor is the stored raw Ed25519 public key and its SHA-256 fingerprint.
4. If a verified record is found, use its stored public key for `intendedReceiverIdentityPubKey`.
5. If no matching record is found, send a null intended receiver key and keep the session untrusted until SAS verification.
6. If more than one record could match a device ID, do not guess. Require explicit peer selection or treat the connection as untrusted.
7. A discovery-advertised public key may narrow lookup candidates but must never promote trust.

The plan should identify whether the discovery `/info` response will expose a public-key hint. If it does, that hint must remain explicitly unauthenticated until the signed handshake completes.

### 2.2 Specify receiver-side changed-identity behavior

Updating `TrustStore.evaluatePeer()` is not enough. The transfer handler must define what happens when a known device name or device ID presents a different fingerprint.

Required behavior:

- Preserve the existing verified record unchanged.
- Do not replace its public key, fingerprint, or trust level.
- Do not show the ordinary accept dialog as if this were a normal peer.
- Show an identity-change warning containing the old and new fingerprints.
- Reject by default.
- Permit continuation only through an explicit “Proceed as Untrusted” action.
- Never mark the new identity verified automatically.
- Store the new identity, if stored at all, as a separate unverified record.

The plan must also define whether the sender and receiver use identical policy. A verified sender identity must not be silently replaced by a new sender key.

### 2.3 Define the full scope of control-message atomicity

The plan currently places a mutex in `control_message_channel.dart`, but the channel validates messages while the HTTP server performs the business action. A channel-only mutex cannot guarantee single execution.

The plan must require that the critical section includes:

1. Envelope parsing.
2. Direction validation.
3. HMAC verification.
4. Replay-cache lookup.
5. Sequence validation.
6. Business-action execution.
7. Replay-cache insertion.
8. Sequence advancement.

Acceptable designs include:

- A locked callback that performs the business action inside the channel’s critical section.
- A per-session service lock that wraps channel evaluation, action execution, and `recordSuccess()`.

The implementation must also define lock behavior during session cleanup. Cleanup must not destroy the channel while an accepted control action is still executing.

Required tests:

- Two simultaneous copies of the same valid message execute once.
- One request receives the original cached response after the other completes.
- A duplicate cannot execute after cache eviction.
- Cleanup racing with a control request does not execute the action twice.

### 2.4 Define the body-limit API and error path

The plan says `_readJsonBody()` should return HTTP 413, but the current method returns a `Map<String, dynamic>` and converts failures into `{}`. The implementation plan must specify the API change.

Required behavior:

- Enforce the limit while reading the stream.
- Do not call `.join()` without a bounded byte counter.
- Return a distinct oversized-body result or throw a dedicated exception.
- Route handlers must return `413 Payload Too Large`.
- Malformed JSON must not be treated as an empty request.
- Oversized input must not reach handshake parsing.
- Close or safely drain the request after rejection.

Use endpoint-specific limits. The selected limit must be justified by maximum file count, filename length, metadata size, public-key fields, signatures, and JSON overhead. A fixed 64 KB value is acceptable only after these maximums are defined.

### 2.5 Expand validation to both handshake directions

The plan specifically mentions msg2 version and lengths in `handleAcceptResponse()`, but all received handshake fields require validation.

Validate before cryptographic operations:

- `e2ee` is a JSON object.
- Version is an integer equal to protocol version 2.
- Ed25519 public keys are exactly 32 bytes.
- X25519 public keys are exactly 32 bytes.
- Ed25519 signatures are exactly 64 bytes.
- Manifest and token hashes are exactly 32 bytes.
- Optional intended receiver key is null or exactly 32 bytes.
- Base64 values decode strictly.
- Transfer ID and file IDs are bounded and valid.
- File count and filename lengths are bounded.
- File sizes are non-negative and within policy.
- Numeric sequence values are positive and within the supported range.

Apply these checks to msg1 on the receiver and msg2 on the sender. Reject malformed input before creating persistent or active session state.

### 2.6 Define macOS migration and Keychain failure behavior

The plan correctly says to remove the production plaintext fallback, but it does not define what happens to existing `.oneshare_secure_keys.json` data.

The plan must choose one of these explicit paths:

**Migration path:**

1. Detect the legacy file.
2. Validate its structure and identity material.
3. Import the identity seed into Keychain.
4. Verify that the restored public key and fingerprint match the legacy identity.
5. Migrate trust records without changing fingerprints.
6. Securely remove or quarantine the legacy file after successful migration.

**Explicit reset path:**

1. Detect legacy data that cannot be safely imported.
2. Inform the user that the device identity cannot be restored.
3. Require explicit identity reset.
4. Explain that previous peer trust must be re-established.
5. Never regenerate silently.

For all paths:

- A temporary Keychain failure must not create a new identity.
- Advertising and transfers must remain disabled until identity storage is known to work.
- Keychain read/write failures must fail closed.
- Debug and Release/App Store-signed behavior must be tested separately.

Do not add `keychain-access-groups` blindly. Confirm the entitlement required by the exact `flutter_secure_storage` version and Apple signing configuration.

### 2.7 Correct cancellation ordering and failure handling

The cancellation fix is correct in principle, but the plan should specify the failure path:

1. Capture the session and control channel.
2. Create and authenticate the cancellation payload.
3. Send the peer notification.
4. Abort local I/O.
5. Destroy session state.
6. Invoke `_cleanupTransferState()`.

If network delivery fails, local cleanup must still happen. If the peer receives the message after local cleanup, the message must already contain the required authentication data.

Add tests for cancellation during:

- Handshake pending.
- Active upload.
- Active receive.
- Between files.
- Concurrent with peer cancellation.
- Concurrent with session cleanup.

### 2.8 Add encrypted-stream resource limits

The plan adds nonce overflow checks but does not include all stream-resource requirements from the security specification.

Add explicit requirements for:

- Maximum total size for unknown-size files.
- Maximum number of encrypted frames.
- Maximum buffered bytes while parsing a frame.
- Rejection of data after the sentinel.
- Exactly one sentinel.
- Partial-file deletion on every parser or authentication failure.
- No whole-file buffering.

These are availability controls and are required even though AEAD authentication prevents silent corruption.

## 3. Store-Release Requirements Missing From the Plan

### 3.1 Android signing and application identity

Add a dedicated release task for:

- Final Android namespace.
- Final unique application ID.
- Production release signing outside the repository.
- Google Play App Signing.
- Protected upload key.
- Removal of debug signing from every release variant.
- CI secret-handling review.
- Update testing with the same signing chain.

The current project uses a placeholder application ID and debug signing. These are release blockers, not optional cleanup.

### 3.2 Android cleartext network policy

The current manifest globally permits cleartext traffic. The plan must explicitly decide whether LAN HTTP remains part of the store product.

If HTTP remains:

- Document the local-network threat model.
- Scope cleartext permission as narrowly as technically possible.
- Ensure unrelated traffic cannot use cleartext.
- State that E2EE does not protect metadata, controls, or availability.
- Test hostile Wi-Fi, rogue peers, altered discovery, and captive portals.

If authenticated TLS or another secure local transport is adopted, define its certificate and peer-authentication model without weakening the existing E2EE layer.

### 3.3 macOS App Store release configuration

Add tasks for:

- App Sandbox entitlement review.
- Keychain behavior under App Store signing.
- Network client/server entitlement review.
- Removal of unnecessary Debug/JIT entitlements from Release.
- User-selected file and downloads access review.
- App Store update and reinstall testing.
- Verification that the network-server behavior is compatible with App Store distribution.

## 4. Verification Plan Required for Approval

The plan should replace the current two-command test list with the following test groups.

### Identity and trust

- Persistent seed restores identical public key and fingerprint.
- Verified trust survives transfer cleanup, process death, restart, and app update.
- Verified receiver key is included in msg1.
- Wrong pinned receiver is rejected.
- Changed verified identity is not accepted as the old peer.
- Old verified record is never overwritten.
- First contact remains untrusted.
- Previously seen unverified peer is never auto-promoted.
- Discovery keys never establish trust.

### Handshake and protocol

- msg1 and msg2 require version 2.
- Missing fields, malformed Base64, wrong lengths, invalid IDs, negative sizes, excessive metadata, and excessive file counts are rejected.
- Manifest alteration fails authentication.
- Transcript alteration fails key agreement.
- Directional keys differ.
- Intended receiver mismatch fails before the accept UI.

### Control messages

- Post-handshake cancellation is authenticated.
- Duplicate concurrent controls execute once.
- Replay-cache responses are stable.
- Wrong direction, gap, expired sequence, and modified duplicate are rejected.
- Cleanup cannot race an accepted control action.

### Encrypted streams

- Single and multi-frame round trips succeed.
- Empty file sentinel succeeds.
- Missing, duplicate, or malformed sentinel fails.
- Reordered, modified, oversized, and trailing frames fail.
- Unknown-size file policy is enforced.
- Large files do not cause whole-file memory growth.
- Nonce overflow fails before reuse.

### Platform and release

- macOS Keychain persists across restart, update, and App Store signing.
- Legacy storage migration preserves identity or requires explicit reset.
- Android secure storage persists across process death and update.
- Release artifacts are not debug-signed.
- Final application IDs are used.
- Logs contain no tokens, keys, signatures, or complete authentication bodies.
- Store builds contain no ordinary-file identity-key fallback.

## 5. Definition of Done

Security implementation is complete only when:

- All non-negotiable security invariants in the implementation specification pass.
- The identity-resolution and mismatch policy is documented and tested.
- Mutex scope includes business-action execution.
- Body limits are enforced before buffering.
- macOS migration and Keychain failure behavior are explicit.
- Android signing and cleartext policy are finalized.
- macOS entitlements are verified under App Store signing.
- All test groups above pass on supported platforms.
- Security reviewers receive release artifacts, test evidence, threat-model documentation, and redacted logs.

## Final Recommendation

Revise the implementation plan with the requirements in this document before beginning security-sensitive implementation. Once these details are incorporated, the plan will be suitable for engineering execution and formal security review. 
