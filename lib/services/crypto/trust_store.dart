import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';

/// Persistent trust store managing known peer identities and their trust levels.
///
/// Strictly adheres to the 3-state trust model:
/// - Unverified first contact is recorded as [TrustLevel.unverifiedSeen] ("seen")
///   and is NEVER automatically promoted to trusted.
/// - Merely seen or recognized identities are explicitly not equivalent to
///   manually verified identities and remain untrusted.
/// - Only explicit out-of-band SAS confirmation elevates status to
class TrustStorageException implements Exception {
  TrustStorageException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'TrustStorageException: $message';
}

class TrustCorruptedException implements Exception {
  TrustCorruptedException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'TrustCorruptedException: $message';
}

/// Persistent store managing peer trust levels.
///
/// Features:
/// - 3-state trust lifecycle: untrusted -> unverifiedSeen -> manuallyVerified.
/// - Unseen peers default to [TrustLevel.untrusted].
/// - First connection is recorded as [TrustLevel.unverifiedSeen] (NOT trusted).
/// - Manual out-of-band SAS code confirmation permanently elevates peer to
///   [TrustLevel.manuallyVerified].
/// - Identity change detection flags if a known device name/ID connects with an
///   unexpected fingerprint.
class TrustStore {
  TrustStore({KeyStorage? storage}) : _storage = storage ?? CryptoKeyStorage();

  static const String kTrustStorePrefix = 'oneshare_trust_peer_';
  static const String kTrustIndexKey = 'oneshare_trust_index_fingerprints';

  final KeyStorage _storage;
  final Map<String, PeerRecord> _cache = {};
  bool _isLoaded = false;

  /// Loads all stored peer records from persistent storage into memory cache.
  ///
  /// CRITICAL SECURITY GUARANTEES:
  /// - Fails closed on storage error throwing [TrustStorageException].
  /// - Fails closed on corrupted JSON, invalid fingerprint, or key-hash mismatch
  ///   throwing [TrustCorruptedException].
  /// - Cache is NOT marked loaded on error.
  Future<void> load() async {
    if (_isLoaded) return;

    final String? indexJson;
    try {
      indexJson = await _storage.read(key: kTrustIndexKey);
    } catch (e) {
      _cache.clear();
      throw TrustStorageException('Failed to read trust index from secure storage', e);
    }

    if (indexJson != null && indexJson.isNotEmpty) {
      final dynamic decodedIndex;
      try {
        decodedIndex = jsonDecode(indexJson);
      } catch (e) {
        _cache.clear();
        throw TrustCorruptedException('Malformed trust index JSON in storage', e);
      }

      if (decodedIndex is! List) {
        _cache.clear();
        throw TrustCorruptedException('Trust index JSON root is not a list');
      }

      final seenFps = <String>{};
      for (final fp in decodedIndex) {
        if (fp is! String || fp.length != 64) {
          _cache.clear();
          throw TrustCorruptedException('Invalid or corrupted fingerprint in trust index: $fp');
        }

        if (seenFps.contains(fp)) {
          _cache.clear();
          throw TrustCorruptedException('Duplicate fingerprint entry detected in trust index: $fp');
        }
        seenFps.add(fp);

        final String? recordJson;
        try {
          recordJson = await _storage.read(key: '$kTrustStorePrefix$fp');
        } catch (e) {
          _cache.clear();
          throw TrustStorageException('Failed to read trust peer record for $fp', e);
        }

        if (recordJson == null || recordJson.isEmpty) {
          _cache.clear();
          throw TrustCorruptedException('Missing trust peer record for indexed fingerprint: $fp');
        }

        final dynamic decodedRecord;
        try {
          decodedRecord = jsonDecode(recordJson);
        } catch (e) {
          _cache.clear();
          throw TrustCorruptedException('Malformed peer record JSON for fingerprint: $fp', e);
        }

        if (decodedRecord is! Map<String, dynamic>) {
          _cache.clear();
          throw TrustCorruptedException('Peer record is not a valid JSON map for: $fp');
        }

        final PeerRecord record;
        try {
          record = PeerRecord.fromJson(decodedRecord);
        } catch (e) {
          _cache.clear();
          throw TrustCorruptedException('Failed to parse PeerRecord for fingerprint: $fp', e);
        }

        if (record.fingerprint != fp) {
          _cache.clear();
          throw TrustCorruptedException('Mismatched fingerprint inside PeerRecord for: $fp');
        }

        if (record.identityPublicKeyBytes.length != 32) {
          _cache.clear();
          throw TrustCorruptedException('Invalid public key byte length in PeerRecord for: $fp');
        }

        // Cryptographic verification: Assert SHA-256 of public key matches fingerprint
        final calculatedHash = await Sha256().hash(record.identityPublicKeyBytes);
        final calculatedFp = calculatedHash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (calculatedFp != record.fingerprint) {
          _cache.clear();
          throw TrustCorruptedException('Cryptographic mismatch: public key does not match fingerprint for: $fp');
        }

        _cache[record.fingerprint] = record;
      }
    }

    _isLoaded = true;
  }

