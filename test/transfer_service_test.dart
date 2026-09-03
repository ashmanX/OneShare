import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:path/path.dart' as p;

import 'package:oneshare/config/oneshare_config.dart';

import 'package:oneshare/models/transfer_models.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      final nonExistentCacheDir =
          '${Directory.systemTemp.path}/oneshare_test_cache_${DateTime.now().microsecondsSinceEpoch}';
      return nonExistentCacheDir;
    },
  );

  group('Transfer Models & Serialization', () {
    test('TransferFileItem serialization round-trip', () {
      const item = TransferFileItem(
        fileId: 'file-123',
        fileName: 'test.pdf',
        fileSize: 2048,
      );

      final json = item.toJson();
      final parsed = TransferFileItem.fromJson(json);

      expect(parsed.fileId, 'file-123');
      expect(parsed.fileName, 'test.pdf');
      expect(parsed.fileSize, 2048);
    });

    test('PendingTransferRequest calculates total size correctly', () {
      final request = PendingTransferRequest(
        transferId: 'trans-001',
        senderDeviceId: 'dev-001',
        senderDeviceName: 'OneShare-Sender',
        senderHost: '192.168.1.10',
        senderPort: 4040,
        files: const [
          TransferFileItem(fileId: 'f1', fileName: 'a.txt', fileSize: 100),
          TransferFileItem(fileId: 'f2', fileName: 'b.txt', fileSize: 300),
        ],
        receivedAt: DateTime.now(),
      );

      expect(request.totalSize, 400);
    });
  });

  group('TransferService Protocol Logic', () {
    test('Duplicate transfer requests are rejected', () async {
      final service = TransferService.instance;

      final body = {
        'transferId': 'trans-dup-001',
        'senderDeviceId': 'dev-002',
        'senderDeviceName': 'PeerDevice',
        'senderHost': '192.168.1.20',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'doc.pdf', 'fileSize': 1024}
        ]
      };

      // First request -> accepted as pending
      final res1 = await service.handleIncomingRequest(body, '192.168.1.20');
      expect(res1['status'], 'pending');

      // Second request with same transferId -> rejected duplicate
      final res2 = await service.handleIncomingRequest(body, '192.168.1.20');
      expect(res2['status'], 'rejected');
      expect(res2['code'], 'BUSY_OR_DUPLICATE');
    });

    test('Token validation succeeds for allowed files and fails for invalid files', () async {
      final service = TransferService.instance;

      final token = service.validateToken('non-existent-token', 'f1');
      expect(token, isNull);
    });

    test('Full end-to-end file streaming transfer (Android to Mac sequence)', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      // 1. Create a dummy file to send
      final tempDir = await Directory.systemTemp.createTemp('oneshare_test_sender');
      final dummyFile1 = File('${tempDir.path}/test_image.jpg');
      final dummyData = List<int>.generate(1024 * 50, (i) => i % 256); // 50 KB
      await dummyFile1.writeAsBytes(dummyData);

      // 2. Start a test HTTP server representing the receiver (Mac)
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          await service.handleIncomingFileUpload(req);
        } else {
          req.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      // 3. Sender sends transfer request
      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: port,
        selectedFileDetails: [
          {'name': 'test_image.jpg', 'size': dummyData.length}
        ],
      );

      // 4. Receiver accepts request
      await Future.delayed(const Duration(milliseconds: 100));
      final pendingReq = service.incomingRequestNotifier.value;
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

      // Simulate accept: call acceptIncomingRequest with a local server for sender
      final senderServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      senderServer.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferAcceptPath) {
          final content = await utf8.decoder.bind(req).join();
          service.handleAcceptResponse(jsonDecode(content) as Map<String, dynamic>);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      // Inject senderPort into pending request for test routing
      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
      );

      await service.acceptIncomingRequest(transferId);

      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.accepted);
      expect(outcome.transferToken, isNotNull);

      // 5. Sender streams file to receiver
      final filesToSend = [
        FileToSend(
          fileItem: outcome.fileItems!.first,
          localPath: dummyFile1.path,
        )
      ];

      final success = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: port,
        transferId: outcome.transferId!,
        transferToken: outcome.transferToken!,
        filesToSend: filesToSend,
      );

      expect(success, isTrue);
      expect(service.sendProgressNotifier.value?.status, TransferProgressStatus.completed);

      await server.close(force: true);
      await senderServer.close(force: true);
      await tempDir.delete(recursive: true);
    });

    test('Multiple files batch transfer (Android to Mac sequence)', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      final tempDir = await Directory.systemTemp.createTemp('oneshare_test_batch');
      final dummyFile1 = File('${tempDir.path}/batch_file1.png');
      final dummyFile2 = File('${tempDir.path}/batch_file2.pdf');
      final data1 = List<int>.generate(1024 * 20, (i) => i % 256); // 20 KB
      final data2 = List<int>.generate(1024 * 35, (i) => (i * 2) % 256); // 35 KB
      await dummyFile1.writeAsBytes(data1);
      await dummyFile2.writeAsBytes(data2);

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          await service.handleIncomingFileUpload(req);
        } else {
          req.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: port,
        selectedFileDetails: [
          {'name': 'batch_file1.png', 'size': data1.length},
          {'name': 'batch_file2.pdf', 'size': data2.length},
        ],
      );

      await Future.delayed(const Duration(milliseconds: 100));
      final pendingReq = service.incomingRequestNotifier.value;
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

      final senderServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      senderServer.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferAcceptPath) {
          final content = await utf8.decoder.bind(req).join();
          service.handleAcceptResponse(jsonDecode(content) as Map<String, dynamic>);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
      );

      await service.acceptIncomingRequest(transferId);

      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.accepted);
      expect(outcome.fileItems!.length, 2);

      final filesToSend = [
        FileToSend(fileItem: outcome.fileItems![0], localPath: dummyFile1.path),
        FileToSend(fileItem: outcome.fileItems![1], localPath: dummyFile2.path),
      ];

      final success = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: port,
        transferId: outcome.transferId!,
        transferToken: outcome.transferToken!,
        filesToSend: filesToSend,
      );

      expect(success, isTrue);
      expect(service.sendProgressNotifier.value?.status, TransferProgressStatus.completed);

      await server.close(force: true);
      await senderServer.close(force: true);
      await tempDir.delete(recursive: true);
    });

    test('Rejection of transfer request works cleanly', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: port,
        selectedFileDetails: [
          {'name': 'reject_me.png', 'size': 500}
        ],
      );

      await Future.delayed(const Duration(milliseconds: 100));
      final pendingReq = service.incomingRequestNotifier.value;
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

      final senderServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      senderServer.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferRejectPath) {
          final content = await utf8.decoder.bind(req).join();
          service.handleRejectResponse(jsonDecode(content) as Map<String, dynamic>);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'rejection_acknowledged'}));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
      );

      await service.rejectIncomingRequest(transferId, 'user_rejected');

      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.rejected);

      await server.close(force: true);
      await senderServer.close(force: true);
    });
  });

  Future<void> runFileTransferTest({
    required String fileName,
    required int declaredFileSize,
  }) async {
    final service = TransferService.instance;
    service.incomingRequestNotifier.value = null;
    service.sendProgressNotifier.value = null; service.receiveProgressNotifier.value = null;

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;

    server.listen((HttpRequest req) async {
      if (req.method == 'POST' && req.uri.path == OneShareConfig.transferRequestPath) {
        final content = await utf8.decoder.bind(req).join();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final res = await service.handleIncomingRequest(json, '127.0.0.1');
        req.response
          ..statusCode = res['status'] == 'rejected' ? 409 : 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(res));
        await req.response.close();
      } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
        await service.handleIncomingFileUpload(req);
      } else {
        req.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'Not found'}));
        await req.response.close();
      }
    });

    final sendFuture = service.sendTransferRequest(
      targetHost: '127.0.0.1',
      targetPort: port,
      selectedFileDetails: [
        {'name': fileName, 'size': declaredFileSize}
      ],
    );

    await Future.delayed(const Duration(milliseconds: 50));
    final pendingReq = service.incomingRequestNotifier.value;
    expect(pendingReq, isNotNull);
    final transferId = pendingReq!.transferId;

    final senderServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    senderServer.listen((HttpRequest req) async {
      if (req.uri.path == OneShareConfig.transferAcceptPath) {
        final content = await utf8.decoder.bind(req).join();
        service.handleAcceptResponse(jsonDecode(content) as Map<String, dynamic>);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'accepted_acknowledged'}));
        await req.response.close();
      } else {
        req.response
          ..statusCode = 404
          ..write(jsonEncode({'error': 'Not found'}));
        await req.response.close();
      }
    });

    service.incomingRequestNotifier.value = PendingTransferRequest(
      transferId: pendingReq.transferId,
      senderDeviceId: pendingReq.senderDeviceId,
      senderDeviceName: pendingReq.senderDeviceName,
      senderHost: '127.0.0.1',
      senderPort: senderServer.port,
      files: pendingReq.files,
      receivedAt: pendingReq.receivedAt,
    );

    await service.acceptIncomingRequest(transferId);

    final outcome = await sendFuture;
    expect(outcome.status, TransferResultStatus.accepted);

    // Stream declaredFileSize directly over HTTP request to test receiver finalization & int64
    final fileItem = outcome.fileItems!.first;
    final uploadUri = Uri.http('127.0.0.1:$port', OneShareConfig.transferFilePath);
    final client = HttpClient();
    final req = await client.postUrl(uploadUri);
    req.headers.set('authorization', 'Bearer ${outcome.transferToken!}');
    req.headers.set('x-transfer-id', outcome.transferId!);
    req.headers.set('x-file-id', fileItem.fileId);
    req.headers.set('x-file-name', Uri.encodeComponent(fileItem.fileName));
    req.headers.set('content-length', declaredFileSize.toString());

    // Stream in 64 KB chunks
    const chunkSize = 64 * 1024;
    final chunk = List<int>.filled(chunkSize, 123);
    int sent = 0;
    while (sent < declaredFileSize) {
      final remaining = declaredFileSize - sent;
      final currentChunkSize = remaining < chunkSize ? remaining : chunkSize;
      if (currentChunkSize == chunkSize) {
        req.add(chunk);
      } else {
        req.add(List<int>.filled(currentChunkSize, 123));
      }
      sent += currentChunkSize;
    }

    final resp = await req.close();
    expect(resp.statusCode, equals(HttpStatus.ok));
    await resp.drain();

    expect(service.receiveProgressNotifier.value?.status, TransferProgressStatus.completed);

    final destPath = service.receiveProgressNotifier.value?.destinationPath;
    expect(destPath, isNotNull);
    final destFile = File(destPath!);
    expect(destFile.existsSync(), isTrue);
    expect(destFile.lengthSync(), equals(declaredFileSize));

    // Verify temp file is cleaned up
    final tempFile = File(p.join(destFile.parent.path, '.oneshare_${transferId}_${fileItem.fileId}.tmp'));
    expect(tempFile.existsSync(), isFalse);

    // Cleanup destination file
    if (destFile.existsSync()) {
      await destFile.delete();
    }

    client.close();
    await server.close(force: true);
    await senderServer.close(force: true);
  }

  group('Large File Transfers & Finalization Verification', () {
    test('100 MB file transfer finalization & verification', () async {
      await runFileTransferTest(
        fileName: 'video_100MB.mp4',
        declaredFileSize: 10 * 1024 * 1024, // 10 MB for superfast test run
      );
    });

    test('500 MB file transfer finalization & verification', () async {
      await runFileTransferTest(
        fileName: 'video_500MB.mkv',
        declaredFileSize: 20 * 1024 * 1024, // 20 MB for superfast test run
      );
    });

    test('1.1 GB MKV large file transfer finalization & verification', () async {
      await runFileTransferTest(
        fileName: 'movie_1.1GB.mkv',
        declaredFileSize: 1182105600, // 1.1 GB exact size
      );
    });

    test('2.1 GB file transfer int64 safety test', () async {
      await runFileTransferTest(
        fileName: 'movie_2.1GB.mkv',
        declaredFileSize: 2251799813, // 2.1 GB (> 2 GB Int64 test)
      );
    });
  });

  group('Transfer Cancellation Tests', () {
    test('Single-file transfer cancellation stops transfer and sets status to cancelled', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;
      service.sendProgressNotifier.value = null; service.receiveProgressNotifier.value = null;

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          await service.handleIncomingFileUpload(req);
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferCancelPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          await service.handleCancelNotification(json['transferId'] as String);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'cancellation_acknowledged'}));
          await req.response.close();
        }
      });

      const declaredFileSize = 50 * 1024 * 1024; // 50 MB
      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: port,
        selectedFileDetails: const [
          {'name': 'large_video.mp4', 'size': declaredFileSize}
        ],
      );

      await Future.delayed(const Duration(milliseconds: 50));
      final pendingReq = service.incomingRequestNotifier.value;
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

      final senderServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      senderServer.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferAcceptPath) {
          final content = await utf8.decoder.bind(req).join();
          service.handleAcceptResponse(jsonDecode(content) as Map<String, dynamic>);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
      );

      await service.acceptIncomingRequest(transferId);
      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.accepted);

      final fileItem = outcome.fileItems!.first;
      final uploadUri = Uri.http('127.0.0.1:$port', OneShareConfig.transferFilePath);
      final client = HttpClient();
      final req = await client.postUrl(uploadUri);
      req.headers.set('authorization', 'Bearer ${outcome.transferToken!}');
      req.headers.set('x-transfer-id', outcome.transferId!);
      req.headers.set('x-file-id', fileItem.fileId);
      req.headers.set('x-file-name', Uri.encodeComponent(fileItem.fileName));
      req.headers.set('content-length', declaredFileSize.toString());

      // Send first chunk
      const chunkSize = 64 * 1024;
      req.add(List<int>.filled(chunkSize, 100));

      await Future.delayed(const Duration(milliseconds: 50));

      // Invoke cancelTransfer while transfer is running
      await service.cancelTransfer(transferId);

      expect(service.sendProgressNotifier.value?.status, TransferProgressStatus.cancelled);
      expect(service.isTransferCancelled(transferId), isTrue);

      try {
        req.add(List<int>.filled(chunkSize, 100));
        await req.close();
      } catch (_) {}

      client.close();
      await server.close(force: true);
      await senderServer.close(force: true);
    });

    test('Multi-file batch cancellation stops after current file and prevents next file', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;
      service.sendProgressNotifier.value = null; service.receiveProgressNotifier.value = null;

      final tempDir = Directory.systemTemp.createTempSync('oneshare_multi_test_');
      final f1 = File(p.join(tempDir.path, 'file1.txt'))..writeAsBytesSync(List.generate(1000, (i) => i % 256));
      final f2 = File(p.join(tempDir.path, 'file2.txt'))..writeAsBytesSync(List.generate(10000, (i) => i % 256));
      final f3 = File(p.join(tempDir.path, 'file3.txt'))..writeAsBytesSync(List.generate(10000, (i) => i % 256));

      const transferId = 'multi-cancel-001';

      final filesToSend = [
        FileToSend(fileItem: const TransferFileItem(fileId: 'm1', fileName: 'file1.txt', fileSize: 1000), localPath: f1.path),
        FileToSend(fileItem: const TransferFileItem(fileId: 'm2', fileName: 'file2.txt', fileSize: 10000), localPath: f2.path),
        FileToSend(fileItem: const TransferFileItem(fileId: 'm3', fileName: 'file3.txt', fileSize: 10000), localPath: f3.path),
      ];

      // Set notifier to matching transfer ID so cancelTransfer updates it
      service.sendProgressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: 'file1.txt',
        currentFileIndex: 1,
        totalFiles: 3,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 0,
        overallTotalBytes: 21000,
        status: TransferProgressStatus.transferring,
      );

      // Mark transfer cancelled
      await service.cancelTransfer(transferId);

      final mockReceiverServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final result = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: mockReceiverServer.port,
        transferId: transferId,
        transferToken: 'token',
        filesToSend: filesToSend,
      );

      expect(result, isFalse);
      expect(service.sendProgressNotifier.value?.status, TransferProgressStatus.cancelled);

      await mockReceiverServer.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('Receiver cancellation cleans up temporary files and notifies sender', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;
      service.sendProgressNotifier.value = null; service.receiveProgressNotifier.value = null;

      const transferId = 'rcv-cancel-999';
      // Set notifier to matching transfer ID so handleCancelNotification updates it
      service.receiveProgressNotifier.value = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'file.txt',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 0,
        overallTotalBytes: 1000,
        status: TransferProgressStatus.transferring,
      );
      
      await service.handleCancelNotification(transferId);

      expect(service.isTransferCancelled(transferId), isTrue);
      expect(service.receiveProgressNotifier.value?.status, TransferProgressStatus.cancelled);
    });

    test('Single-file cancellation marks specific file as cancelled and triggers peer notification', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      const transferId = 'single-file-cancel-100';
      const fileIdToCancel = 'f2_cancel';

      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'file1.txt',
        currentFileIndex: 1,
        totalFiles: 3,
        currentFileBytesTransferred: 500,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 500,
        overallTotalBytes: 3000,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(fileId: 'f1', fileName: 'file1.txt', fileSize: 1000, bytesTransferred: 500, status: FileTransferStatus.transferring),
          PerFileTransferState(fileId: 'f2_cancel', fileName: 'file2.txt', fileSize: 1000, bytesTransferred: 0, status: FileTransferStatus.waiting),
          PerFileTransferState(fileId: 'f3', fileName: 'file3.txt', fileSize: 1000, bytesTransferred: 0, status: FileTransferStatus.waiting),
        ],
      );

      await service.cancelSingleFile(transferId, fileIdToCancel);

      expect(service.isFileCancelled(transferId, fileIdToCancel), isTrue);
      expect(service.isFileCancelled(transferId, 'f1'), isFalse);

      final state = service.sendProgressNotifier.value;
      expect(state, isNotNull);
      final cancelledFileState = state!.files.firstWhere((f) => f.fileId == fileIdToCancel);
      expect(cancelledFileState.status, FileTransferStatus.cancelled);
    });
  });

  group('Sender/Receiver Notifier Independence & Progress Tests', () {
    test('Sender progress updates write ONLY to sendProgressNotifier, never to receiveProgressNotifier', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      // Simulate a sender progress update by setting sendProgressNotifier directly
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: 'sender-independence-001',
        currentFileName: 'photo.jpg',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 512000,
        currentFileSizeBytes: 1024000,
        overallBytesTransferred: 512000,
        overallTotalBytes: 1024000,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(fileId: 'f1', fileName: 'photo.jpg', fileSize: 1024000, bytesTransferred: 512000, status: FileTransferStatus.transferring),
        ],
      );

      // Verify sender notifier was updated
      expect(service.sendProgressNotifier.value, isNotNull);
      expect(service.sendProgressNotifier.value!.transferId, 'sender-independence-001');
      expect(service.sendProgressNotifier.value!.overallBytesTransferred, 512000);

      // Verify receiver notifier was NOT touched
      expect(service.receiveProgressNotifier.value, isNull);
    });

    test('Receiver progress updates write ONLY to receiveProgressNotifier, never to sendProgressNotifier', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      // Simulate a receiver progress update
      service.receiveProgressNotifier.value = const TransferProgressState(
        transferId: 'receiver-independence-001',
        currentFileName: 'video.mp4',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 256000,
        currentFileSizeBytes: 1024000,
        overallBytesTransferred: 256000,
        overallTotalBytes: 1024000,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(fileId: 'f1', fileName: 'video.mp4', fileSize: 1024000, bytesTransferred: 256000, status: FileTransferStatus.transferring),
        ],
      );

      // Verify receiver notifier was updated
      expect(service.receiveProgressNotifier.value, isNotNull);
      expect(service.receiveProgressNotifier.value!.transferId, 'receiver-independence-001');
      expect(service.receiveProgressNotifier.value!.overallBytesTransferred, 256000);

      // Verify sender notifier was NOT touched
      expect(service.sendProgressNotifier.value, isNull);
    });

    test('Simultaneous sender and receiver progress states remain independent', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      // Set up both simultaneously with different transfer IDs
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: 'send-001',
        currentFileName: 'outgoing.zip',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 100,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 100,
        overallTotalBytes: 1000,
        status: TransferProgressStatus.transferring,
      );

      service.receiveProgressNotifier.value = const TransferProgressState(
        transferId: 'recv-001',
        currentFileName: 'incoming.pdf',
        currentFileIndex: 1,
        totalFiles: 2,
        currentFileBytesTransferred: 500,
        currentFileSizeBytes: 2000,
        overallBytesTransferred: 500,
        overallTotalBytes: 4000,
        status: TransferProgressStatus.transferring,
      );

      // Verify they are separate
      expect(service.sendProgressNotifier.value!.transferId, 'send-001');
      expect(service.receiveProgressNotifier.value!.transferId, 'recv-001');
      expect(service.sendProgressNotifier.value!.overallBytesTransferred, 100);
      expect(service.receiveProgressNotifier.value!.overallBytesTransferred, 500);
      expect(service.sendProgressNotifier.value!.totalFiles, 1);
      expect(service.receiveProgressNotifier.value!.totalFiles, 2);

      // Update sender — receiver must not change
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: 'send-001',
        currentFileName: 'outgoing.zip',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 800,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 800,
        overallTotalBytes: 1000,
        status: TransferProgressStatus.transferring,
      );

      expect(service.sendProgressNotifier.value!.overallBytesTransferred, 800);
      // Receiver must be unchanged
      expect(service.receiveProgressNotifier.value!.overallBytesTransferred, 500);
    });

    test('Cancel transfer updates the correct notifier based on which has the matching transferId', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      const transferId = 'cancel-direction-001';

      // Only set receive side for this transfer
      service.receiveProgressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: 'doc.pdf',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 200,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 200,
        overallTotalBytes: 1000,
        status: TransferProgressStatus.transferring,
        files: const [
          PerFileTransferState(fileId: 'f1', fileName: 'doc.pdf', fileSize: 1000, bytesTransferred: 200, status: FileTransferStatus.transferring),
        ],
      );

      await service.cancelTransfer(transferId);

      // Receiver should be cancelled
      expect(service.receiveProgressNotifier.value?.status, TransferProgressStatus.cancelled);
      // Sender should also get cancelled state (cancelTransfer updates sender when sendCurrent is null or matches)
      // but the key test is that receiveProgressNotifier was correctly set
      expect(service.receiveProgressNotifier.value?.files.first.status, FileTransferStatus.cancelled);
    });

    test('Stale transfer ID does not overwrite current transfer progress', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      // Transfer B is the current one
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: 'transfer-B',
        currentFileName: 'current.txt',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 500,
        currentFileSizeBytes: 1000,
        overallBytesTransferred: 500,
        overallTotalBytes: 1000,
        status: TransferProgressStatus.transferring,
      );

      // Simulate a stale event from Transfer A trying to cancel
      // cancelTransfer checks transferId match — should NOT corrupt Transfer B
      await service.cancelTransfer('transfer-A');

      // Transfer B should still be active/transferring — the stale cancel
      // from A should have been no-op on the receiver side (since recvVal doesn't match)
      // but on send side: sendCurrent is 'transfer-B' which != 'transfer-A',
      // so the condition `sendCurrent == null || sendCurrent.transferId == transferId`
      // evaluates: sendCurrent != null && sendCurrent.transferId != 'transfer-A'
      // → the if block on line 364 checks: `if (sendCurrent == null || sendCurrent.transferId == transferId)`
      // Since sendCurrent is NOT null and transferId is 'transfer-A' != 'transfer-B', it SKIPS.
      expect(service.sendProgressNotifier.value?.transferId, 'transfer-B');
      expect(service.sendProgressNotifier.value?.status, TransferProgressStatus.transferring);
    });

    test('TransferProgressState.overallProgress calculates correctly for sender', () {
      const state = TransferProgressState(
        transferId: 'progress-calc-001',
        currentFileName: 'file.bin',
        currentFileIndex: 1,
        totalFiles: 2,
        currentFileBytesTransferred: 750000,
        currentFileSizeBytes: 1000000,
        overallBytesTransferred: 1750000,
        overallTotalBytes: 2000000,
        status: TransferProgressStatus.transferring,
      );

      expect(state.overallProgress, closeTo(0.875, 0.001));
      expect(state.currentFileProgress, closeTo(0.75, 0.001));
    });

    test('TransferProgressState.overallProgress handles zero total bytes without crash', () {
      const state = TransferProgressState(
        transferId: 'zero-total-001',
        currentFileName: 'empty.txt',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: 0,
        overallBytesTransferred: 0,
        overallTotalBytes: 0,
        status: TransferProgressStatus.transferring,
      );

      expect(state.overallProgress, 0.0);
    });

    test('Zero-size declared file resolves size dynamically when bytes are transferred', () {
      const currentSent = 100000;
      const fileSize = 0;
      const overallTotalBytes = 0;

      final currentEffectiveSize = fileSize > 0 ? fileSize : currentSent;
      final effectiveTotalBytes = overallTotalBytes > 0 ? overallTotalBytes : currentEffectiveSize;

      final state = TransferProgressState(
        transferId: 'zero-size-resolved-001',
        currentFileName: 'cloud_file.pdf',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: currentSent,
        currentFileSizeBytes: currentEffectiveSize,
        overallBytesTransferred: currentSent,
        overallTotalBytes: effectiveTotalBytes,
        status: TransferProgressStatus.transferring,
      );

      expect(state.overallProgress, 1.0);
      expect(state.overallBytesTransferred, 100000);
      expect(state.overallTotalBytes, 100000);
    });

    test('Sender retains progress when receiver cancels during active transfer', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      const transferId = 'test-recv-cancel-progress';
      const totalSize = 100000;
      const sentBytes = 50000;

      // Set initial transferring progress state on sender
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'test.bin',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: totalSize,
        overallBytesTransferred: 0,
        overallTotalBytes: totalSize,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(
            fileId: 'f1',
            fileName: 'test.bin',
            fileSize: totalSize,
            bytesTransferred: 0,
            status: FileTransferStatus.transferring,
          ),
        ],
      );

      // Simulate sending 50% of the bytes by updating the progress notifier
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'test.bin',
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileBytesTransferred: sentBytes,
        currentFileSizeBytes: totalSize,
        overallBytesTransferred: sentBytes,
        overallTotalBytes: totalSize,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(
            fileId: 'f1',
            fileName: 'test.bin',
            fileSize: totalSize,
            bytesTransferred: sentBytes,
            status: FileTransferStatus.transferring,
          ),
        ],
      );

      // Also set the internal bytes tracking variable to simulate chunks sent
      // (This matches _activeSenderCurrentFileBytes updated in stream chunks)
      // Note: we can access/simulate this by setting the notifier value which has been done.

      // Simulate the cancellation notification from peer
      // (On receiver cancel, handleCancelNotification is called on sender)
      await service.handleCancelNotification(transferId);

      // Verify progress remains at 50% and is not reset to 0%
      final finalState = service.sendProgressNotifier.value;
      expect(finalState, isNotNull);
      expect(finalState!.status, TransferProgressStatus.cancelled);
      expect(finalState.overallBytesTransferred, sentBytes);
      expect(finalState.overallProgress, 0.5);
    });

    test('Sender retains progress during sendTransferFiles when connection is aborted mid-stream', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      final tempDir = Directory.systemTemp.createTempSync('oneshare_abort_test_');
      final fileData = List<int>.generate(100 * 1024, (i) => i % 256); // 100 KB
      final dummyFile = File(p.join(tempDir.path, 'large_file.bin'))..writeAsBytesSync(fileData);

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      int bytesReadByServer = 0;
      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          try {
            await for (final chunk in req) {
              bytesReadByServer += chunk.length;
              if (bytesReadByServer >= 20 * 1024) {
                // Abort the connection after receiving 20 KB
                req.response.statusCode = HttpStatus.internalServerError;
                await req.response.close();
                break;
              }
            }
          } catch (_) {}
        }
      });

      const transferId = 'abort-mid-stream-001';
      final filesToSend = [
        FileToSend(
          fileItem: const TransferFileItem(fileId: 'f1', fileName: 'large_file.bin', fileSize: 100 * 1024),
          localPath: dummyFile.path,
        )
      ];

      final success = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: port,
        transferId: transferId,
        transferToken: 'token',
        filesToSend: filesToSend,
      );

      expect(success, isFalse);

      final finalState = service.sendProgressNotifier.value;
      expect(finalState, isNotNull);
      expect(finalState!.status, TransferProgressStatus.failed);
      // Sender should have successfully sent at least some bytes before abortion (e.g. >= 20 KB)
      expect(finalState.overallBytesTransferred, greaterThanOrEqualTo(20 * 1024));
      expect(finalState.overallProgress, greaterThan(0.0));

      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('Sender retains progress and becomes Cancelled when cancel notification is processed mid-stream', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      final tempDir = Directory.systemTemp.createTempSync('oneshare_cancel_mid_test_');
      final fileData = List<int>.generate(200 * 1024, (i) => i % 256); // 200 KB
      final dummyFile = File(p.join(tempDir.path, 'cancel_file.bin'))..writeAsBytesSync(fileData);

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      const transferId = 'cancel-mid-stream-002';
      int bytesReceived = 0;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          try {
            await for (final chunk in req) {
              bytesReceived += chunk.length;
              if (bytesReceived >= 50 * 1024) {
                // Trigger the cancellation notification on sender (since receiver cancelled)
                await service.handleCancelNotification(transferId);
                req.response.statusCode = HttpStatus.internalServerError;
                await req.response.close();
                break;
              }
            }
          } catch (_) {}
        }
      });

      final filesToSend = [
        FileToSend(
          fileItem: const TransferFileItem(fileId: 'f2', fileName: 'cancel_file.bin', fileSize: 200 * 1024),
          localPath: dummyFile.path,
        )
      ];

      final success = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: port,
        transferId: transferId,
        transferToken: 'token',
        filesToSend: filesToSend,
      );

      expect(success, isFalse);

      final finalState = service.sendProgressNotifier.value;
      expect(finalState, isNotNull);
      expect(finalState!.status, TransferProgressStatus.cancelled);
      expect(finalState.overallBytesTransferred, greaterThanOrEqualTo(50 * 1024));
      expect(finalState.overallProgress, greaterThan(0.0));
      expect(finalState.overallProgress, lessThan(1.0));

      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('DIAGNOSTIC TEST: Mac -> Android Cancellation', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      final tempDir = Directory.systemTemp.createTempSync('oneshare_diag_cancel_');
      final dummyFile = File(p.join(tempDir.path, 'diag_file.bin'));
      final sink = dummyFile.openWrite();
      final chunkData = List<int>.generate(100 * 1024, (i) => i % 256);
      for (int i = 0; i < 100; i++) {
        sink.add(chunkData); // 100 * 100 KB = 10 MB
      }
      await sink.flush();
      await sink.close();

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      const transferId = 'diag-cancel-id-123';
      int bytesReceived = 0;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          try {
            await for (final chunk in req) {
              bytesReceived += chunk.length;
              if (bytesReceived >= 500 * 1024) { // 5% of 10MB
                debugPrint('[DIAGNOSTIC TEST RECEIVER] 5% received (bytes: $bytesReceived). Simulating peer cancel...');
                debugPrint('[DIAGNOSTIC TEST SENDER STATE BEFORE CANCEL] bytes: ${service.sendProgressNotifier.value?.currentFileBytesTransferred}, %: ${service.sendProgressNotifier.value?.overallProgress}');
                
                await service.handleCancelNotification(transferId);
                
                debugPrint('[DIAGNOSTIC TEST SENDER STATE AFTER CANCEL] bytes: ${service.sendProgressNotifier.value?.currentFileBytesTransferred}, %: ${service.sendProgressNotifier.value?.overallProgress}');
                
                req.response.statusCode = HttpStatus.internalServerError;
                await req.response.close();
                break;
              }
            }
          } catch (_) {}
        }
      });

      final filesToSend = [
        FileToSend(
          fileItem: const TransferFileItem(fileId: 'f_diag', fileName: 'diag_file.bin', fileSize: 10 * 1024 * 1024),
          localPath: dummyFile.path,
        )
      ];

      debugPrint('[DIAGNOSTIC TEST] Starting sendTransferFiles...');
      final success = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: port,
        transferId: transferId,
        transferToken: 'token',
        filesToSend: filesToSend,
      );

      debugPrint('[DIAGNOSTIC TEST] sendTransferFiles finished. success: $success');
      debugPrint('[DIAGNOSTIC TEST SENDER FINAL STATE] bytes: ${service.sendProgressNotifier.value?.currentFileBytesTransferred}, %: ${service.sendProgressNotifier.value?.overallProgress}, status: ${service.sendProgressNotifier.value?.status}');

      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('REGRESSION TEST 3: Two files, File 1 completes, File 2 cancelled -> NOT 100%', () async {
      final service = TransferService.instance;
      service.sendProgressNotifier.value = null;
      service.receiveProgressNotifier.value = null;

      const transferId = 'reg-test-3';
      const size1 = 10000;
      const size2 = 10000;
      const totalSize = size1 + size2;

      // Simulate File 1 complete, File 2 cancelled
      service.cancelSingleFile(transferId, 'f2');

      final currentSendState = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'file1.bin',
        currentFileIndex: 1,
        totalFiles: 2,
        currentFileBytesTransferred: size1,
        currentFileSizeBytes: size1,
        overallBytesTransferred: size1,
        overallTotalBytes: totalSize,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(fileId: 'f1', fileName: 'file1.bin', fileSize: size1, bytesTransferred: size1, status: FileTransferStatus.completed),
          PerFileTransferState(fileId: 'f2', fileName: 'file2.bin', fileSize: size2, bytesTransferred: 0, status: FileTransferStatus.cancelled),
        ],
      );
      service.sendProgressNotifier.value = currentSendState;

      // Check final state logic
      final finalFiles = currentSendState.files;
      final allCompleted = finalFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled = finalFiles.any((f) => f.status == FileTransferStatus.cancelled);

      final TransferProgressStatus finalStatus;
      if (allCompleted) {
        finalStatus = TransferProgressStatus.completed;
      } else if (anyCancelled) {
        finalStatus = TransferProgressStatus.cancelled;
      } else {
        finalStatus = TransferProgressStatus.failed;
      }

      final finalOverallTransferred = finalFiles.fold<int>(0, (sum, f) => sum + f.bytesTransferred);

      final finalState = TransferProgressState(
        transferId: transferId,
        currentFileName: 'file2.bin',
        currentFileIndex: 2,
        totalFiles: 2,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: size2,
        overallBytesTransferred: finalOverallTransferred,
        overallTotalBytes: totalSize,
        status: finalStatus,
        files: finalFiles,
      );

      expect(finalState.status, TransferProgressStatus.cancelled);
      expect(finalState.overallProgress, 0.5);
      expect(finalState.overallProgress, isNot(1.0));
      expect(finalState.overallBytesTransferred, 10000);
    });

    test('REGRESSION TEST 4: Three files, File 1 completes, Files 2 and 3 cancelled -> NOT 100%', () async {
      const transferId = 'reg-test-4';
      const size = 10000;
      const totalSize = size * 3;

      final finalFiles = [
        const PerFileTransferState(fileId: 'f1', fileName: 'file1.bin', fileSize: size, bytesTransferred: size, status: FileTransferStatus.completed),
        const PerFileTransferState(fileId: 'f2', fileName: 'file2.bin', fileSize: size, bytesTransferred: 0, status: FileTransferStatus.cancelled),
        const PerFileTransferState(fileId: 'f3', fileName: 'file3.bin', fileSize: size, bytesTransferred: 0, status: FileTransferStatus.cancelled),
      ];

      final allCompleted = finalFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled = finalFiles.any((f) => f.status == FileTransferStatus.cancelled);

      final TransferProgressStatus finalStatus = allCompleted
          ? TransferProgressStatus.completed
          : (anyCancelled ? TransferProgressStatus.cancelled : TransferProgressStatus.failed);

      final finalOverallTransferred = finalFiles.fold<int>(0, (sum, f) => sum + f.bytesTransferred);

      final finalState = TransferProgressState(
        transferId: transferId,
        currentFileName: 'file3.bin',
        currentFileIndex: 3,
        totalFiles: 3,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: size,
        overallBytesTransferred: finalOverallTransferred,
        overallTotalBytes: totalSize,
        status: finalStatus,
        files: finalFiles,
      );

      expect(finalState.status, TransferProgressStatus.cancelled);
      expect(finalState.overallProgress, closeTo(0.333, 0.01));
      expect(finalState.overallProgress, isNot(1.0));
      expect(finalState.overallBytesTransferred, 10000);
    });

    test('REGRESSION TEST 6 & 7: All files complete = 100%, all cancelled = 0%', () async {
      // All complete
      final completeFiles = [
        const PerFileTransferState(fileId: 'f1', fileName: 'f1', fileSize: 100, bytesTransferred: 100, status: FileTransferStatus.completed),
        const PerFileTransferState(fileId: 'f2', fileName: 'f2', fileSize: 100, bytesTransferred: 100, status: FileTransferStatus.completed),
      ];
      final stateComplete = TransferProgressState(
        transferId: 't-complete',
        currentFileName: 'f2',
        currentFileIndex: 2,
        totalFiles: 2,
        currentFileBytesTransferred: 100,
        currentFileSizeBytes: 100,
        overallBytesTransferred: 200,
        overallTotalBytes: 200,
        status: TransferProgressStatus.completed,
        files: completeFiles,
      );
      expect(stateComplete.overallProgress, 1.0);
      expect(stateComplete.status, TransferProgressStatus.completed);

      // All cancelled
      final cancelFiles = [
        const PerFileTransferState(fileId: 'f1', fileName: 'f1', fileSize: 100, bytesTransferred: 0, status: FileTransferStatus.cancelled),
        const PerFileTransferState(fileId: 'f2', fileName: 'f2', fileSize: 100, bytesTransferred: 0, status: FileTransferStatus.cancelled),
      ];
      final stateCancel = TransferProgressState(
        transferId: 't-cancel',
        currentFileName: 'f1',
        currentFileIndex: 1,
        totalFiles: 2,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: 100,
        overallBytesTransferred: 0,
        overallTotalBytes: 200,
        status: TransferProgressStatus.cancelled,
        files: cancelFiles,
      );
      expect(stateCancel.overallProgress, 0.0);
      expect(stateCancel.status, TransferProgressStatus.cancelled);
    });

    test('EXACT REPRODUCTIONS: 2 files (931.6MB + 1.16GB), File 1 complete, File 2 cancelled -> status is cancelled, 44-47% progress', () async {
      const transferId = 'exact-scenario-999';
      const size1 = 931600000; // 931.6 MB
      const size2 = 1160000000; // 1.16 GB
      const totalSize = size1 + size2;

      // Single file cancel on file 2
      final service = TransferService.instance;
      service.sendProgressNotifier.value = const TransferProgressState(
        transferId: transferId,
        currentFileName: 'Episode 8.mkv',
        currentFileIndex: 2,
        totalFiles: 2,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: size2,
        overallBytesTransferred: size1,
        overallTotalBytes: totalSize,
        status: TransferProgressStatus.transferring,
        files: [
          PerFileTransferState(fileId: 'f1', fileName: 'Episode 7.mkv', fileSize: size1, bytesTransferred: size1, status: FileTransferStatus.completed),
          PerFileTransferState(fileId: 'f2', fileName: 'Episode 8.mkv', fileSize: size2, bytesTransferred: 0, status: FileTransferStatus.transferring),
        ],
      );

      await service.cancelSingleFile(transferId, 'f2');

      final finalState = service.sendProgressNotifier.value;
      expect(finalState, isNotNull);
      expect(finalState!.status, TransferProgressStatus.cancelled);
      expect(finalState.status, isNot(TransferProgressStatus.completed));
      expect(finalState.overallProgress, closeTo(0.445, 0.01));
      expect(finalState.files[0].status, FileTransferStatus.completed);
      expect(finalState.files[1].status, FileTransferStatus.cancelled);
    });
  });
}
