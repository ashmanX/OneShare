import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';

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

  static DeviceIdentity? _identity;

  /// Whether the persistent identity has been initialized from storage.
  static bool get isInitialized => _identity != null;

  /// Synchronous access to device identity.
  ///
  /// Returns the initialized identity, or lazily generates an in-memory
  /// fallback identity if accessed before [initialize] has been called.
  static DeviceIdentity get identity {
    return _identity ??= _createFallbackIdentity();
  }

  /// Initializes the device identity from [storage].
  ///
  /// If an identity already exists in [storage], it is loaded and restored.
  /// Otherwise, a new UUID, device name, and Ed25519 keypair are generated
  /// and persisted.
  static Future<DeviceIdentity> initialize({KeyStorage? storage}) async {
    final store = storage ?? CryptoKeyStorage();

    final storedDeviceId = await store.read(key: kDeviceIdKey);
    final storedDeviceName = await store.read(key: kDeviceNameKey);
    final storedPrivKeyB64 = await store.read(key: kIdentityPrivateKeyKey);

    if (storedDeviceId != null &&
        storedDeviceId.isNotEmpty &&
        storedDeviceName != null &&
        storedDeviceName.isNotEmpty &&
        storedPrivKeyB64 != null &&
        storedPrivKeyB64.isNotEmpty) {
      try {
        final privBytes = base64Decode(storedPrivKeyB64);
        if (privBytes.length == 32) {
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
        }
      } catch (e) {
        debugPrint('[DeviceIdentityService] Failed to load stored identity: $e. Re-generating.');
      }
    }

    // Generate new identity
    final newDeviceId = _generateUuidV4();
    final newDeviceName = _generateDeviceName();

    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPair();
    final privBytes = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final pubKey = await keyPair.extractPublicKey();
    final pubBytes = Uint8List.fromList(pubKey.bytes);
    final fingerprint = await computeFingerprint(pubBytes);

    await store.write(key: kDeviceIdKey, value: newDeviceId);
    await store.write(key: kDeviceNameKey, value: newDeviceName);
    await store.write(key: kIdentityPrivateKeyKey, value: base64Encode(privBytes));

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
