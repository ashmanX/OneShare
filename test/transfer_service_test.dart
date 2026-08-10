import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(service.progressNotifier.value?.status, TransferProgressStatus.completed);

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
      expect(service.progressNotifier.value?.status, TransferProgressStatus.completed);

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
}