  /// Returns a peer record by [fingerprint], or `null` if unknown.
  Future<PeerRecord?> getPeer(String fingerprint) async {
    await load();
    return _cache[fingerprint];
  }

  /// Synchronously looks up a cached record by [fingerprint].
  PeerRecord? getCachedPeer(String fingerprint) {
    return _cache[fingerprint];
  }

  /// Returns all stored peer records.
  Future<List<PeerRecord>> getAllPeers() async {
    await load();
    return _cache.values.toList();
  }

  /// Evaluates an incoming peer's trust status without modifying the store.
  ///
  /// Detects whether:
  /// 1. The identity fingerprint is already known.
  /// 2. The peer is verified vs seen vs untrusted.
  /// 3. A known device name or device ID is presenting a DIFFERENT fingerprint
  ///    than previously seen/verified (potential MITM or key reset).
  Future<PeerTrustEvaluation> evaluatePeer({
    required String fingerprint,
    required String deviceName,
    required String deviceId,
  }) async {
    await load();

    final existing = _cache[fingerprint];
    if (existing != null) {
      return PeerTrustEvaluation(
        fingerprint: fingerprint,
        trustLevel: existing.trustLevel,
        isKnownFingerprint: true,
        hasIdentityMismatchForDeviceName: false,
        existingRecord: existing,
      );
    }

    // Fingerprint is new/unseen. Check if deviceName or deviceId conflicts
    // with an already stored peer.
    PeerRecord? conflictingRecord;
    for (final peer in _cache.values) {
      if (peer.fingerprint != fingerprint) {
        final nameMatches = peer.deviceName.trim().toLowerCase() == deviceName.trim().toLowerCase();
        final idMatches = deviceId.isNotEmpty && peer.deviceId == deviceId;
        if (nameMatches || idMatches) {
          conflictingRecord = peer;
          break;
        }
      }
    }

    return PeerTrustEvaluation(
      fingerprint: fingerprint,
      trustLevel: TrustLevel.untrusted,
      isKnownFingerprint: false,
      hasIdentityMismatchForDeviceName: conflictingRecord != null,
      mismatchedRecord: conflictingRecord,
    );
  }

