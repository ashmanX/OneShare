import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Exception thrown when an encrypted stream is tampered, truncated, or invalid.
class EncryptedStreamException implements Exception {
  const EncryptedStreamException(this.message);
  final String message;

  @override
  String toString() => 'EncryptedStreamException: $message';
}

/// Handles chunking, ChaCha20-Poly1305 encryption, and framing for file streaming.
class EncryptedStreamWriter {
  EncryptedStreamWriter({
    required this.fileKey,
    required this.transferId,
    required this.fileId,
  });

  final SecretKey fileKey;
  final String transferId;
  final String fileId;

  static final _algorithm = Chacha20.poly1305Aead();

  static const int maxPlaintextChunkSize = 65536; // 64 KB
  static const int maxCiphertextChunkSize = 65552; // 64 KB + 16-byte Poly1305 tag

  int _chunkCounter = 0;
  int _totalPlaintextBytes = 0;

  /// Constructs the 12-byte nonce for a given [chunkCounter]:
  /// `[0, 0, 0, 0, (8 bytes big-endian chunkCounter)]`.
  static Uint8List buildNonce(int chunkCounter) {
    final nonce = Uint8List(12);
    final bd = ByteData.sublistView(nonce, 4, 12);
    bd.setUint64(0, chunkCounter, Endian.big);
    return nonce;
  }

  /// Encrypts a plaintext chunk (up to 64KB) and returns framed ciphertext bytes:
  /// `[4-byte big-endian length][ciphertext + 16-byte tag]`.
  Future<Uint8List> encryptChunk(List<int> plaintext) async {
    if (plaintext.isEmpty) {
      throw ArgumentError('Plaintext chunk must not be empty. Use writeSentinel for EOF.');
    }
    if (plaintext.length > maxPlaintextChunkSize) {
      throw ArgumentError('Plaintext exceeds maximum chunk size of $maxPlaintextChunkSize');
    }

    final nonce = buildNonce(_chunkCounter);
    final aad = utf8.encode('OS2|$transferId|$fileId|D|$_chunkCounter');

    final secretBox = await _algorithm.encrypt(
      plaintext,
      secretKey: fileKey,
      nonce: nonce,
      aad: aad,
    );

    // Concatenate ciphertext and 16-byte Poly1305 MAC tag
    final ciphertextAndTag = Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length);
    ciphertextAndTag.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
    ciphertextAndTag.setRange(
      secretBox.cipherText.length,
      ciphertextAndTag.length,
      secretBox.mac.bytes,
    );

    final frame = Uint8List(4 + ciphertextAndTag.length);
    final bd = ByteData.sublistView(frame, 0, 4);
    bd.setUint32(0, ciphertextAndTag.length, Endian.big);
    frame.setRange(4, frame.length, ciphertextAndTag);

    _totalPlaintextBytes += plaintext.length;
    _chunkCounter++;

    return frame;
  }

  /// Generates the terminal sentinel frame containing 0 bytes of plaintext:
  /// AAD: `OS2|{transferId}|{fileId}|F|{chunk_counter}|{total_plaintext_bytes}`.
  Future<Uint8List> writeSentinel() async {
    final nonce = buildNonce(_chunkCounter);
    final aad = utf8.encode('OS2|$transferId|$fileId|F|$_chunkCounter|$_totalPlaintextBytes');

    final secretBox = await _algorithm.encrypt(
      const <int>[],
      secretKey: fileKey,
      nonce: nonce,
      aad: aad,
    );

    final ciphertextAndTag = Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length);
    ciphertextAndTag.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
    ciphertextAndTag.setRange(
      secretBox.cipherText.length,
      ciphertextAndTag.length,
      secretBox.mac.bytes,
    );

    final frame = Uint8List(4 + ciphertextAndTag.length);
    final bd = ByteData.sublistView(frame, 0, 4);
    bd.setUint32(0, ciphertextAndTag.length, Endian.big);
    frame.setRange(4, frame.length, ciphertextAndTag);

    return frame;
  }

  /// Transforms a stream of plaintext bytes into framed encrypted chunks
  /// (breaking into <=64KB chunks as needed), and appends the final sentinel frame.
  Stream<Uint8List> encryptStream(Stream<List<int>> inputStream) async* {
    final buffer = <int>[];

    await for (final chunk in inputStream) {
      buffer.addAll(chunk);

      while (buffer.length >= maxPlaintextChunkSize) {
        final slice = buffer.sublist(0, maxPlaintextChunkSize);
        buffer.removeRange(0, maxPlaintextChunkSize);
        yield await encryptChunk(slice);
      }
    }

    if (buffer.isNotEmpty) {
      yield await encryptChunk(buffer);
      buffer.clear();
    }

    yield await writeSentinel();
  }
}

/// State enum for [EncryptedStreamReader].
enum ReaderState {
  readLength,
  readCiphertext,
  decrypt,
  verifyEof,
  done,
  error,
}

/// Reads framed encrypted stream, verifies ChaCha20-Poly1305 tags and final sentinel chunk,
/// yielding decrypted plaintext chunks.
class EncryptedStreamReader {
  EncryptedStreamReader({
    required this.fileKey,
    required this.transferId,
    required this.fileId,
  });

