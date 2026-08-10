import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/device_identity_service.dart';

class FileToSend {
  const FileToSend({
    required this.fileItem,
    required this.localPath,
  });

  final TransferFileItem fileItem;
  final String localPath;
}

class TransferService {
  TransferService._();
  static final TransferService instance = TransferService._();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  final ValueNotifier<PendingTransferRequest?> incomingRequestNotifier =
      ValueNotifier(null);
  final ValueNotifier<TransferProgressState?> progressNotifier =
      ValueNotifier(null);

  final Set<String> _processedTransferIds = {};
  final Map<String, TransferToken> _activeTokens = {};
  final Map<String, Completer<TransferRequestOutcome>> _outgoingRequests = {};
  final Map<String, List<TransferFileItem>> _outgoingFileItems = {};
  final Map<String, PendingTransferRequest> _acceptedRequests = {};
  final Map<String, Set<String>> _receivedFilesPerTransfer = {};

  ValueNotifier<String?> lastSenderMessageNotifier = ValueNotifier(null);

  Future<TransferRequestOutcome> sendTransferRequest({
    required String targetHost,
    required int targetPort,
    required List<Map<String, dynamic>> selectedFileDetails,
    String? localHost,
  }) async {
    final transferId = _generateUuidV4();
    final ownIdentity = DeviceIdentityService.identity;

    final fileItems = selectedFileDetails.map((f) {
      return TransferFileItem(
        fileId: _generateUuidV4(),
        fileName: f['name'] as String? ?? 'file',
        fileSize: f['size'] as int? ?? 0,
      );
    }).toList();

    _outgoingFileItems[transferId] = fileItems;

    final payload = {
      'transferId': transferId,
      'senderDeviceId': ownIdentity.deviceId,
      'senderDeviceName': ownIdentity.deviceName,
      'senderHost': localHost ?? '127.0.0.1',
      'senderPort': DropLanConfig.port,
      'files': fileItems.map((f) => f.toJson()).toList(),
    };

    final completer = Completer<TransferRequestOutcome>();
    _outgoingRequests[transferId] = completer;

    // 35 second fallback timeout for sender
    final timer = Timer(const Duration(seconds: 35), () {
      if (_outgoingRequests.containsKey(transferId)) {
        _outgoingFileItems.remove(transferId);
        _outgoingRequests.remove(transferId)?.complete(
              const TransferRequestOutcome(
                status: TransferResultStatus.expired,
                message: 'Transfer request timed out waiting for response',
              ),
            );
      }
    });

    try {
      final uri =
          Uri.http('$targetHost:$targetPort', DropLanConfig.transferRequestPath);
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        timer.cancel();
        _outgoingFileItems.remove(transferId);
        _outgoingRequests.remove(transferId);
        return const TransferRequestOutcome(
          status: TransferResultStatus.failed,
          message: 'Receiver rejected request initial handshake',
        );
      }

      final result = await completer.future;
      timer.cancel();
      return result;
    } catch (e) {
      timer.cancel();
      _outgoingFileItems.remove(transferId);
      _outgoingRequests.remove(transferId);
      return TransferRequestOutcome(
        status: TransferResultStatus.failed,
        message: 'Network error: $e',
      );
    }
  }

  Future<bool> sendTransferFiles({
    required String targetHost,
    required int targetPort,
    required String transferId,
    required String transferToken,
    required List<FileToSend> filesToSend,
  }) async {
    final overallTotalBytes =
        filesToSend.fold<int>(0, (sum, f) => sum + f.fileItem.fileSize);
    int completedFilesBytes = 0;

    for (int i = 0; i < filesToSend.length; i++) {
      final fileToSend = filesToSend[i];
      final fileItem = fileToSend.fileItem;
      final file = File(fileToSend.localPath);

      if (!await file.exists()) {
        progressNotifier.value = TransferProgressState(
          transferId: transferId,
          currentFileName: fileItem.fileName,
          currentFileIndex: i + 1,
          totalFiles: filesToSend.length,
          currentFileBytesTransferred: 0,
          currentFileSizeBytes: fileItem.fileSize,
          overallBytesTransferred: completedFilesBytes,
          overallTotalBytes: overallTotalBytes,
          status: TransferProgressStatus.failed,
          errorMessage: 'File not found on sender device: ${fileItem.fileName}',
        );
        return false;
      }

      progressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: fileItem.fileName,
        currentFileIndex: i + 1,
        totalFiles: filesToSend.length,
        currentFileBytesTransferred: 0,
        currentFileSizeBytes: fileItem.fileSize,
        overallBytesTransferred: completedFilesBytes,
        overallTotalBytes: overallTotalBytes,
        status: TransferProgressStatus.transferring,
      );

      try {
        final uri =
            Uri.http('$targetHost:$targetPort', DropLanConfig.transferFilePath);
        final request = await _client.postUrl(uri);
        request.headers.contentType = ContentType.binary;
        request.headers.set('authorization', 'Bearer $transferToken');
        request.headers.set('x-transfer-id', transferId);
        request.headers.set('x-file-id', fileItem.fileId);
        request.headers.set(
            'x-file-name', Uri.encodeComponent(fileItem.fileName));
        request.contentLength = fileItem.fileSize;

        int currentFileSent = 0;
        final fileStream = file.openRead();

        await for (final chunk in fileStream) {
          request.add(chunk);
          currentFileSent += chunk.length;
          progressNotifier.value = TransferProgressState(
            transferId: transferId,
            currentFileName: fileItem.fileName,
            currentFileIndex: i + 1,
            totalFiles: filesToSend.length,
            currentFileBytesTransferred: currentFileSent,
            currentFileSizeBytes: fileItem.fileSize,
            overallBytesTransferred: completedFilesBytes + currentFileSent,
            overallTotalBytes: overallTotalBytes,
            status: TransferProgressStatus.transferring,
          );
        }

        final response = await request.close();

        if (response.statusCode != HttpStatus.ok) {
          final responseBody = await utf8.decoder.bind(response).join();
          progressNotifier.value = TransferProgressState(
            transferId: transferId,
            currentFileName: fileItem.fileName,
            currentFileIndex: i + 1,
            totalFiles: filesToSend.length,
            currentFileBytesTransferred: currentFileSent,
            currentFileSizeBytes: fileItem.fileSize,
            overallBytesTransferred: completedFilesBytes + currentFileSent,
            overallTotalBytes: overallTotalBytes,
            status: TransferProgressStatus.failed,
            errorMessage:
                'Upload failed (${response.statusCode}): $responseBody',
          );
          return false;
        }

        completedFilesBytes += fileItem.fileSize;
      } catch (e) {
        progressNotifier.value = TransferProgressState(
          transferId: transferId,
          currentFileName: fileItem.fileName,
          currentFileIndex: i + 1,
          totalFiles: filesToSend.length,
          currentFileBytesTransferred: 0,
          currentFileSizeBytes: fileItem.fileSize,
          overallBytesTransferred: completedFilesBytes,
          overallTotalBytes: overallTotalBytes,
          status: TransferProgressStatus.failed,
          errorMessage: 'Transfer network error: $e',
        );
        return false;
      }
    }

    progressNotifier.value = TransferProgressState(
      transferId: transferId,
      currentFileName: filesToSend.last.fileItem.fileName,
      currentFileIndex: filesToSend.length,
      totalFiles: filesToSend.length,
      currentFileBytesTransferred: filesToSend.last.fileItem.fileSize,
      currentFileSizeBytes: filesToSend.last.fileItem.fileSize,
      overallBytesTransferred: overallTotalBytes,
      overallTotalBytes: overallTotalBytes,
      status: TransferProgressStatus.completed,
    );

    return true;
  }

  Future<Map<String, dynamic>> handleIncomingRequest(
      Map<String, dynamic> body, String clientRemoteHost) async {
    final pendingRequest = PendingTransferRequest.fromJson(body);

    if (pendingRequest.transferId.isEmpty ||
        _processedTransferIds.contains(pendingRequest.transferId) ||
        incomingRequestNotifier.value != null) {
      return {
        'status': 'rejected',
        'error': 'Duplicate transfer ID or busy',
        'code': 'BUSY_OR_DUPLICATE',
      };
    }

    _processedTransferIds.add(pendingRequest.transferId);

    final requestWithHost = PendingTransferRequest(
      transferId: pendingRequest.transferId,
      senderDeviceId: pendingRequest.senderDeviceId,
      senderDeviceName: pendingRequest.senderDeviceName,
      senderHost: pendingRequest.senderHost.isNotEmpty &&
              pendingRequest.senderHost != '127.0.0.1'
          ? pendingRequest.senderHost
          : clientRemoteHost,
      senderPort: pendingRequest.senderPort,
      files: pendingRequest.files,
      receivedAt: DateTime.now(),
    );

    requestWithHost.timer = Timer(const Duration(seconds: 30), () {
      _expireIncomingRequest(requestWithHost.transferId);
    });

    incomingRequestNotifier.value = requestWithHost;

    return {
      'status': 'pending',
      'transferId': requestWithHost.transferId,
    };
  }

  Future<void> acceptIncomingRequest(String transferId) async {
    final request = incomingRequestNotifier.value;
    if (request == null || request.transferId != transferId) return;

    request.timer?.cancel();
    incomingRequestNotifier.value = null;

    final tokenString = _generateSecureToken();
    final allowedFileIds = request.files.map((f) => f.fileId).toSet();

    final token = TransferToken(
      token: tokenString,
      transferId: transferId,
      senderDeviceId: request.senderDeviceId,
      allowedFileIds: allowedFileIds,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );

    _activeTokens[tokenString] = token;
    _acceptedRequests[transferId] = request;

    final payload = {
      'transferId': transferId,
      'receiverDeviceId': DeviceIdentityService.identity.deviceId,
      'transferToken': tokenString,
    };

    try {
      final uri = Uri.http(
        '${request.senderHost}:${request.senderPort}',
        DropLanConfig.transferAcceptPath,
      );
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      await req.close();
    } catch (_) {}
  }

  Future<void> rejectIncomingRequest(String transferId,
      [String reason = 'user_rejected']) async {
    final request = incomingRequestNotifier.value;
    if (request == null || request.transferId != transferId) return;

    request.timer?.cancel();
    incomingRequestNotifier.value = null;

    final payload = {
      'transferId': transferId,
      'receiverDeviceId': DeviceIdentityService.identity.deviceId,
      'reason': reason,
    };

    try {
      final uri = Uri.http(
        '${request.senderHost}:${request.senderPort}',
        DropLanConfig.transferRejectPath,
      );
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      await req.close();
    } catch (_) {}
  }

  void handleAcceptResponse(Map<String, dynamic> body) {
    final transferId = body['transferId'] as String?;
    final token = body['transferToken'] as String?;

    if (transferId != null && _outgoingRequests.containsKey(transferId)) {
      final fileItems = _outgoingFileItems.remove(transferId);
      _outgoingRequests.remove(transferId)?.complete(
            TransferRequestOutcome(
              status: TransferResultStatus.accepted,
              transferId: transferId,
              transferToken: token,
              fileItems: fileItems,
            ),
          );
    }
  }

  void handleRejectResponse(Map<String, dynamic> body) {
    final transferId = body['transferId'] as String?;
    final reason = body['reason'] as String? ?? 'user_rejected';

    if (transferId != null && _outgoingRequests.containsKey(transferId)) {
      _outgoingFileItems.remove(transferId);
      _outgoingRequests.remove(transferId)?.complete(
            TransferRequestOutcome(
              status: reason == 'expired'
                  ? TransferResultStatus.expired
                  : TransferResultStatus.rejected,
              transferId: transferId,
              reason: reason,
            ),
          );
    }
  }

  Future<void> handleIncomingFileUpload(HttpRequest request) async {
    final authHeader = request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      await _sendErrorResponse(
        request,
        HttpStatus.unauthorized,
        'Missing or invalid Authorization header',
        'UNAUTHORIZED',
      );
      return;
    }

    final tokenString = authHeader.substring(7).trim();
    final transferId = request.headers.value('x-transfer-id') ?? '';
    final fileId = request.headers.value('x-file-id') ?? '';
    final rawFileNameHeader = request.headers.value('x-file-name') ?? '';
    final rawFileName = Uri.decodeComponent(rawFileNameHeader);
    final contentLengthHeader = request.headers.value('content-length');
    final declaredSize =
        contentLengthHeader != null ? int.tryParse(contentLengthHeader) ?? -1 : -1;

    // 1. Check pending accepted request
    final pendingReq = _acceptedRequests[transferId];
    if (pendingReq == null) {
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Transfer ID not active or accepted',
        'INVALID_TRANSFER',
      );
      return;
    }

    // 2. Validate token
    final token = validateToken(tokenString, fileId);
    if (token == null) {
      await _sendErrorResponse(
        request,
        HttpStatus.forbidden,
        'Invalid or expired token',
        'INVALID_TOKEN',
      );
      return;
    }

    // 3. Bound sender device ID check
    if (token.senderDeviceId != pendingReq.senderDeviceId) {
      await _sendErrorResponse(
        request,
        HttpStatus.forbidden,
        'Token bound sender device ID mismatch',
        'DEVICE_MISMATCH',
      );
      return;
    }

    // 4. Token transfer ID check
    if (token.transferId != transferId) {
      await _sendErrorResponse(
        request,
        HttpStatus.forbidden,
        'Token transfer ID mismatch',
        'TRANSFER_MISMATCH',
      );
      return;
    }

    // 5. Allowed fileId check
    TransferFileItem? expectedFileItem;
    for (final f in pendingReq.files) {
      if (f.fileId == fileId) {
        expectedFileItem = f;
        break;
      }
    }

    if (expectedFileItem == null) {
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'File ID not found in transfer metadata',
        'UNRECOGNIZED_FILE_ID',
      );
      return;
    }

    // 6. Expected filename & file size checks
    if (rawFileName.isNotEmpty && rawFileName != expectedFileItem.fileName) {
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Filename does not match expected metadata',
        'FILENAME_MISMATCH',
      );
      return;
    }

    if (declaredSize != expectedFileItem.fileSize) {
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Declared content length does not match expected size',
        'SIZE_MISMATCH',
      );
      return;
    }

    final expectedSize = expectedFileItem.fileSize;
    final tempDir = await getTemporaryDirectory();
    final tempFile =
        File('${tempDir.path}/droplan_${transferId}_$fileId.tmp');

    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final sink = tempFile.openWrite();
    int actualBytesReceived = 0;
    bool sizeExceeded = false;

    try {
      await for (final chunk in request) {
        actualBytesReceived += chunk.length;
        if (actualBytesReceived > expectedSize) {
          sizeExceeded = true;
          break;
        }
        sink.add(chunk);

        _updateReceiverProgress(
          transferId: transferId,
          currentFileName: expectedFileItem.fileName,
          pendingReq: pendingReq,
          currentFileId: fileId,
          currentFileBytes: actualBytesReceived,
          currentFileSize: expectedSize,
        );
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      _setReceiverProgressFailed(
          transferId, 'Error receiving stream for $rawFileName');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'Error writing stream: $e',
        'STREAM_ERROR',
      );
      return;
    }

    if (sizeExceeded || actualBytesReceived != expectedSize) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      _setReceiverProgressFailed(
          transferId, 'Byte count mismatch for $rawFileName');
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Byte count mismatch: expected $expectedSize, got $actualBytesReceived',
        'BYTE_COUNT_MISMATCH',
      );
      return;
    }

    // Save to target destination safely
    final targetFile =
        await _resolveSafeDestinationFile(expectedFileItem.fileName);
    try {
      await tempFile.rename(targetFile.path);
    } catch (_) {
      await tempFile.copy(targetFile.path);
      await tempFile.delete();
    }

    _markFileReceived(transferId, fileId, tokenString, pendingReq);

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'status': 'file_received', 'fileId': fileId}));
    await request.response.close();
  }

  void _updateReceiverProgress({
    required String transferId,
    required String currentFileName,
    required PendingTransferRequest pendingReq,
    required String currentFileId,
    required int currentFileBytes,
    required int currentFileSize,
  }) {
    final alreadyReceivedSet = _receivedFilesPerTransfer[transferId] ?? {};
    int completedBytes = 0;
    int currentFileIndex = 1;

    for (int i = 0; i < pendingReq.files.length; i++) {
      final f = pendingReq.files[i];
      if (f.fileId == currentFileId) {
        currentFileIndex = i + 1;
      } else if (alreadyReceivedSet.contains(f.fileId)) {
        completedBytes += f.fileSize;
      }
    }

    progressNotifier.value = TransferProgressState(
      transferId: transferId,
      currentFileName: currentFileName,
      currentFileIndex: currentFileIndex,
      totalFiles: pendingReq.files.length,
      currentFileBytesTransferred: currentFileBytes,
      currentFileSizeBytes: currentFileSize,
      overallBytesTransferred: completedBytes + currentFileBytes,
      overallTotalBytes: pendingReq.totalSize,
      status: TransferProgressStatus.transferring,
    );
  }

  void _setReceiverProgressFailed(String transferId, String message) {
    final current = progressNotifier.value;
    if (current != null) {
      progressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: current.currentFileName,
        currentFileIndex: current.currentFileIndex,
        totalFiles: current.totalFiles,
        currentFileBytesTransferred: current.currentFileBytesTransferred,
        currentFileSizeBytes: current.currentFileSizeBytes,
        overallBytesTransferred: current.overallBytesTransferred,
        overallTotalBytes: current.overallTotalBytes,
        status: TransferProgressStatus.failed,
        errorMessage: message,
      );
    }
  }

  void _markFileReceived(
    String transferId,
    String fileId,
    String tokenString,
    PendingTransferRequest pendingReq,
  ) {
    final set = _receivedFilesPerTransfer.putIfAbsent(transferId, () => {});
    set.add(fileId);

    if (set.length >= pendingReq.files.length) {
      // All files in batch received!
      progressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: pendingReq.files.last.fileName,
        currentFileIndex: pendingReq.files.length,
        totalFiles: pendingReq.files.length,
        currentFileBytesTransferred: pendingReq.files.last.fileSize,
        currentFileSizeBytes: pendingReq.files.last.fileSize,
        overallBytesTransferred: pendingReq.totalSize,
        overallTotalBytes: pendingReq.totalSize,
        status: TransferProgressStatus.completed,
      );

      // Invalidate token after batch completion
      invalidateToken(tokenString);

      _acceptedRequests.remove(transferId);
      _receivedFilesPerTransfer.remove(transferId);
    }
  }

  Future<File> _resolveSafeDestinationFile(String rawFileName) async {
    String baseName = p.basename(rawFileName);
    if (baseName.isEmpty) {
      baseName = 'downloaded_file';
    }

    final sanitized = baseName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');

    Directory downloadsDir;
    if (Platform.isAndroid) {
      downloadsDir = Directory('/storage/emulated/0/Download/DropLAN');
    } else {
      final systemDownloads = await getDownloadsDirectory();
      downloadsDir = Directory(
          '${systemDownloads?.path ?? Directory.systemTemp.path}/DropLAN');
    }

    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }

    String fileNameNoExt = p.basenameWithoutExtension(sanitized);
    String ext = p.extension(sanitized);
    if (fileNameNoExt.isEmpty) {
      fileNameNoExt = 'file';
    }

    String finalPath = p.join(downloadsDir.path, '$fileNameNoExt$ext');
    File targetFile = File(finalPath);
    int counter = 1;

    while (await targetFile.exists()) {
      finalPath = p.join(downloadsDir.path, '$fileNameNoExt ($counter)$ext');
      targetFile = File(finalPath);
      counter++;
    }

    return targetFile;
  }

  Future<void> _sendErrorResponse(
    HttpRequest request,
    int statusCode,
    String message,
    String code,
  ) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': message, 'code': code}));
    await request.response.close();
  }

  void _expireIncomingRequest(String transferId) {
    if (incomingRequestNotifier.value?.transferId == transferId) {
      rejectIncomingRequest(transferId, 'expired');
    }
  }

  TransferToken? validateToken(String tokenString, String fileId) {
    final token = _activeTokens[tokenString];
    if (token == null || token.isExpired) {
      _activeTokens.remove(tokenString);
      return null;
    }

    if (!token.allowedFileIds.contains(fileId)) {
      return null;
    }

    return token;
  }

  void invalidateToken(String tokenString) {
    _activeTokens.remove(tokenString);
  }

  String _generateSecureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'tok_sec_$hex';
  }

  String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int v) => v.toRadixString(16).padLeft(2, '0');
    final parts = bytes.map(hex).toList();
    return '${parts.sublist(0, 4).join()}-'
        '${parts.sublist(4, 6).join()}-'
        '${parts.sublist(6, 8).join()}-'
        '${parts.sublist(8, 10).join()}-'
        '${parts.sublist(10, 16).join()}';
  }
}
