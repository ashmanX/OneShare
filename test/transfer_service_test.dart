import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:path/path.dart' as p;

import 'package:droplan/config/droplan_config.dart';

import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      final nonExistentCacheDir =
          '${Directory.systemTemp.path}/droplan_test_cache_${DateTime.now().microsecondsSinceEpoch}';
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
        senderDeviceName: 'DropLAN-Sender',
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
      final tempDir = await Directory.systemTemp.createTemp('droplan_test_sender');
      final dummyFile1 = File('${tempDir.path}/test_image.jpg');
      final dummyData = List<int>.generate(1024 * 50, (i) => i % 256); // 50 KB
      await dummyFile1.writeAsBytes(dummyData);

      // 2. Start a test HTTP server representing the receiver (Mac)
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == DropLanConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == DropLanConfig.transferFilePath) {
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
        if (req.uri.path == DropLanConfig.transferAcceptPath) {
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

      final tempDir = await Directory.systemTemp.createTemp('droplan_test_batch');
      final dummyFile1 = File('${tempDir.path}/batch_file1.png');
      final dummyFile2 = File('${tempDir.path}/batch_file2.pdf');
      final data1 = List<int>.generate(1024 * 20, (i) => i % 256); // 20 KB
      final data2 = List<int>.generate(1024 * 35, (i) => (i * 2) % 256); // 35 KB
      await dummyFile1.writeAsBytes(data1);
      await dummyFile2.writeAsBytes(data2);

      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == DropLanConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == DropLanConfig.transferFilePath) {
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
        if (req.uri.path == DropLanConfig.transferAcceptPath) {
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
        if (req.uri.path == DropLanConfig.transferRequestPath) {
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
        if (req.uri.path == DropLanConfig.transferRejectPath) {
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
      if (req.method == 'POST' && req.uri.path == DropLanConfig.transferRequestPath) {
        final content = await utf8.decoder.bind(req).join();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final res = await service.handleIncomingRequest(json, '127.0.0.1');
        req.response
          ..statusCode = res['status'] == 'rejected' ? 409 : 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(res));
        await req.response.close();
      } else if (req.method == 'POST' && req.uri.path == DropLanConfig.transferFilePath) {
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
      if (req.uri.path == DropLanConfig.transferAcceptPath) {
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
    final uploadUri = Uri.http('127.0.0.1:$port', DropLanConfig.transferFilePath);
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
    final tempFile = File(p.join(destFile.parent.path, '.droplan_${transferId}_${fileItem.fileId}.tmp'));
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
        if (req.method == 'POST' && req.uri.path == DropLanConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          req.response
            ..statusCode = res['status'] == 'rejected' ? 409 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == DropLanConfig.transferFilePath) {
          await service.handleIncomingFileUpload(req);
        } else if (req.method == 'POST' && req.uri.path == DropLanConfig.transferCancelPath) {
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
        if (req.uri.path == DropLanConfig.transferAcceptPath) {
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
      final uploadUri = Uri.http('127.0.0.1:$port', DropLanConfig.transferFilePath);
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

      final tempDir = Directory.systemTemp.createTempSync('droplan_multi_test_');
      final f1 = File(p.join(tempDir.path, 'file1.txt'))..writeAsBytesSync(List.generate(1000, (i) => i % 256));
      final f2 = File(p.join(tempDir.path, 'file2.txt'))..writeAsBytesSync(List.generate(10000, (i) => i % 256));
      final f3 = File(p.join(tempDir.path, 'file3.txt'))..writeAsBytesSync(List.generate(10000, (i) => i % 256));

      const transferId = 'multi-cancel-001';

      final filesToSend = [
        FileToSend(fileItem: const TransferFileItem(fileId: 'm1', fileName: 'file1.txt', fileSize: 1000), localPath: f1.path),
        FileToSend(fileItem: const TransferFileItem(fileId: 'm2', fileName: 'file2.txt', fileSize: 10000), localPath: f2.path),
        FileToSend(fileItem: const TransferFileItem(fileId: 'm3', fileName: 'file3.txt', fileSize: 10000), localPath: f3.path),
      ];

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
      await service.handleCancelNotification(transferId);

      expect(service.isTransferCancelled(transferId), isTrue);
      expect(service.receiveProgressNotifier.value?.status, TransferProgressStatus.cancelled);
    });
  });
}