  final SecretKey fileKey;
  final String transferId;
  final String fileId;

  static final _algorithm = Chacha20.poly1305Aead();

  static const int maxCiphertextChunkSize = 65552; // 64 KB + 16 bytes tag

  int _chunkCounter = 0;
  int _accumulatedPlaintextBytes = 0;
  ReaderState _state = ReaderState.readLength;

  ReaderState get state => _state;
  int get accumulatedBytes => _accumulatedPlaintextBytes;

  /// Consumes an incoming raw byte stream and emits decrypted plaintext chunks.
  /// Enforces EOF after terminal sentinel block.
  Stream<Uint8List> processStream(Stream<List<int>> inputStream) async* {
    final buffer = <int>[];
    int? currentExpectedChunkLength;
    bool sentinelVerified = false;

    await for (final chunk in inputStream) {
      if (sentinelVerified) {
        // Any data arriving after sentinel is a hard protocol violation
        _state = ReaderState.error;
        throw const EncryptedStreamException('Trailing bytes received after stream sentinel EOF');
      }

      buffer.addAll(chunk);

      bool processing = true;
      while (processing) {
        if (_state == ReaderState.readLength) {
          if (buffer.length < 4) {
            processing = false;
            break;
          }

          final bd = ByteData.sublistView(Uint8List.fromList(buffer.sublist(0, 4)));
          final chunkLen = bd.getUint32(0, Endian.big);
          buffer.removeRange(0, 4);

          if (chunkLen == 0) {
            _state = ReaderState.error;
            throw const EncryptedStreamException('Invalid zero-length chunk length received');
          }
          if (chunkLen > maxCiphertextChunkSize) {
            _state = ReaderState.error;
            throw EncryptedStreamException(
              'Chunk length $chunkLen exceeds maximum allowed size ($maxCiphertextChunkSize)',
            );
          }

          currentExpectedChunkLength = chunkLen;
          _state = ReaderState.readCiphertext;
        }

        if (_state == ReaderState.readCiphertext) {
          if (buffer.length < currentExpectedChunkLength!) {
            processing = false;
            break;
          }

          final ciphertextWithTag =
              Uint8List.fromList(buffer.sublist(0, currentExpectedChunkLength));
          buffer.removeRange(0, currentExpectedChunkLength);

          if (ciphertextWithTag.length < 16) {
            _state = ReaderState.error;
            throw const EncryptedStreamException('Ciphertext chunk too short to contain Poly1305 MAC tag');
          }

          final cipherText = ciphertextWithTag.sublist(0, ciphertextWithTag.length - 16);
          final mac = Mac(ciphertextWithTag.sublist(ciphertextWithTag.length - 16));
          final nonce = EncryptedStreamWriter.buildNonce(_chunkCounter);

          // 1. Attempt decrypt with Data AAD
          final dataAad = utf8.encode('OS2|$transferId|$fileId|D|$_chunkCounter');
          final dataSecretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

          List<int>? plaintext;
          bool isDataChunk = false;

          try {
            plaintext = await _algorithm.decrypt(
              dataSecretBox,
              secretKey: fileKey,
              aad: dataAad,
            );
            isDataChunk = true;
          } catch (_) {
            // Decrypt with data AAD failed, check if it is the terminal sentinel chunk
          }

          if (isDataChunk) {
            if (plaintext!.isEmpty) {
              _state = ReaderState.error;
              throw const EncryptedStreamException('Unexpected empty data chunk before sentinel');
            }

            _accumulatedPlaintextBytes += plaintext.length;
            _chunkCounter++;
            _state = ReaderState.readLength;
            currentExpectedChunkLength = null;

            yield Uint8List.fromList(plaintext);
            continue;
          }

          // 2. Attempt decrypt with Sentinel AAD
          final sentinelAad = utf8.encode(
            'OS2|$transferId|$fileId|F|$_chunkCounter|$_accumulatedPlaintextBytes',
          );
          final sentinelSecretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

          try {
            final sentinelPlaintext = await _algorithm.decrypt(
              sentinelSecretBox,
              secretKey: fileKey,
              aad: sentinelAad,
            );

            if (sentinelPlaintext.isNotEmpty) {
              _state = ReaderState.error;
              throw const EncryptedStreamException('Sentinel chunk must have zero-length plaintext');
            }

            sentinelVerified = true;
            _state = ReaderState.verifyEof;
            processing = false;
            break;
          } catch (e) {
            _state = ReaderState.error;
            throw EncryptedStreamException('AEAD authentication failed on chunk $_chunkCounter: $e');
          }
        }
      }
    }

    if (!sentinelVerified) {
      _state = ReaderState.error;
      throw const EncryptedStreamException('Stream truncated: stream ended before sentinel chunk was verified');
    }

    if (buffer.isNotEmpty) {
      _state = ReaderState.error;
      throw const EncryptedStreamException('Trailing bytes remain in buffer after sentinel chunk');
    }

    _state = ReaderState.done;
  }
}
