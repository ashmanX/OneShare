import 'dart:io';

/// Centralized sanitizer for logs, diagnostic traces, and exception messages.
///
/// Ensures cryptographic keys, seeds, signatures, session tokens, authorization
/// headers, and absolute filesystem paths never leak into device console logs
/// or diagnostic outputs.
class LogSanitizer {
  LogSanitizer._();

  static final RegExp _bearerRegex = RegExp(
    r'(Bearer\s+)[A-Za-z0-9_\-\.]+',
    caseSensitive: false,
  );

  static final RegExp _tokenRegex = RegExp(
    r'(tok_sec_[0-9a-fA-F]+)',
  );

  static final RegExp _genericTokenParamRegex = RegExp(
    r'''((?:transferToken|tokenHash|token)\s*[:=]\s*)[^\s,}"']+''',
    caseSensitive: false,
  );

  static final RegExp _keyOrSigRegex = RegExp(
    r'''((?:senderIdentityPubKey|receiverIdentityPubKey|senderEphemeralPubKey|receiverEphemeralPubKey|senderEphemeralSig|receiverEphemeralSig|manifestHash|mac)\s*[:=]\s*)[^\s,}"']+''',
    caseSensitive: false,
  );

  /// Sensitive key names in JSON structures that must be sanitized.
  static const Set<String> _sensitiveKeys = {
    'transferToken',
    'tokenHash',
    'seed',
    'privateKey',
    'secretKey',
    'sessionMasterKey',
    'senderFileBaseKey',
    'receiverFileBaseKey',
    'senderCtrlKey',
    'receiverCtrlKey',
    'senderEphemeralSig',
    'receiverEphemeralSig',
    'senderIdentityPubKey',
    'receiverIdentityPubKey',
    'senderEphemeralPubKey',
    'receiverEphemeralPubKey',
    'mac',
    'e2ee_ctrl',
  };

  /// Truncates an ID (e.g. transferId or deviceId) to 8 characters with ellipsis.
  static String truncateId(String? id) {
    if (id == null || id.isEmpty) return '<empty>';
    if (id.length <= 8) return id;
    return '${id.substring(0, 8)}...';
  }

  /// Redacts sensitive patterns (Bearer tokens, secret tokens, keys, signatures) from raw log strings.
  static String redact(String message) {
    if (message.isEmpty) return message;
    var sanitized = message;
    sanitized = sanitized.replaceAllMapped(_bearerRegex, (m) => '${m.group(1)}[REDACTED]');
    sanitized = sanitized.replaceAll(_tokenRegex, '[REDACTED_TOKEN]');
    sanitized = sanitized.replaceAllMapped(_genericTokenParamRegex, (m) => '${m.group(1)}[REDACTED]');
    sanitized = sanitized.replaceAllMapped(_keyOrSigRegex, (m) => '${m.group(1)}[REDACTED]');
    return sanitized;
  }

  /// Sanitizes filesystem paths by reducing them to either `<destination_path>` or filename.
  static String sanitizePath(String path) {
    if (path.isEmpty) return path;
    final sep = Platform.isWindows ? r'\' : '/';
    final parts = path.split(sep);
    if (parts.length > 1) {
      return '<path>/${parts.last}';
    }
    return path;
  }

  /// Recursively sanitizes a JSON-compatible map or list, replacing sensitive
  /// keys or entries with `'[REDACTED]'`.
  static dynamic sanitizeJson(dynamic json) {
    if (json is Map) {
      final sanitized = <String, dynamic>{};
      for (final entry in json.entries) {
        final key = entry.key.toString();
        if (_sensitiveKeys.contains(key)) {
          sanitized[key] = '[REDACTED]';
        } else if (key == 'e2ee' && entry.value is Map) {
          sanitized[key] = sanitizeJson(entry.value);
        } else {
          sanitized[key] = sanitizeJson(entry.value);
        }
      }
      return sanitized;
    } else if (json is List) {
      return json.map((item) => sanitizeJson(item)).toList();
    }
    return json;
  }
}
