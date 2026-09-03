import 'dart:convert';

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
  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final indexJson = await _storage.read(key: kTrustIndexKey);
      if (indexJson != null && indexJson.isNotEmpty) {
        final List<dynamic> fingerprints = jsonDecode(indexJson) as List<dynamic>;
        for (final fp in fingerprints) {
          if (fp is String) {
            final recordJson = await _storage.read(key: '$kTrustStorePrefix$fp');
            if (recordJson != null && recordJson.isNotEmpty) {
              try {
                final map = jsonDecode(recordJson) as Map<String, dynamic>;
                final record = PeerRecord.fromJson(map);
                _cache[record.fingerprint] = record;
              } catch (e) {
                debugPrint('[TrustStore] Failed to decode record for $fp: $e');
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[TrustStore] Failed to load trust index: $e');
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
