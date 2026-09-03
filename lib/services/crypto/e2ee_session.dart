import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/sas_verification.dart';

/// State of an active or pending E2EE session.
enum E2eeSessionState {
  initial,
  msg1Sent,
  msg1Received,
  msg2Sent,
  msg2Received,
  keysDerived,
  active,
  destroyed,
}

/// Represents an encrypted transfer session for a specific `transferId`.
///
/// Encapsulates ephemeral keys, transcript hash, derived session/file/ctrl keys,
/// SAS security codes, peer trust level, and best-effort key zeroization.
class E2eeSession {
  E2eeSession({
    required this.transferId,
    required this.isInitiator,
    required this.myIdentityKeyPair,
    required this.myIdentityPubKey,
  }) : state = E2eeSessionState.initial;

  final String transferId;
  final bool isInitiator;
  final SimpleKeyPair myIdentityKeyPair;
  final Uint8List myIdentityPubKey;

  E2eeSessionState state;

  // Handshake parameters
  SimpleKeyPair? myEphemeralKeyPair;
  Uint8List? myEphemeralPubKey;
  Uint8List? peerEphemeralPubKey;
  Uint8List? peerIdentityPubKey;
  Uint8List? intendedReceiverIdentityPubKey;
  String? peerFingerprint;
  String? peerDeviceId;
  Uint8List? manifestHash;
  Uint8List? tokenHash;
  Uint8List? transcriptHash;

  // Trust evaluation for this session
  TrustLevel trustLevel = TrustLevel.untrusted;
  String? sasCode;

  // Derived cryptographic keys
  SecretKey? sessionMasterKey;
  SecretKey? senderFileBaseKey;
  SecretKey? receiverFileBaseKey;
  SecretKey? senderCtrlKey;
  SecretKey? receiverCtrlKey;
  Uint8List? sasBytes;

  // Authenticated control channels
  ControlMessageChannel? outgoingCtrlChannel;
  ControlMessageChannel? incomingCtrlChannel;

  /// Returns the appropriate file base key depending on our role.
  SecretKey? get myOutgoingFileBaseKey =>
      isInitiator ? senderFileBaseKey : receiverFileBaseKey;

  /// Returns the appropriate incoming file base key depending on our role.
  SecretKey? get myIncomingFileBaseKey =>
      isInitiator ? receiverFileBaseKey : senderFileBaseKey;

  /// Returns the outgoing control key for HMAC authentication.
  SecretKey? get myOutgoingCtrlKey =>
      isInitiator ? senderCtrlKey : receiverCtrlKey;

  /// Returns the incoming control key for HMAC verification.
  SecretKey? get myIncomingCtrlKey =>
      isInitiator ? receiverCtrlKey : senderCtrlKey;

  /// Derives all session keys after successful handshake exchange.
  Future<void> deriveKeys({
    required SecretKey sharedSecret,
    required Uint8List transcriptHash,
  }) async {
    this.transcriptHash = transcriptHash;

    sessionMasterKey = await E2eeHandshake.deriveSessionMasterKey(
      sharedSecret: sharedSecret,
      transcriptHash: transcriptHash,
    );

    final derived = await E2eeHandshake.deriveDirectionalKeys(
      sessionMasterKey: sessionMasterKey!,
      transcriptHash: transcriptHash,
    );

    senderFileBaseKey = derived.senderFileBaseKey;
    receiverFileBaseKey = derived.receiverFileBaseKey;
    senderCtrlKey = derived.senderCtrlKey;
    receiverCtrlKey = derived.receiverCtrlKey;
    sasBytes = derived.sasBytes;
    sasCode = SasVerification.deriveSasCode(sasBytes!);

    // Initialize authenticated control message channels
    final outgoingDirection = isInitiator ? 'sender_to_receiver' : 'receiver_to_sender';
    final incomingDirection = isInitiator ? 'receiver_to_sender' : 'sender_to_receiver';
    outgoingCtrlChannel = ControlMessageChannel(
      transferId: transferId,
      direction: outgoingDirection,
      ctrlKey: myOutgoingCtrlKey!,
    );
    incomingCtrlChannel = ControlMessageChannel(
      transferId: transferId,
      direction: incomingDirection,
      ctrlKey: myIncomingCtrlKey!,
    );

    state = E2eeSessionState.keysDerived;
  }

