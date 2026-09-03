import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'package:oneshare/config/app_environment.dart';

/// Abstract contract for secure key and identity persistence.
abstract class KeyStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
  Future<bool> containsKey({required String key});
  Future<void> deleteAll();
}

class StorageUnavailableException implements Exception {
  StorageUnavailableException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'StorageUnavailableException: $message${cause != null ? ' (Cause: $cause)' : ''}';
}

class LegacyMigrationException implements Exception {
  LegacyMigrationException(this.message, [this.cause]);
  final String message;
  final dynamic cause;

  @override
  String toString() => 'LegacyMigrationException: $message${cause != null ? ' (Cause: $cause)' : ''}';
}

/// Production implementation of [KeyStorage].
///
/// On Android and iOS, hardware-backed keystore/secure-storage is utilized.
/// Production implementation of [KeyStorage].
///
/// On Android and iOS, hardware-backed keystore/secure-storage is utilized.
/// On macOS desktop, macOS Keychain via `flutter_secure_storage` is utilized when
/// `allowFallback` is false (in staging and production).
/// When `allowFallback` is true (in local development), keys may fall back to an isolated application support file.
class CryptoKeyStorage implements KeyStorage {
  CryptoKeyStorage({
    FlutterSecureStorage? storage,
    String? namespacePrefix,
    bool? allowFallback,
  })  : _secureStorage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
              mOptions: MacOsOptions(accessibility: KeychainAccessibility.unlocked),
            ),
        _namespacePrefix = namespacePrefix ?? AppEnvironment.current.storageNamespacePrefix,
        _allowFallback = allowFallback ?? AppEnvironment.current.isFallbackPermitted;

  final FlutterSecureStorage _secureStorage;
  final String _namespacePrefix;
  final bool _allowFallback;
  File? _macStorageFile;
  Map<String, String>? _macCache;
  bool _migrationAttempted = false;

  String _namespacedKey(String key) => key.startsWith(_namespacePrefix) ? key : '$_namespacePrefix$key';

  bool get _isMacDesktop => !kIsWeb && Platform.isMacOS;

  /// Whether to use the plaintext application support file on macOS.
  /// Only active on macOS when fallback is explicitly permitted (development).
  bool get _shouldUseMacFileFallback => _isMacDesktop && _allowFallback;

  /// Checks for and migrates legacy unencrypted file data into the active namespace in Keychain.
  ///
  /// Can be tested with [legacyFileOverride] pointing to a custom file.
  Future<void> migrateLegacyFileIfNeeded({File? legacyFileOverride}) async {
    if (_migrationAttempted) return;
    _migrationAttempted = true;

    final File legacyFile;
    if (legacyFileOverride != null) {
      legacyFile = legacyFileOverride;
    } else {
      if (!_isMacDesktop) return;
      final appSupport = await getApplicationSupportDirectory();
      legacyFile = File('${appSupport.path}/.oneshare_secure_keys.json');
    }

    if (!await legacyFile.exists()) return;

    final content = await legacyFile.readAsString();
    if (content.trim().isEmpty || content.trim() == '{}') return;

    Future<File> getQuarantineFile(File original) async {
      var target = File('${original.path}.corrupted');
      var counter = 1;
      while (await target.exists()) {
        target = File('${original.path}.corrupted.$counter');
        counter++;
      }
      return target;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      try {
        final qFile = await getQuarantineFile(legacyFile);
        await legacyFile.rename(qFile.path);
      } catch (_) {}
      throw LegacyMigrationException('Malformed legacy storage JSON file', e);
    }

    if (decoded is! Map) {
      try {
        final qFile = await getQuarantineFile(legacyFile);
        await legacyFile.rename(qFile.path);
      } catch (_) {}
      throw LegacyMigrationException('Legacy storage JSON root is not a Map');
    }

    final map = Map<String, dynamic>.from(decoded);
    final privKeyB64 = map['oneshare_identity_priv_key_b64'] as String?;

    // Validate seed integrity if present
    Uint8List? seedBytes;
    if (privKeyB64 != null && privKeyB64.isNotEmpty) {
      try {
        final privBytes = base64Decode(privKeyB64);
        if (privBytes.length != 32) {
          final qFile = await getQuarantineFile(legacyFile);
          try {
            await legacyFile.rename(qFile.path);
          } catch (_) {}
          throw LegacyMigrationException('Invalid private seed length: ${privBytes.length} bytes');
        }
        seedBytes = privBytes;
      } catch (e) {
        final qFile = await getQuarantineFile(legacyFile);
        try {
          await legacyFile.rename(qFile.path);
        } catch (_) {}
        if (e is LegacyMigrationException) rethrow;
        throw LegacyMigrationException('Corrupted legacy identity seed', e);
      }
    }

    // Per-attempt migration tracking for rollback on error
    final migratedKeysInAttempt = <String>[];

    try {
      // Migrate all entries directly to Keychain-backed secure storage under active namespace
      for (final entry in map.entries) {
        final key = entry.key;
        final val = entry.value;
        final namespaced = _namespacedKey(key);

        if (val is String) {
          await _secureStorage.write(key: namespaced, value: val);
          migratedKeysInAttempt.add(namespaced);
        } else if (val != null) {
          await _secureStorage.write(key: namespaced, value: jsonEncode(val));
          migratedKeysInAttempt.add(namespaced);
        }
      }

      // Add identity committed marker for transactional integrity
      if (seedBytes != null) {
        final committedKey = _namespacedKey('oneshare_identity_committed');
        await _secureStorage.write(key: committedKey, value: 'true');
        migratedKeysInAttempt.add(committedKey);

        // Verification: read back seed from secure storage and ensure derivation matches
        final readBackPrivKeyB64 = await _secureStorage.read(
          key: _namespacedKey('oneshare_identity_priv_key_b64'),
        );
        if (readBackPrivKeyB64 == null || readBackPrivKeyB64 != privKeyB64) {
          throw LegacyMigrationException('Migration read-back verification failed for private key seed');
        }
      }

      // Only delete legacy file after complete and verified migration
      try {
        await legacyFile.delete();
      } catch (e) {
        debugPrint('[CryptoKeyStorage] Warning: Failed to delete legacy storage file: $e');
      }
    } catch (e) {
      // Rollback only the keys written during this attempt (never deleteAll)
      for (final keyToRollback in migratedKeysInAttempt) {
        try {
          await _secureStorage.delete(key: keyToRollback);
        } catch (_) {}
      }
      if (e is LegacyMigrationException) rethrow;
      throw LegacyMigrationException('Migration write attempt failed and was rolled back', e);
    }
  }

  Future<File> _getMacStorageFile() async {
    if (_macStorageFile != null) return _macStorageFile!;
    final appSupport = await getApplicationSupportDirectory();
    final file = File('${appSupport.path}/.oneshare_secure_keys.json');
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode({}));
    }
    _macStorageFile = file;
    return file;
  }

  Future<Map<String, String>> _loadMacMap() async {
    if (_macCache != null) return _macCache!;
    try {
      final file = await _getMacStorageFile();
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        _macCache = Map<String, String>.from(decoded);
        return _macCache!;
      }
    } catch (_) {}
    _macCache = {};
    return _macCache!;
  }

  Future<void> _saveMacMap(Map<String, String> map) async {
    final file = await _getMacStorageFile();
    await file.writeAsString(jsonEncode(map));
  }

  @override
  Future<void> write({required String key, required String value}) async {
    final namespacedKey = _namespacedKey(key);
    if (_shouldUseMacFileFallback) {
      final map = await _loadMacMap();
      map[namespacedKey] = value;
      await _saveMacMap(map);
      return;
    }
    try {
      return await _secureStorage.write(key: namespacedKey, value: value);
    } catch (e) {
      throw StorageUnavailableException('Failed to write key to secure storage', e);
    }
  }

  @override
  Future<String?> read({required String key}) async {
    final namespacedKey = _namespacedKey(key);
    if (_shouldUseMacFileFallback) {
      final map = await _loadMacMap();
      return map[namespacedKey];
    }
    try {
      return await _secureStorage.read(key: namespacedKey);
    } catch (e) {
      throw StorageUnavailableException('Failed to read key from secure storage', e);
    }
  }

  @override
  Future<void> delete({required String key}) async {
    final namespacedKey = _namespacedKey(key);
    if (_shouldUseMacFileFallback) {
      final map = await _loadMacMap();
      map.remove(namespacedKey);
      await _saveMacMap(map);
      return;
    }
    try {
      return await _secureStorage.delete(key: namespacedKey);
    } catch (e) {
      throw StorageUnavailableException('Failed to delete key from secure storage', e);
    }
  }

  @override
  Future<bool> containsKey({required String key}) async {
    final namespacedKey = _namespacedKey(key);
    if (_shouldUseMacFileFallback) {
      final map = await _loadMacMap();
      return map.containsKey(namespacedKey);
    }
    try {
      return await _secureStorage.containsKey(key: namespacedKey);
    } catch (e) {
      throw StorageUnavailableException('Failed to check key existence in secure storage', e);
    }
  }

  @override
  Future<void> deleteAll() async {
    if (_shouldUseMacFileFallback) {
      final map = await _loadMacMap();
      map.removeWhere((k, _) => k.startsWith(_namespacePrefix));
      await _saveMacMap(map);
      return;
    }
    // Namespace isolation: Only delete keys matching this environment's namespace.
    // Never call _secureStorage.deleteAll() directly, as it would destroy keys from other environments.
    try {
      final allEntries = await _secureStorage.readAll();
      for (final key in allEntries.keys) {
        if (key.startsWith(_namespacePrefix)) {
          await _secureStorage.delete(key: key);
        }
      }
    } catch (e) {
      throw StorageUnavailableException('Failed to delete environment keys from secure storage', e);
    }
  }
}

/// In-memory implementation of [KeyStorage] for unit testing and mock environments.
class InMemoryKeyStorage implements KeyStorage {
  InMemoryKeyStorage({String? namespacePrefix})
      : _namespacePrefix = namespacePrefix ?? AppEnvironment.unitTest.storageNamespacePrefix;

  final String _namespacePrefix;
  final Map<String, String> _store = {};

  String _namespacedKey(String key) => key.startsWith(_namespacePrefix) ? key : '$_namespacePrefix$key';

  @override
  Future<void> write({required String key, required String value}) async {
    _store[_namespacedKey(key)] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    return _store[_namespacedKey(key)];
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(_namespacedKey(key));
  }

  @override
  Future<bool> containsKey({required String key}) async {
    return _store.containsKey(_namespacedKey(key));
  }

  @override
  Future<void> deleteAll() async {
    _store.removeWhere((k, _) => k.startsWith(_namespacePrefix));
  }
}
