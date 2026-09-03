import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:oneshare/config/app_environment.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';

/// Represents the cryptographic and network identity of this device.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.deviceName,
    required this.identityKeyPair,
    required this.identityPublicKeyBytes,
    required this.fingerprint,
  });

  /// Ephemeral or persisted UUID v4 device identifier (used as non-security transport metadata).
  final String deviceId;

  /// User-visible device display name (e.g. "OneShare-1234").
  final String deviceName;

  /// Persistent Ed25519 keypair used to sign ephemeral handshake parameters.
  final SimpleKeyPair identityKeyPair;

  /// Raw 32-byte Ed25519 public key.
  final Uint8List identityPublicKeyBytes;

  /// SHA-256 hex string of [identityPublicKeyBytes] (64 characters).
  ///
  /// This serves as the primary immutable trust anchor.
  final String fingerprint;

  /// Formatted fingerprint grouped in 4-character chunks for UI display
  /// (e.g. "3475 0f98 bd59 ...").
  String get formattedFingerprint => DeviceIdentityService.formatFingerprint(fingerprint);

  /// Abbreviated fingerprint showing the first 16 hex characters.
  String get shortFingerprint {
    if (fingerprint.length >= 16) {
      return fingerprint.substring(0, 16);
    }
    return fingerprint;
  }
}

class IdentityStorageException implements Exception {
  IdentityStorageException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'IdentityStorageException: $message';
}

class IdentityCorruptedException implements Exception {
  IdentityCorruptedException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'IdentityCorruptedException: $message';
}

/// Service managing persistent device identity and Ed25519 signing keypair.
class DeviceIdentityService {
  DeviceIdentityService._();

  /// Formats any 64-character hex fingerprint into grouped 4-character blocks.
  static String formatFingerprint(String fp) {
    final buffer = StringBuffer();
    for (int i = 0; i < fp.length; i += 4) {
      if (i > 0) buffer.write(' ');
      final end = (i + 4 <= fp.length) ? i + 4 : fp.length;
      buffer.write(fp.substring(i, end));
    }
    return buffer.toString();
  }

  static const String kDeviceIdKey = 'oneshare_device_id';
  static const String kDeviceNameKey = 'oneshare_device_name';
  static const String kIdentityPrivateKeyKey = 'oneshare_identity_priv_key_b64';
  static const String kIdentityCommittedKey = 'oneshare_identity_committed';

  static DeviceIdentity? _identity;

  /// Whether the persistent identity has been initialized from storage.
  static bool get isInitialized => _identity != null;

  /// Synchronous access to device identity.
  ///
  /// In staging and production environments, accessing identity before [initialize]
  /// has successfully completed throws a [StateError] (fail-closed).
  /// In unit tests and development, lazily generates a fallback identity.
  static DeviceIdentity get identity {
    if (_identity != null) return _identity!;
    if (AppEnvironment.current.type == EnvironmentType.staging ||
        AppEnvironment.current.type == EnvironmentType.production) {
      throw StateError(
        '[DeviceIdentityService] Identity accessed before initialize() in secure environment (${AppEnvironment.current.type.name}).',
      );
    }
    return _identity ??= _createFallbackIdentity();
  }

