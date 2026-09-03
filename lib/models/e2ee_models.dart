import 'dart:convert';
import 'dart:typed_data';

/// The cryptographic trust level of a peer identity.
enum TrustLevel {
  /// First-time peer; connection is encrypted, but the identity has never
  /// been seen before and is completely untrusted.
  untrusted,

  /// Peer whose identity key was seen in a previous session, but has NEVER
  /// been manually verified via out-of-band SAS comparison.
  ///
  /// Merely recognized as previously seen; NOT trusted.
  unverifiedSeen,

  /// Peer whose identity fingerprint was explicitly compared and confirmed
  /// out-of-band via SAS verification. Cryptographically trusted.
  manuallyVerified,
}

/// A persistent record of a known peer identity stored in [TrustStore].
class PeerRecord {
  PeerRecord({
    required this.fingerprint,
    required this.identityPublicKeyBytes,
    required this.deviceName,
    required this.deviceId,
    required this.trustLevel,
    required this.firstSeen,
    required this.lastSeen,
  });

  /// Primary key: SHA-256 hex string of the Ed25519 public key (64 characters).
  final String fingerprint;

  /// Raw 32-byte Ed25519 public key.
  final Uint8List identityPublicKeyBytes;

  /// Mutable display metadata reported by peer (may change).
  String deviceName;

  /// Mutable transport metadata reported by peer (may change; zero cryptographic significance).
  String deviceId;

  /// Cryptographic trust level.
  TrustLevel trustLevel;

  /// Timestamp when this identity was first encountered.
  final DateTime firstSeen;

  /// Timestamp of the most recent interaction with this identity.
  DateTime lastSeen;

  /// Whether this peer is cryptographically verified and trusted.
  bool get isTrusted => trustLevel == TrustLevel.manuallyVerified;

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'identityPublicKeyBytes': base64Encode(identityPublicKeyBytes),
        'deviceName': deviceName,
        'deviceId': deviceId,
        'trustLevel': trustLevel.name,
        'firstSeen': firstSeen.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory PeerRecord.fromJson(Map<String, dynamic> json) {
    return PeerRecord(
      fingerprint: json['fingerprint'] as String,
      identityPublicKeyBytes:
          Uint8List.fromList(base64Decode(json['identityPublicKeyBytes'] as String)),
      deviceName: json['deviceName'] as String? ?? 'Unknown',
      deviceId: json['deviceId'] as String? ?? '',
      trustLevel: TrustLevel.values.firstWhere(
        (e) => e.name == json['trustLevel'],
        orElse: () => TrustLevel.unverifiedSeen,
      ),
      firstSeen: DateTime.parse(json['firstSeen'] as String),
      lastSeen: DateTime.parse(json['lastSeen'] as String),
    );
  }
}

/// Result of evaluating an incoming peer identity against [TrustStore].
class PeerTrustEvaluation {
  const PeerTrustEvaluation({
    required this.fingerprint,
    required this.trustLevel,
    required this.isKnownFingerprint,
    required this.hasIdentityMismatchForDeviceName,
    this.existingRecord,
    this.mismatchedRecord,
  });

  /// The fingerprint of the evaluated peer.
  final String fingerprint;

  /// The resolved trust level for this session.
  final TrustLevel trustLevel;

  /// Whether this exact fingerprint exists in the trust store.
  final bool isKnownFingerprint;

  /// True if a known deviceName or deviceId is already associated with a
  /// DIFFERENT fingerprint (potential MITM or key reset warning).
  final bool hasIdentityMismatchForDeviceName;

  /// The stored record for this fingerprint, if any.
  final PeerRecord? existingRecord;

  /// The conflicting record if a known device name presented a different fingerprint.
  final PeerRecord? mismatchedRecord;
}
