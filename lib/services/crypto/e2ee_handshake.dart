import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:oneshare/services/crypto/canonical_encoding.dart';

/// Representation of a file item for computing the canonical manifest hash.
class ManifestFileItem {
  const ManifestFileItem({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
}

/// Implements context-bound Ed25519 signing, verification, transcript computation,
/// and transcript-bound HKDF key derivation.
class E2eeHandshake {
  E2eeHandshake._();

  static final _sha256 = Sha256();
  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();

  /// Computes the canonical transfer-manifest hash from a list of files (§2.3.2):
  ///
  /// 1. Sort files lexicographically by `fileId` ascending.
  /// 2. For each file: `encode_string(fileId) + encode_string(fileName) + encode_uint64(fileSize)`.
  /// 3. Concat: `encode_string("oneshare-manifest-v2") + encode_uint32(sortedFiles.length) + manifestEntries`.
  /// 4. SHA-256 over canonical manifest.
  static Future<Uint8List> computeManifestHash(List<ManifestFileItem> files) async {
    final sorted = List<ManifestFileItem>.from(files)
      ..sort((a, b) => a.fileId.compareTo(b.fileId));

    final entryChunks = <Uint8List>[];
    for (final f in sorted) {
      entryChunks.add(CanonicalEncoding.encodeString(f.fileId));
      entryChunks.add(CanonicalEncoding.encodeString(f.fileName));
      entryChunks.add(CanonicalEncoding.encodeUint64(f.fileSize));
    }

    final canonicalManifest = CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-manifest-v2'),
      CanonicalEncoding.encodeUint32(sorted.length),
      ...entryChunks,
    ]);

    final hash = await _sha256.hash(canonicalManifest);
    return Uint8List.fromList(hash.bytes);
  }

  /// Computes the SHA-256 hash of the bearer transfer token.
  static Future<Uint8List> computeTokenHash(String transferToken) async {
    final hash = await _sha256.hash(utf8.encode(transferToken));
    return Uint8List.fromList(hash.bytes);
  }

  /// Generates a fresh ephemeral X25519 keypair for ECDH key exchange.
  static Future<SimpleKeyPair> generateEphemeralKeyPair() {
    return _x25519.newKeyPair();
  }

