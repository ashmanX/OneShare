import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/encrypted_stream.dart';

void main() {
  late SecretKey fileKey;
  const transferId = 'transfer-stream-test-100';
  const fileId = 'file-abc-001';

  setUp(() async {
    final algo = Chacha20.poly1305Aead();
    fileKey = await algo.newSecretKey();
  });

  group('EncryptedStreamWriter & EncryptedStreamReader', () {
    test('roundtrip streaming for 0-byte file (sentinel only)', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final sentinelFrame = await writer.writeSentinel();
      final stream = Stream<List<int>>.fromIterable([sentinelFrame]);

      final decryptedChunks = await reader.processStream(stream).toList();
      expect(decryptedChunks, isEmpty);
      expect(reader.accumulatedBytes, 0);
      expect(reader.state, ReaderState.done);
    });

    test('roundtrip streaming for small file (under 64KB)', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final originalData = utf8.encode('Hello, OneShare Encrypted Streaming World!');
      final chunkFrame = await writer.encryptChunk(originalData);
      final sentinelFrame = await writer.writeSentinel();

      // Emit in fragments to test buffer reassembly
      final stream = Stream<List<int>>.fromIterable([
        chunkFrame.sublist(0, 10),
        chunkFrame.sublist(10, 30),
        chunkFrame.sublist(30),
        sentinelFrame,
      ]);

      final decryptedChunks = await reader.processStream(stream).toList();
      final fullPlaintext = decryptedChunks.expand((c) => c).toList();

      expect(utf8.decode(fullPlaintext), 'Hello, OneShare Encrypted Streaming World!');
      expect(reader.accumulatedBytes, originalData.length);
      expect(reader.state, ReaderState.done);
    });

    test('roundtrip streaming for multi-chunk file (>200KB)', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final rng = Random(42);
      final totalBytes = 200 * 1024; // 200 KB -> 4 chunks (64KB, 64KB, 64KB, 8KB)
      final originalData = Uint8List.fromList(List.generate(totalBytes, (_) => rng.nextInt(256)));

      final controller = StreamController<List<int>>();

      Future<void> sendData() async {
        int offset = 0;
        while (offset < totalBytes) {
          final end = min(offset + 64 * 1024, totalBytes);
          final chunk = originalData.sublist(offset, end);
          final frame = await writer.encryptChunk(chunk);
          controller.add(frame);
          offset = end;
        }
        final sentinel = await writer.writeSentinel();
        controller.add(sentinel);
        await controller.close();
      }

      unawaited(sendData());

      final decryptedChunks = await reader.processStream(controller.stream).toList();
      final reconstructed = Uint8List.fromList(decryptedChunks.expand((c) => c).toList());

      expect(reconstructed.length, totalBytes);
      expect(reconstructed, originalData);
      expect(reader.accumulatedBytes, totalBytes);
      expect(reader.state, ReaderState.done);
    });

    test('roundtrip using writer.encryptStream pipeline', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final rng = Random(123);
      final totalBytes = 150 * 1024;
      final originalData = Uint8List.fromList(List.generate(totalBytes, (_) => rng.nextInt(256)));

      // Plaintext stream with arbitrary chunk sizes
      final plaintextChunks = [
        originalData.sublist(0, 1000),
        originalData.sublist(1000, 70000),
        originalData.sublist(70000),
      ];
      final plainStream = Stream<List<int>>.fromIterable(plaintextChunks);

      final encryptedStream = writer.encryptStream(plainStream);
      final decryptedChunks = await reader.processStream(encryptedStream).toList();
      final reconstructed = Uint8List.fromList(decryptedChunks.expand((c) => c).toList());

      expect(reconstructed.length, totalBytes);
      expect(reconstructed, originalData);
      expect(reader.accumulatedBytes, totalBytes);
      expect(reader.state, ReaderState.done);
    });

    test('rejects tampered ciphertext', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final originalData = utf8.encode('Sensitive Data');
      final chunkFrame = await writer.encryptChunk(originalData);
      // Flip one bit in the ciphertext portion (after 4-byte length)
      chunkFrame[5] ^= 0x01;
      final sentinelFrame = await writer.writeSentinel();

      final stream = Stream<List<int>>.fromIterable([chunkFrame, sentinelFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('AEAD authentication failed'),
        )),
      );
    });

    test('rejects tampered chunk length header', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final chunkFrame = await writer.encryptChunk(utf8.encode('Hello'));
      // Overwrite length with huge value > 65552
      final bd = ByteData.sublistView(chunkFrame, 0, 4);
      bd.setUint32(0, 70000, Endian.big);

      final stream = Stream<List<int>>.fromIterable([chunkFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('exceeds maximum allowed size'),
        )),
      );
    });

    test('rejects truncated stream (sentinel missing)', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final originalData = utf8.encode('Data without sentinel');
      final chunkFrame = await writer.encryptChunk(originalData);

      // Sentinel frame is omitted
      final stream = Stream<List<int>>.fromIterable([chunkFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('Stream truncated'),
        )),
      );
    });

    test('rejects trailing bytes received after sentinel', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId,
      );

      final chunkFrame = await writer.encryptChunk(utf8.encode('Valid data'));
      final sentinelFrame = await writer.writeSentinel();
      final rogueBytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

      final stream = Stream<List<int>>.fromIterable([chunkFrame, sentinelFrame, rogueBytes]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('Trailing bytes'),
        )),
      );
    });

    test('rejects stream encrypted with different fileId', () async {
      final writer = EncryptedStreamWriter(
        fileKey: fileKey,
        transferId: transferId,
        fileId: 'other-file-id',
      );
      final reader = EncryptedStreamReader(
        fileKey: fileKey,
        transferId: transferId,
        fileId: fileId, // Expecting fileId
      );

      final chunkFrame = await writer.encryptChunk(utf8.encode('Data'));
      final sentinelFrame = await writer.writeSentinel();

      final stream = Stream<List<int>>.fromIterable([chunkFrame, sentinelFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('AEAD authentication failed'),
        )),
      );
    });
  });
}