  /// Initializes the device identity from [storage].
  ///
  /// If an identity already exists in [storage], it is loaded and restored.
  /// If storage is clean/empty (fresh install), a new UUID, device name,
  /// and Ed25519 keypair are generated and persisted.
  ///
  /// CRITICAL SECURITY GUARANTEES:
  /// 1. Storage read errors fail closed with [IdentityStorageException].
  /// 2. Corrupted or partially-written keys fail closed with [IdentityCorruptedException].
  /// 3. Existing valid Phase 1 identities (missing commit marker) are backfilled automatically.
  /// 4. A new identity is NEVER generated automatically on storage failure or corruption.
  static Future<DeviceIdentity> initialize({KeyStorage? storage}) async {
    final store = storage ?? CryptoKeyStorage();

    if (store is CryptoKeyStorage) {
      await store.migrateLegacyFileIfNeeded();
    }

    String? storedDeviceId;
    String? storedDeviceName;
    String? storedPrivKeyB64;
    String? storedCommitted;

    try {
      storedDeviceId = await store.read(key: kDeviceIdKey);
      storedDeviceName = await store.read(key: kDeviceNameKey);
      storedPrivKeyB64 = await store.read(key: kIdentityPrivateKeyKey);
      storedCommitted = await store.read(key: kIdentityCommittedKey);
    } catch (e) {
      throw IdentityStorageException(
        'Failed to read persistent identity from secure storage. Halting startup.',
        e,
      );
    }

    final hasAnyStored = (storedDeviceId != null && storedDeviceId.isNotEmpty) ||
        (storedDeviceName != null && storedDeviceName.isNotEmpty) ||
        (storedPrivKeyB64 != null && storedPrivKeyB64.isNotEmpty) ||
        (storedCommitted != null && storedCommitted.isNotEmpty);

    if (hasAnyStored) {
      // Must have all three identity fields completely intact
      if (storedDeviceId == null ||
          storedDeviceId.isEmpty ||
          storedDeviceName == null ||
          storedDeviceName.isEmpty ||
          storedPrivKeyB64 == null ||
          storedPrivKeyB64.isEmpty) {
        throw IdentityCorruptedException(
          'Persistent identity state in storage is incomplete or corrupted. Refusing silent regeneration.',
        );
      }

      final Uint8List privBytes;
      try {
        privBytes = Uint8List.fromList(base64Decode(storedPrivKeyB64));
        if (privBytes.length != 32) {
          throw IdentityCorruptedException(
            'Stored Ed25519 private seed has invalid length (${privBytes.length} bytes; expected 32).',
          );
        }
      } catch (e) {
        if (e is IdentityCorruptedException) rethrow;
        throw IdentityCorruptedException(
          'Failed to decode stored Ed25519 private key: $e',
          e,
        );
      }

      // Backfill commit marker for existing valid Phase 1 identities
      if (storedCommitted == null || storedCommitted != 'true') {
        try {
          await store.write(key: kIdentityCommittedKey, value: 'true');
        } catch (e) {
          throw IdentityStorageException(
            'Failed to backfill identity commit marker to secure storage: $e',
            e,
          );
        }
      }

      try {
        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPairFromSeed(privBytes);
        final pubKey = await keyPair.extractPublicKey();
        final pubBytes = Uint8List.fromList(pubKey.bytes);
        final fingerprint = await computeFingerprint(pubBytes);

        final loaded = DeviceIdentity(
          deviceId: storedDeviceId,
          deviceName: storedDeviceName,
          identityKeyPair: keyPair,
          identityPublicKeyBytes: pubBytes,
          fingerprint: fingerprint,
        );
        _identity = loaded;
        return loaded;
      } catch (e) {
        throw IdentityCorruptedException(
          'Failed to restore Ed25519 keypair from validated seed: $e',
          e,
        );
      }
    }

    // Completely empty storage: bootstrap fresh persistent identity transactionally
    final newDeviceId = _generateUuidV4();
    final newDeviceName = _generateDeviceName();

    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPair();
    final privBytes = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final pubKey = await keyPair.extractPublicKey();
    final pubBytes = Uint8List.fromList(pubKey.bytes);
    final fingerprint = await computeFingerprint(pubBytes);

    try {
      // Transactional write order: private seed -> device id -> device name -> commit marker
      await store.write(key: kIdentityPrivateKeyKey, value: base64Encode(privBytes));
      await store.write(key: kDeviceIdKey, value: newDeviceId);
      await store.write(key: kDeviceNameKey, value: newDeviceName);
      await store.write(key: kIdentityCommittedKey, value: 'true');
    } catch (e) {
      throw IdentityStorageException(
        'Failed to persist newly generated device identity to storage: $e',
        e,
      );
    }

    final newIdentity = DeviceIdentity(
      deviceId: newDeviceId,
      deviceName: newDeviceName,
      identityKeyPair: keyPair,
      identityPublicKeyBytes: pubBytes,
      fingerprint: fingerprint,
    );
    _identity = newIdentity;
    return newIdentity;
  }

  /// Explicit user-initiated identity reset.
  ///
  /// Atomically clears stored identity keys AND invalidates the entire trust store.
  /// A newly generated identity will NEVER inherit old trust records.
  /// Must only be invoked following explicit user confirmation.
  static Future<DeviceIdentity> resetIdentity({
    required KeyStorage storage,
    TrustStore? trustStore,
  }) async {
    // 1. Purge all peer trust records and the trust index
    if (trustStore != null) {
      await trustStore.clearAll();
    } else {
      final store = TrustStore(storage: storage);
      await store.clearAll();
    }

    // 2. Uncommit and clear identity keys
    await storage.delete(key: kIdentityCommittedKey);
    await storage.delete(key: kDeviceIdKey);
    await storage.delete(key: kDeviceNameKey);
    await storage.delete(key: kIdentityPrivateKeyKey);
    _identity = null;

    // 3. Cleanly bootstrap fresh identity
    return initialize(storage: storage);
  }

  /// Computes the SHA-256 hex fingerprint of a public key.
  static Future<String> computeFingerprint(List<int> publicKeyBytes) async {
    final hash = await Sha256().hash(publicKeyBytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Sets an explicit identity instance (useful in tests).
  @visibleForTesting
  static void setIdentityForTesting(DeviceIdentity? identity) {
    _identity = identity;
  }

  /// Explicitly resets the local device identity and clears all paired trust records.
  /// Resets the cached identity state (useful in tests).
  @visibleForTesting
  static void resetForTesting() {
    _identity = null;
  }

  static String _generateDeviceName() {
    final suffix = Random().nextInt(9000) + 1000;
    return 'OneShare-$suffix';
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');

    final parts = bytes.map(hex).toList();
    return '${parts.sublist(0, 4).join()}-'
        '${parts.sublist(4, 6).join()}-'
        '${parts.sublist(6, 8).join()}-'
        '${parts.sublist(8, 10).join()}-'
        '${parts.sublist(10, 16).join()}';
  }

  static DeviceIdentity _createFallbackIdentity() {
    final seed = Uint8List.fromList(List<int>.filled(32, 0x01));
    const pubBytesList = <int>[
      138, 136, 227, 221, 116, 9, 241, 149, 253, 82, 219, 45, 60, 186, 93, 114,
      202, 103, 9, 191, 29, 148, 18, 27, 243, 116, 136, 1, 180, 15, 111, 92,
    ];
    final pubBytes = Uint8List.fromList(pubBytesList);
    final keyPair = SimpleKeyPairData(
      seed,
      publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    return DeviceIdentity(
      deviceId: _generateUuidV4(),
      deviceName: _generateDeviceName(),
      identityKeyPair: keyPair,
      identityPublicKeyBytes: pubBytes,
      fingerprint: '34750f98bd59fcfc946da45aaabe933be154a4b5094e1c4abf42866505f3c97e',
    );
  }
}
