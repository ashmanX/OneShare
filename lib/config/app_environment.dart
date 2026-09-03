import 'package:flutter/foundation.dart';

/// The active execution environment for OneShare.
enum EnvironmentType {
  /// Fast deterministic in-memory testing.
  unitTest,

  /// Fast local development and debugging over LAN.
  development,

  /// Release-like testing on Android/macOS before production release.
  staging,

  /// Store-ready distribution (Google Play / macOS App Store).
  production,
}

/// Central configuration class defining environment boundaries, storage
/// namespaces, cleartext policies, and fallback permissions.
class AppEnvironment {
  const AppEnvironment._({
    required this.type,
    required this.storageNamespacePrefix,
    required this.isFallbackPermitted,
    required this.isCleartextLanPermitted,
    required this.isVerboseLoggingEnabled,
  });

  final EnvironmentType type;

  /// The immutable namespace prefix prepended to all secure storage keys,
  /// trust-store peer records, and trust index files.
  final String storageNamespacePrefix;

  /// Whether development fallback storage (e.g. unencrypted file on macOS)
  /// is permitted. Strictly `false` in staging and production.
  final bool isFallbackPermitted;

  /// Whether unauthenticated HTTP on the LAN is permitted for transport.
  final bool isCleartextLanPermitted;

  /// Whether verbose diagnostic logging is enabled.
  final bool isVerboseLoggingEnabled;

  /// Unit test configuration: in-memory, fully isolated.
  static const AppEnvironment unitTest = AppEnvironment._(
    type: EnvironmentType.unitTest,
    storageNamespacePrefix: 'oneshare.test.',
    isFallbackPermitted: false,
    isCleartextLanPermitted: false,
    isVerboseLoggingEnabled: false,
  );

  /// Development configuration: isolated dev namespace, LAN HTTP allowed.
  static const AppEnvironment development = AppEnvironment._(
    type: EnvironmentType.development,
    storageNamespacePrefix: 'oneshare.dev.',
    isFallbackPermitted: true,
    isCleartextLanPermitted: true,
    isVerboseLoggingEnabled: true,
  );

  /// Staging configuration: staging namespace, no fallback storage.
  static const AppEnvironment staging = AppEnvironment._(
    type: EnvironmentType.staging,
    storageNamespacePrefix: 'oneshare.staging.',
    isFallbackPermitted: false,
    isCleartextLanPermitted: true,
    isVerboseLoggingEnabled: false,
  );

  /// Production configuration: production namespace, no fallback, strict storage.
  static const AppEnvironment production = AppEnvironment._(
    type: EnvironmentType.production,
    storageNamespacePrefix: 'oneshare.prod.',
    isFallbackPermitted: false,
    isCleartextLanPermitted: true, // Controlled in Phase 8 store prep
    isVerboseLoggingEnabled: false,
  );

  static AppEnvironment? _current;

  /// The active environment instance. Defaults to [development] in debug builds
  /// if not explicitly resolved.
  static AppEnvironment get current {
    if (_current == null) {
      if (kDebugMode) {
        _current = development;
      } else {
        throw StateError(
          '[AppEnvironment] Environment is uninitialized. In profile/release builds, '
          'an explicit compile-time flag (--dart-define=ENV=staging or '
          '--dart-define=ENV=production) is required.',
        );
      }
    }
    return _current!;
  }

  /// Explicitly sets the current environment (e.g. in tests or at startup).
  @visibleForTesting
  static set current(AppEnvironment env) {
    _current = env;
  }

  /// Resolves the environment from compile-time flags:
  /// `--dart-define=ENV=development`
  /// `--dart-define=ENV=staging`
  /// `--dart-define=ENV=production`
  ///
  /// In debug mode, if `ENV` is omitted, defaults to [development].
  /// In release or profile mode, an explicit matching `ENV` flag is required;
  /// missing or invalid flags throw [StateError] (fail-closed).
  static AppEnvironment resolveFromEnvironment() {
    const envString = String.fromEnvironment('ENV');

    if (envString.isEmpty) {
      if (kDebugMode) {
        _current = development;
        return development;
      }
      throw StateError(
        '[AppEnvironment] Missing compile-time --dart-define=ENV flag in non-debug build. '
        'Must specify ENV=staging or ENV=production.',
      );
    }

    switch (envString.toLowerCase().trim()) {
      case 'development':
      case 'dev':
        if (kReleaseMode) {
          throw StateError(
            '[AppEnvironment] Invalid configuration: ENV=development is prohibited in release builds.',
          );
        }
        _current = development;
        return development;

      case 'staging':
        _current = staging;
        return staging;

      case 'production':
      case 'prod':
        _current = production;
        return production;

      default:
        throw StateError(
          '[AppEnvironment] Unknown ENV value: "$envString". '
          'Allowed values are: development, staging, production.',
        );
    }
  }

  /// Resets the current environment state (used for testing).
  @visibleForTesting
  static void resetForTesting() {
    _current = null;
  }
}
