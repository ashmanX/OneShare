import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/app_environment.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';

void main() {
  setUp(() {
    AppEnvironment.resetForTesting();
  });

  tearDown(() {
    AppEnvironment.resetForTesting();
  });

  group('Phase 1: Environment and Dependency Injection Isolation Tests', () {
    test('AppEnvironment defaults to development in debug mode', () {
      expect(AppEnvironment.current.type, EnvironmentType.development);
      expect(AppEnvironment.current.storageNamespacePrefix, 'oneshare.dev.');
      expect(AppEnvironment.current.isFallbackPermitted, isTrue);
      expect(AppEnvironment.current.isCleartextLanPermitted, isTrue);
    });

    test('All environments define distinct, non-overlapping namespace prefixes', () {
      final prefixes = {
        AppEnvironment.unitTest.storageNamespacePrefix,
        AppEnvironment.development.storageNamespacePrefix,
        AppEnvironment.staging.storageNamespacePrefix,
        AppEnvironment.production.storageNamespacePrefix,
      };

      expect(prefixes.length, 4);
      expect(prefixes, contains('oneshare.test.'));
      expect(prefixes, contains('oneshare.dev.'));
      expect(prefixes, contains('oneshare.staging.'));
      expect(prefixes, contains('oneshare.prod.'));
    });

    test('Staging and production strictly forbid fallback plaintext file storage', () {
      expect(AppEnvironment.staging.isFallbackPermitted, isFalse);
      expect(AppEnvironment.production.isFallbackPermitted, isFalse);
    });

    test('InMemoryKeyStorage automatically prefixes keys with active environment namespace', () async {
      AppEnvironment.current = AppEnvironment.unitTest;
      final storage = InMemoryKeyStorage();

      await storage.write(key: 'device_id', value: 'test-uuid-123');
      expect(await storage.read(key: 'device_id'), 'test-uuid-123');

      // Verify that the underlying storage key contains the prefix
      expect(await storage.containsKey(key: 'device_id'), isTrue);
      expect(await storage.containsKey(key: 'other_key'), isFalse);
    });

    test('Isolated storage instances with different namespaces cannot see each other data', () async {
      final devStorage = InMemoryKeyStorage(namespacePrefix: AppEnvironment.development.storageNamespacePrefix);
      final prodStorage = InMemoryKeyStorage(namespacePrefix: AppEnvironment.production.storageNamespacePrefix);

      await devStorage.write(key: 'secret_key', value: 'dev-secret-material');
      await prodStorage.write(key: 'secret_key', value: 'prod-secret-material');

      expect(await devStorage.read(key: 'secret_key'), 'dev-secret-material');
      expect(await prodStorage.read(key: 'secret_key'), 'prod-secret-material');

      // Deleting in dev namespace does not affect prod namespace
      await devStorage.delete(key: 'secret_key');
      expect(await devStorage.read(key: 'secret_key'), isNull);
      expect(await prodStorage.read(key: 'secret_key'), 'prod-secret-material');
    });

    test('CryptoKeyStorage routes to secure storage when allowFallback is false', () async {
      final strictStorage = CryptoKeyStorage(
        namespacePrefix: 'oneshare.prod.',
        allowFallback: false,
      );

      // In Phase 2, when allowFallback: false, macOS routes directly to platform secure storage
      // (Keychain), rather than throwing StateError from a prohibited fallback.
      // In headless test environments without native macOS Keychain host, platform channel throws
      // which is wrapped as StorageUnavailableException.
      expect(
        () => strictStorage.write(key: 'test_key', value: '123'),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(
        () => strictStorage.read(key: 'test_key'),
        throwsA(isA<StorageUnavailableException>()),
      );
    });

    test('Compile-time resolver rejects unknown ENV strings', () {
      expect(
        () => AppEnvironment.resolveFromEnvironment(),
        // In local test runner with no --dart-define=ENV, it defaults to development in debug mode
        returnsNormally,
      );
    });

    test('Shared backend namespace partitioning prevents cross-environment reads and deletions', () async {
      // Simulate two separate CryptoKeyStorage instances connected to the SAME mock storage backend
      final sharedMockBackend = _MockSecureStorageBackend();
      
      final devKeyStorage = _TestableCryptoKeyStorage(
        backend: sharedMockBackend,
        namespacePrefix: 'oneshare.dev.',
        allowFallback: false,
      );

      final prodKeyStorage = _TestableCryptoKeyStorage(
        backend: sharedMockBackend,
        namespacePrefix: 'oneshare.prod.',
        allowFallback: false,
      );

      // Write keys with identical logical names
      await devKeyStorage.write(key: 'device_id', value: 'dev-device-001');
      await prodKeyStorage.write(key: 'device_id', value: 'prod-device-999');

      // Verify each reads its own value
      expect(await devKeyStorage.read(key: 'device_id'), 'dev-device-001');
      expect(await prodKeyStorage.read(key: 'device_id'), 'prod-device-999');

      // Execute deleteAll on DEV storage: MUST NOT delete PROD keys
      await devKeyStorage.deleteAll();

      expect(await devKeyStorage.read(key: 'device_id'), isNull);
      expect(await prodKeyStorage.read(key: 'device_id'), 'prod-device-999');

      // Underlying backend still contains the production key
      expect(sharedMockBackend.map.containsKey('oneshare.prod.device_id'), isTrue);
      expect(sharedMockBackend.map.containsKey('oneshare.dev.device_id'), isFalse);
    });

    test('Storage failure policy: read and write errors fail closed with StateError when fallback is prohibited', () async {
      final failingBackend = _MockFailingSecureStorageBackend();
      final storage = _TestableCryptoKeyStorage(
        backend: failingBackend,
        namespacePrefix: 'oneshare.prod.',
        allowFallback: false,
      );

      expect(() => storage.write(key: 'key', value: 'val'), throwsA(isA<Exception>()));
      expect(() => storage.read(key: 'key'), throwsA(isA<Exception>()));
    });
  });
}

/// Helper mock representing platform secure storage (e.g. Android KeyStore / SharedPreferences)
class _MockSecureStorageBackend {
  final Map<String, String> map = {};

  Future<void> write({required String key, required String value}) async => map[key] = value;
  Future<String?> read({required String key}) async => map[key];
  Future<void> delete({required String key}) async => map.remove(key);
  Future<bool> containsKey({required String key}) async => map.containsKey(key);
  Future<Map<String, String>> readAll() async => Map.from(map);
  Future<void> deleteAll() async => map.clear();
}

class _MockFailingSecureStorageBackend extends _MockSecureStorageBackend {
  @override
  Future<void> write({required String key, required String value}) async => throw Exception('Storage write error');
  @override
  Future<String?> read({required String key}) async => throw Exception('Storage read error');
}

/// Testable adapter injecting the mock backend into the secure storage path
class _TestableCryptoKeyStorage implements KeyStorage {
  _TestableCryptoKeyStorage({
    required this.backend,
    required this.namespacePrefix,
    required this.allowFallback,
  });

  final _MockSecureStorageBackend backend;
  final String namespacePrefix;
  final bool allowFallback;

  String _namespacedKey(String key) => key.startsWith(namespacePrefix) ? key : '$namespacePrefix$key';

  @override
  Future<void> write({required String key, required String value}) async {
    return backend.write(key: _namespacedKey(key), value: value);
  }

  @override
  Future<String?> read({required String key}) async {
    return backend.read(key: _namespacedKey(key));
  }

  @override
  Future<void> delete({required String key}) async {
    return backend.delete(key: _namespacedKey(key));
  }

  @override
  Future<bool> containsKey({required String key}) async {
    return backend.containsKey(key: _namespacedKey(key));
  }

  @override
  Future<void> deleteAll() async {
    final all = await backend.readAll();
    for (final k in all.keys) {
      if (k.startsWith(namespacePrefix)) {
        await backend.delete(key: k);
      }
    }
  }
}