  /// Records or updates a peer identity encountered during a transfer.
  ///
  /// Rules:
  /// - If the fingerprint is brand new, it is recorded as [TrustLevel.unverifiedSeen].
  ///   It is NEVER auto-promoted to trusted.
  /// - If the fingerprint was already stored, its [deviceName], [deviceId], and
  ///   [lastSeen] are updated, but its [trustLevel] is preserved (e.g. an
  ///   unverified peer remains unverified, a manually verified peer remains verified).
  Future<PeerRecord> recordPeerEncounter({
    required String fingerprint,
    required Uint8List identityPublicKeyBytes,
    required String deviceName,
    required String deviceId,
  }) async {
    await load();

    final existing = _cache[fingerprint];
    final now = DateTime.now();

    if (existing != null) {
      existing.deviceName = deviceName;
      existing.deviceId = deviceId;
      existing.lastSeen = now;
      await _persistRecord(existing);
      return existing;
    }

    final newRecord = PeerRecord(
      fingerprint: fingerprint,
      identityPublicKeyBytes: identityPublicKeyBytes,
      deviceName: deviceName,
      deviceId: deviceId,
      trustLevel: TrustLevel.unverifiedSeen,
      firstSeen: now,
      lastSeen: now,
    );

    _cache[fingerprint] = newRecord;
    await _persistRecord(newRecord);
    await _persistIndex();
    return newRecord;
  }

  /// Explicitly marks a peer fingerprint as [TrustLevel.manuallyVerified].
  ///
  /// This must ONLY be invoked after explicit out-of-band SAS code confirmation.
  Future<PeerRecord> markManuallyVerified({
    required String fingerprint,
    required Uint8List identityPublicKeyBytes,
    required String deviceName,
    required String deviceId,
  }) async {
    await load();

    final existing = _cache[fingerprint];
    final now = DateTime.now();

    if (existing != null) {
      existing.trustLevel = TrustLevel.manuallyVerified;
      existing.deviceName = deviceName;
      existing.deviceId = deviceId;
      existing.lastSeen = now;
      await _persistRecord(existing);
      return existing;
    }

    final verifiedRecord = PeerRecord(
      fingerprint: fingerprint,
      identityPublicKeyBytes: identityPublicKeyBytes,
      deviceName: deviceName,
      deviceId: deviceId,
      trustLevel: TrustLevel.manuallyVerified,
      firstSeen: now,
      lastSeen: now,
    );

    _cache[fingerprint] = verifiedRecord;
    await _persistRecord(verifiedRecord);
    await _persistIndex();
    return verifiedRecord;
  }

  /// Finds candidate peer records matching a discovered [deviceId] or [deviceName].
  ///
  /// Used for peer identity resolution:
  /// - Returns a list of candidate stored records.
  /// - If exactly one candidate is returned and is [TrustLevel.manuallyVerified],
  ///   the sender can bind its public key.
  /// - If multiple records or no records match, the lookup is ambiguous and
  ///   the caller must treat the connection as untrusted.
  Future<List<PeerRecord>> findCandidatePeers({
    String? deviceId,
    String? deviceName,
  }) async {
    await load();
    final candidates = <PeerRecord>[];

    for (final peer in _cache.values) {
      final idMatch = deviceId != null && deviceId.isNotEmpty && peer.deviceId == deviceId;
      final nameMatch = deviceName != null &&
          deviceName.trim().isNotEmpty &&
          peer.deviceName.trim().toLowerCase() == deviceName.trim().toLowerCase();

      if (idMatch || nameMatch) {
        candidates.add(peer);
      }
    }

    return candidates;
  }

  /// Removes a peer identity record from the store.
  Future<void> removePeer(String fingerprint) async {
    await load();
    if (_cache.containsKey(fingerprint)) {
      _cache.remove(fingerprint);
      await _storage.delete(key: '$kTrustStorePrefix$fingerprint');
      await _persistIndex();
    }
  }

  /// Clears all stored peer records.
  Future<void> clearAll() async {
    await load();
    for (final fp in _cache.keys) {
      await _storage.delete(key: '$kTrustStorePrefix$fp');
    }
    _cache.clear();
    await _storage.delete(key: kTrustIndexKey);
  }

  Future<void> _persistRecord(PeerRecord record) async {
    final jsonStr = jsonEncode(record.toJson());
    await _storage.write(key: '$kTrustStorePrefix${record.fingerprint}', value: jsonStr);
  }

  Future<void> _persistIndex() async {
    final indexJson = jsonEncode(_cache.keys.toList());
    await _storage.write(key: kTrustIndexKey, value: indexJson);
  }
}
