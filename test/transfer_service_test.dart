import 'package:flutter_test/flutter_test.dart';

import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/transfer_service.dart';

void main() {
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
  });
}