  /// Constructs canonical `signedData_msg1` (§2.3.4):
  ///
  /// ```
  /// signedData_msg1 = concat(
  ///   encode_string("oneshare-e2ee-v2-msg1-initiator"),
  ///   encode_string(transferId),
  ///   encode_bytes(manifestHash),
  ///   encode_bytes(senderEphemeralPubKey),
  ///   encode_bytes(intendedReceiverIdentityPubKey ?? [])
  /// )
  /// ```
  static Uint8List buildSignedDataMsg1({
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List senderEphemeralPubKey,
    Uint8List? intendedReceiverIdentityPubKey,
  }) {
    return CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-e2ee-v2-msg1-initiator'),
      CanonicalEncoding.encodeString(transferId),
      CanonicalEncoding.encodeBytes(manifestHash),
      CanonicalEncoding.encodeBytes(senderEphemeralPubKey),
      CanonicalEncoding.encodeBytes(
        intendedReceiverIdentityPubKey ?? Uint8List(0),
      ),
    ]);
  }

  /// Signs `signedData_msg1` with the sender's persistent Ed25519 identity key.
  static Future<Uint8List> signMsg1({
    required SimpleKeyPair senderIdentityKeyPair,
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List senderEphemeralPubKey,
    Uint8List? intendedReceiverIdentityPubKey,
  }) async {
    final signedData = buildSignedDataMsg1(
      transferId: transferId,
      manifestHash: manifestHash,
      senderEphemeralPubKey: senderEphemeralPubKey,
      intendedReceiverIdentityPubKey: intendedReceiverIdentityPubKey,
    );

    final signature = await _ed25519.sign(
      signedData,
      keyPair: senderIdentityKeyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies the sender's Ed25519 signature on msg1.
  static Future<bool> verifyMsg1({
    required Uint8List senderIdentityPubKey,
    required Uint8List signatureBytes,
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List senderEphemeralPubKey,
    Uint8List? intendedReceiverIdentityPubKey,
  }) async {
    final signedData = buildSignedDataMsg1(
      transferId: transferId,
      manifestHash: manifestHash,
      senderEphemeralPubKey: senderEphemeralPubKey,
      intendedReceiverIdentityPubKey: intendedReceiverIdentityPubKey,
    );

    final signature = Signature(
      signatureBytes,
      publicKey: SimplePublicKey(senderIdentityPubKey, type: KeyPairType.ed25519),
    );

    return _ed25519.verify(signedData, signature: signature);
  }

  /// Constructs canonical `signedData_msg2` (§2.3.5):
  ///
  /// ```
  /// signedData_msg2 = concat(
  ///   encode_string("oneshare-e2ee-v2-msg2-responder"),
  ///   encode_string(transferId),
  ///   encode_bytes(manifestHash),
  ///   encode_bytes(tokenHash),
  ///   encode_bytes(receiverEphemeralPubKey),
  ///   encode_bytes(senderEphemeralPubKey),
  ///   encode_bytes(senderIdentityPubKey)
  /// )
  /// ```
  static Uint8List buildSignedDataMsg2({
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List tokenHash,
    required Uint8List receiverEphemeralPubKey,
    required Uint8List senderEphemeralPubKey,
    required Uint8List senderIdentityPubKey,
  }) {
    return CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-e2ee-v2-msg2-responder'),
      CanonicalEncoding.encodeString(transferId),
      CanonicalEncoding.encodeBytes(manifestHash),
      CanonicalEncoding.encodeBytes(tokenHash),
      CanonicalEncoding.encodeBytes(receiverEphemeralPubKey),
      CanonicalEncoding.encodeBytes(senderEphemeralPubKey),
      CanonicalEncoding.encodeBytes(senderIdentityPubKey),
    ]);
  }

  /// Signs `signedData_msg2` with the receiver's persistent Ed25519 identity key.
  static Future<Uint8List> signMsg2({
    required SimpleKeyPair receiverIdentityKeyPair,
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List tokenHash,
    required Uint8List receiverEphemeralPubKey,
    required Uint8List senderEphemeralPubKey,
    required Uint8List senderIdentityPubKey,
  }) async {
    final signedData = buildSignedDataMsg2(
      transferId: transferId,
      manifestHash: manifestHash,
      tokenHash: tokenHash,
      receiverEphemeralPubKey: receiverEphemeralPubKey,
      senderEphemeralPubKey: senderEphemeralPubKey,
      senderIdentityPubKey: senderIdentityPubKey,
    );

    final signature = await _ed25519.sign(
      signedData,
      keyPair: receiverIdentityKeyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies the receiver's Ed25519 signature on msg2.
  static Future<bool> verifyMsg2({
    required Uint8List receiverIdentityPubKey,
    required Uint8List signatureBytes,
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List tokenHash,
    required Uint8List receiverEphemeralPubKey,
    required Uint8List senderEphemeralPubKey,
    required Uint8List senderIdentityPubKey,
  }) async {
    final signedData = buildSignedDataMsg2(
      transferId: transferId,
      manifestHash: manifestHash,
      tokenHash: tokenHash,
      receiverEphemeralPubKey: receiverEphemeralPubKey,
      senderEphemeralPubKey: senderEphemeralPubKey,
      senderIdentityPubKey: senderIdentityPubKey,
    );

    final signature = Signature(
      signatureBytes,
      publicKey: SimplePublicKey(receiverIdentityPubKey, type: KeyPairType.ed25519),
    );

    return _ed25519.verify(signedData, signature: signature);
  }

  /// Computes the canonical handshake transcript hash (§2.4):
  ///
  /// ```
  /// transcript = concat(
  ///   encode_string("oneshare-e2ee-v2-transcript"),
  ///   encode_byte(0x02),
  ///   encode_string(transferId),
  ///   encode_bytes(manifestHash),
  ///   encode_bytes(tokenHash),
  ///   encode_bytes(senderIdentityPubKey),
  ///   encode_bytes(receiverIdentityPubKey),
  ///   encode_bytes(senderEphemeralPubKey),
  ///   encode_bytes(receiverEphemeralPubKey)
  /// )
  /// ```
  static Future<Uint8List> computeTranscriptHash({
    required String transferId,
    required Uint8List manifestHash,
    required Uint8List tokenHash,
    required Uint8List senderIdentityPubKey,
    required Uint8List receiverIdentityPubKey,
    required Uint8List senderEphemeralPubKey,
    required Uint8List receiverEphemeralPubKey,
  }) async {
    final transcript = CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-e2ee-v2-transcript'),
      CanonicalEncoding.encodeByte(0x02),
      CanonicalEncoding.encodeString(transferId),
      CanonicalEncoding.encodeBytes(manifestHash),
      CanonicalEncoding.encodeBytes(tokenHash),
      CanonicalEncoding.encodeBytes(senderIdentityPubKey),
      CanonicalEncoding.encodeBytes(receiverIdentityPubKey),
      CanonicalEncoding.encodeBytes(senderEphemeralPubKey),
      CanonicalEncoding.encodeBytes(receiverEphemeralPubKey),
    ]);

    final hash = await _sha256.hash(transcript);
    return Uint8List.fromList(hash.bytes);
  }

  /// Computes the X25519 shared secret between our ephemeral private key
  /// and peer's ephemeral public key.
  static Future<SecretKey> computeSharedSecret({
    required SimpleKeyPair myEphemeralKeyPair,
    required Uint8List peerEphemeralPubKey,
  }) {
    return _x25519.sharedSecretKey(
      keyPair: myEphemeralKeyPair,
      remotePublicKey: SimplePublicKey(peerEphemeralPubKey, type: KeyPairType.x25519),
    );
  }

  /// Derives the 32-byte session master key using HKDF-SHA256:
  ///
  /// ```
  /// sessionMasterKey = HKDF-SHA256(
  ///   IKM:  sharedSecret,
  ///   salt: transcriptHash,
  ///   info: "oneshare-e2ee-v2-session-master",
  ///   length: 32
  /// )
  /// ```
  static Future<SecretKey> deriveSessionMasterKey({
    required SecretKey sharedSecret,
    required Uint8List transcriptHash,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-session-master'),
    );
  }

  /// Derives directional base keys, control keys, and sasBytes from session master key (§2.4):
  ///
  /// - `senderFileBaseKey`: info = "oneshare-e2ee-v2-sender-file", length = 32
  /// - `receiverFileBaseKey`: info = "oneshare-e2ee-v2-receiver-file", length = 32
  /// - `senderCtrlKey`: info = "oneshare-e2ee-v2-sender-ctrl", length = 32
  /// - `receiverCtrlKey`: info = "oneshare-e2ee-v2-receiver-ctrl", length = 32
  /// - `sasBytes`: info = "oneshare-e2ee-v2-sas", length = 4
  static Future<DerivedKeys> deriveDirectionalKeys({
    required SecretKey sessionMasterKey,
    required Uint8List transcriptHash,
  }) async {
    final hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final hkdf4 = Hkdf(hmac: Hmac.sha256(), outputLength: 4);

    final senderFileBaseKey = await hkdf32.deriveKey(
      secretKey: sessionMasterKey,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-sender-file'),
    );

    final receiverFileBaseKey = await hkdf32.deriveKey(
      secretKey: sessionMasterKey,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-receiver-file'),
    );

    final senderCtrlKey = await hkdf32.deriveKey(
      secretKey: sessionMasterKey,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-sender-ctrl'),
    );

    final receiverCtrlKey = await hkdf32.deriveKey(
      secretKey: sessionMasterKey,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-receiver-ctrl'),
    );

    final sasSecret = await hkdf4.deriveKey(
      secretKey: sessionMasterKey,
      nonce: transcriptHash,
      info: utf8.encode('oneshare-e2ee-v2-sas'),
    );

    final sasBytes = Uint8List.fromList(await sasSecret.extractBytes());

    return DerivedKeys(
      senderFileBaseKey: senderFileBaseKey,
      receiverFileBaseKey: receiverFileBaseKey,
      senderCtrlKey: senderCtrlKey,
      receiverCtrlKey: receiverCtrlKey,
      sasBytes: sasBytes,
    );
  }

  /// Derives per-file subkey using unique `fileId` alone (§2.5):
  ///
  /// ```
  /// fileKey = HKDF-SHA256(
  ///   IKM:  directionFileBaseKey,
  ///   salt: transcriptHash,
  ///   info: concat(
  ///     encode_string("oneshare-e2ee-v2-file-key"),
  ///     encode_string(fileId)
  ///   ),
  ///   length: 32
  /// )
  /// ```
  static Future<SecretKey> deriveFileKey({
    required SecretKey directionFileBaseKey,
    required Uint8List transcriptHash,
    required String fileId,
  }) {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final info = CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-e2ee-v2-file-key'),
      CanonicalEncoding.encodeString(fileId),
    ]);

    return hkdf.deriveKey(
      secretKey: directionFileBaseKey,
      nonce: transcriptHash,
      info: info,
    );
  }
}

/// Container for all session keys derived from HKDF.
class DerivedKeys {
  const DerivedKeys({
    required this.senderFileBaseKey,
    required this.receiverFileBaseKey,
    required this.senderCtrlKey,
    required this.receiverCtrlKey,
    required this.sasBytes,
  });

  final SecretKey senderFileBaseKey;
  final SecretKey receiverFileBaseKey;
  final SecretKey senderCtrlKey;
  final SecretKey receiverCtrlKey;
  final Uint8List sasBytes;
}
