import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Abstract contract for secure key and identity persistence.
abstract class KeyStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
  Future<bool> containsKey({required String key});
  Future<void> deleteAll();
}

/// Production implementation of [KeyStorage].
///
/// On Android and iOS, hardware-backed keystore/secure-storage is utilized.
/// On macOS desktop (where ad-hoc developer builds trigger interactive OS Keychain
/// password prompts), keys are stored in an isolated, sandboxed application support file.
class CryptoKeyStorage implements KeyStorage {
  CryptoKeyStorage({FlutterSecureStorage? storage})
      : _secureStorage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _secureStorage;
  File? _macStorageFile;
  Map<String, String>? _macCache;

  bool get _isMacDesktop => !kIsWeb && Platform.isMacOS;

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
    if (_isMacDesktop) {
      final map = await _loadMacMap();
      map[key] = value;
      await _saveMacMap(map);
      return;
    }
    return _secureStorage.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) async {
    if (_isMacDesktop) {
      final map = await _loadMacMap();
      return map[key];
    }
    return _secureStorage.read(key: key);
  }

  @override
  Future<void> delete({required String key}) async {
    if (_isMacDesktop) {
      final map = await _loadMacMap();
      map.remove(key);
      await _saveMacMap(map);
      return;
    }
    return _secureStorage.delete(key: key);
  }

  @override
  Future<bool> containsKey({required String key}) async {
    if (_isMacDesktop) {
      final map = await _loadMacMap();
      return map.containsKey(key);
    }
    return _secureStorage.containsKey(key: key);
  }

  @override
  Future<void> deleteAll() async {
    if (_isMacDesktop) {
      final map = await _loadMacMap();
      map.clear();
      await _saveMacMap(map);
      return;
    }
    return _secureStorage.deleteAll();
  }
}

/// In-memory implementation of [KeyStorage] for unit testing and mock environments.
class InMemoryKeyStorage implements KeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    return _store[key];
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }

  @override
  Future<bool> containsKey({required String key}) async {
    return _store.containsKey(key);
  }

  @override
  Future<void> deleteAll() async {
    _store.clear();
  }
}