  /// Derives the encryption/decryption key for a specific file using its unique `fileId`.
  Future<SecretKey> deriveFileKeyForId(String fileId) async {
    if (transcriptHash == null || myOutgoingFileBaseKey == null) {
      throw StateError('Cannot derive file key: session keys have not been established');
    }
    return E2eeHandshake.deriveFileKey(
      directionFileBaseKey: myOutgoingFileBaseKey!,
      transcriptHash: transcriptHash!,
      fileId: fileId,
    );
  }

  /// Derives the decryption key for an incoming file using its unique `fileId`.
  Future<SecretKey> deriveIncomingFileKeyForId(String fileId) async {
    if (transcriptHash == null || myIncomingFileBaseKey == null) {
      throw StateError('Cannot derive file key: session keys have not been established');
    }
    return E2eeHandshake.deriveFileKey(
      directionFileBaseKey: myIncomingFileBaseKey!,
      transcriptHash: transcriptHash!,
      fileId: fileId,
    );
  }

  /// Performs best-effort key zeroization and transitions session to destroyed state.
  ///
  /// DART GC ZEROIZATION BOUNDARIES & LIMITATIONS:
  /// Pure Dart applications running on the Dart VM or Flutter runtime operate under
  /// automatic garbage collection without pinned raw heap allocation primitives.
  /// While mutable byte lists ([Uint8List]) can have their underlying bytes explicitly
  /// overwritten with zeros via [List.fillRange], the following limitations apply:
  /// 1. Immutable objects (such as [String] instances used for fingerprints, Base64
  ///    representations, or tokens) cannot be overwritten in-place in Dart heap memory.
  /// 2. Intermediate copies created by internal cryptographic primitives (e.g. package:cryptography
  ///    or native BoringSSL wrappers during HKDF/HMAC/ChaCha20 operations) reside in
  ///    transient heap buffers that remain until swept and reclaimed by the garbage collector.
  /// 3. To guarantee zero residual key-memory risk, native C/Rust interop with pinned
  ///    `mlock` / `sodium_memzero` boundaries would be required. In pure Flutter/Dart,
  ///    best-effort zeroization explicitly zeroes all accessible mutable byte arrays,
  ///    releases references immediately to permit GC reclamation, and closes active channels.
  Future<void> destroy() async {
    state = E2eeSessionState.destroyed;

    // Overwrite ephemeral key bytes if accessible
    if (myEphemeralKeyPair != null) {
      try {
        final priv = await myEphemeralKeyPair!.extractPrivateKeyBytes();
        priv.fillRange(0, priv.length, 0);
      } catch (_) {}
      myEphemeralKeyPair = null;
    }

    if (myEphemeralPubKey != null) {
      myEphemeralPubKey!.fillRange(0, myEphemeralPubKey!.length, 0);
      myEphemeralPubKey = null;
    }

    if (peerEphemeralPubKey != null) {
      peerEphemeralPubKey!.fillRange(0, peerEphemeralPubKey!.length, 0);
      peerEphemeralPubKey = null;
    }

    if (peerIdentityPubKey != null) {
      peerIdentityPubKey!.fillRange(0, peerIdentityPubKey!.length, 0);
      peerIdentityPubKey = null;
    }

    if (manifestHash != null) {
      manifestHash!.fillRange(0, manifestHash!.length, 0);
      manifestHash = null;
    }

    if (tokenHash != null) {
      tokenHash!.fillRange(0, tokenHash!.length, 0);
      tokenHash = null;
    }

    if (transcriptHash != null) {
      transcriptHash!.fillRange(0, transcriptHash!.length, 0);
      transcriptHash = null;
    }

    if (sasBytes != null) {
      sasBytes!.fillRange(0, sasBytes!.length, 0);
      sasBytes = null;
    }

    sessionMasterKey = null;
    senderFileBaseKey = null;
    receiverFileBaseKey = null;
    senderCtrlKey = null;
    receiverCtrlKey = null;
    outgoingCtrlChannel = null;
    incomingCtrlChannel = null;
  }
}
