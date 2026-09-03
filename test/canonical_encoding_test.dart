import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/canonical_encoding.dart';

void main() {
  group('CanonicalEncoding', () {
    test('encodeBytes and decodeBytes roundtrip', () {
      final raw = Uint8List.fromList([1, 2, 3, 4, 255, 0, 128]);
      final encoded = CanonicalEncoding.encodeBytes(raw);
      expect(encoded.length, raw.length + 4);

      // Check big-endian length prefix
      expect(encoded[0], 0);
      expect(encoded[1], 0);
      expect(encoded[2], 0);
      expect(encoded[3], raw.length);

      final (decoded, nextOffset) = CanonicalEncoding.decodeBytes(encoded, 0);
      expect(decoded, raw);
      expect(nextOffset, encoded.length);
    });

    test('encodeString and decodeString roundtrip', () {
      const testStr = 'OneShare-E2EE-v2-🔐-Test';
      final encoded = CanonicalEncoding.encodeString(testStr);

      final (decoded, nextOffset) = CanonicalEncoding.decodeString(encoded, 0);
      expect(decoded, testStr);
      expect(nextOffset, encoded.length);
    });

    test('encodeUint64 and decodeUint64 roundtrip', () {
      const value = 0x123456789ABCDEF0;
      final encoded = CanonicalEncoding.encodeUint64(value);
      expect(encoded.length, 8);

      final (decoded, nextOffset) = CanonicalEncoding.decodeUint64(encoded, 0);
      expect(decoded, value);
      expect(nextOffset, 8);
    });

    test('encodeUint32 and decodeUint32 roundtrip', () {
      const value = 0xAABBCCDD;
      final encoded = CanonicalEncoding.encodeUint32(value);
      expect(encoded.length, 4);

      final (decoded, nextOffset) = CanonicalEncoding.decodeUint32(encoded, 0);
      expect(decoded, value);
      expect(nextOffset, 4);
    });

    test('encodeUint16 and decodeUint16 roundtrip', () {
      const value = 0xFEDC;
      final encoded = CanonicalEncoding.encodeUint16(value);
      expect(encoded.length, 2);

      final (decoded, nextOffset) = CanonicalEncoding.decodeUint16(encoded, 0);
      expect(decoded, value);
      expect(nextOffset, 2);
    });

    test('encodeByte and decodeByte roundtrip', () {
      const value = 0x42;
      final encoded = CanonicalEncoding.encodeByte(value);
      expect(encoded.length, 1);

      final (decoded, nextOffset) = CanonicalEncoding.decodeByte(encoded, 0);
      expect(decoded, value);
      expect(nextOffset, 1);
    });

    test('concat combines multiple chunks sequentially and accurately', () {
      final c1 = Uint8List.fromList([1, 2]);
      final c2 = Uint8List.fromList([3, 4, 5]);
      final c3 = Uint8List.fromList([]);
      final c4 = Uint8List.fromList([6]);

      final combined = CanonicalEncoding.concat([c1, c2, c3, c4]);
      expect(combined, [1, 2, 3, 4, 5, 6]);
    });

    test('sequential decoding of composite structure', () {
      final payload = CanonicalEncoding.concat([
        CanonicalEncoding.encodeString('header'),
        CanonicalEncoding.encodeUint32(42),
        CanonicalEncoding.encodeBytes(Uint8List.fromList([0xAA, 0xBB])),
        CanonicalEncoding.encodeByte(0x01),
      ]);

      int offset = 0;
      final (s, o1) = CanonicalEncoding.decodeString(payload, offset);
      expect(s, 'header');

      final (u32, o2) = CanonicalEncoding.decodeUint32(payload, o1);
      expect(u32, 42);

      final (bytes, o3) = CanonicalEncoding.decodeBytes(payload, o2);
      expect(bytes, [0xAA, 0xBB]);

      final (b, o4) = CanonicalEncoding.decodeByte(payload, o3);
      expect(b, 0x01);
      expect(o4, payload.length);
    });

    test('decoding truncated data throws FormatException', () {
      final truncated = Uint8List.fromList([0, 0, 0, 10, 1, 2, 3]); // Declared 10, only 3 present
      expect(() => CanonicalEncoding.decodeBytes(truncated, 0), throwsFormatException);
    });
  });
}
