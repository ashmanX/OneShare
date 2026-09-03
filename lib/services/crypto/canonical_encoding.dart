import 'dart:convert';
import 'dart:typed_data';

/// Centralized canonical length-prefixed byte serialization for signatures,
/// transcripts, manifests, and MAC inputs.
///
/// Ensures deterministic, unambiguous encoding across all platforms and
/// prevents delimiter collision attacks.
class CanonicalEncoding {
  CanonicalEncoding._();

  /// Concatenates multiple byte collections into a single [Uint8List].
  static Uint8List concat(List<List<int>> byteLists) {
    int totalLength = 0;
    for (final list in byteLists) {
      totalLength += list.length;
    }
    final result = Uint8List(totalLength);
    int offset = 0;
    for (final list in byteLists) {
      result.setRange(offset, offset + list.length, list);
      offset += list.length;
    }
    return result;
  }

  /// Encodes raw bytes with a 4-byte big-endian length prefix:
  /// `[BigEndian_uint32(b.length)] + b`.
  static Uint8List encodeBytes(List<int> bytes) {
    final bdata = ByteData(4);
    bdata.setUint32(0, bytes.length, Endian.big);
    final prefix = bdata.buffer.asUint8List();
    final result = Uint8List(4 + bytes.length);
    result.setRange(0, 4, prefix);
    result.setRange(4, 4 + bytes.length, bytes);
    return result;
  }

  /// Encodes a UTF-8 string with a 4-byte big-endian byte-length prefix:
  /// `encode_bytes(utf8.encode(s))`.
  static Uint8List encodeString(String s) {
    return encodeBytes(utf8.encode(s));
  }

  /// Encodes an unsigned 64-bit integer as 8 big-endian bytes.
  static Uint8List encodeUint64(int value) {
    final bdata = ByteData(8);
    bdata.setUint64(0, value, Endian.big);
    return bdata.buffer.asUint8List();
  }

  /// Encodes an unsigned 32-bit integer as 4 big-endian bytes.
  static Uint8List encodeUint32(int value) {
    final bdata = ByteData(4);
    bdata.setUint32(0, value, Endian.big);
    return bdata.buffer.asUint8List();
  }

  /// Encodes an unsigned 16-bit integer as 2 big-endian bytes.
  static Uint8List encodeUint16(int value) {
    final bdata = ByteData(2);
    bdata.setUint16(0, value, Endian.big);
    return bdata.buffer.asUint8List();
  }

  /// Encodes a single byte as a 1-byte [Uint8List].
  static Uint8List encodeByte(int value) {
    return Uint8List.fromList([value & 0xFF]);
  }

  /// Decodes length-prefixed bytes from [data] starting at [offset].
  ///
  /// Returns a record of `(bytes, nextOffset)`.
  static (Uint8List bytes, int nextOffset) decodeBytes(
    Uint8List data,
    int offset,
  ) {
    if (offset + 4 > data.length) {
      throw const FormatException('Unexpected EOF reading byte prefix length');
    }
    final bdata = ByteData.sublistView(data, offset, offset + 4);
    final length = bdata.getUint32(0, Endian.big);
    final start = offset + 4;
    final end = start + length;
    if (end > data.length) {
      throw FormatException(
        'Unexpected EOF: declared length $length exceeds data length ${data.length}',
      );
    }
    return (Uint8List.fromList(data.sublist(start, end)), end);
  }

  /// Decodes a length-prefixed UTF-8 string from [data] starting at [offset].
  ///
  /// Returns a record of `(string, nextOffset)`.
  static (String value, int nextOffset) decodeString(
    Uint8List data,
    int offset,
  ) {
    final (bytes, nextOffset) = decodeBytes(data, offset);
    return (utf8.decode(bytes), nextOffset);
  }

  /// Decodes an unsigned 64-bit integer from [data] starting at [offset].
  ///
  /// Returns a record of `(value, nextOffset)`.
  static (int value, int nextOffset) decodeUint64(
    Uint8List data,
    int offset,
  ) {
    if (offset + 8 > data.length) {
      throw const FormatException('Unexpected EOF reading uint64');
    }
    final bdata = ByteData.sublistView(data, offset, offset + 8);
    return (bdata.getUint64(0, Endian.big), offset + 8);
  }

  /// Decodes an unsigned 32-bit integer from [data] starting at [offset].
  ///
  /// Returns a record of `(value, nextOffset)`.
  static (int value, int nextOffset) decodeUint32(
    Uint8List data,
    int offset,
  ) {
    if (offset + 4 > data.length) {
      throw const FormatException('Unexpected EOF reading uint32');
    }
    final bdata = ByteData.sublistView(data, offset, offset + 4);
    return (bdata.getUint32(0, Endian.big), offset + 4);
  }

  /// Decodes an unsigned 16-bit integer from [data] starting at [offset].
  ///
  /// Returns a record of `(value, nextOffset)`.
  static (int value, int nextOffset) decodeUint16(
    Uint8List data,
    int offset,
  ) {
    if (offset + 2 > data.length) {
      throw const FormatException('Unexpected EOF reading uint16');
    }
    final bdata = ByteData.sublistView(data, offset, offset + 2);
    return (bdata.getUint16(0, Endian.big), offset + 2);
  }

  /// Decodes a single byte from [data] starting at [offset].
  ///
  /// Returns a record of `(byte, nextOffset)`.
  static (int value, int nextOffset) decodeByte(
    Uint8List data,
    int offset,
  ) {
    if (offset + 1 > data.length) {
      throw const FormatException('Unexpected EOF reading byte');
    }
    return (data[offset], offset + 1);
  }

  /// Serializes a JSON-compatible object into canonical JSON:
  /// - Keys sorted lexicographically at every object level
  /// - No extra whitespace between keys and values
  /// - Deterministic encoding
  static String canonicalJson(dynamic object) {
    if (object == null) return 'null';
    if (object is num || object is bool) return object.toString();
    if (object is String) return jsonEncode(object);
    if (object is List) {
      final items = object.map(canonicalJson).join(',');
      return '[$items]';
    }
    if (object is Map) {
      final sortedKeys = object.keys.map((k) => k.toString()).toList()..sort();
      final entries = sortedKeys.map((k) {
        final val = canonicalJson(object[k]);
        return '${jsonEncode(k)}:$val';
      }).join(',');
      return '{$entries}';
    }
    throw ArgumentError('Unsupported object type for canonical JSON: ${object.runtimeType}');
  }
}
