import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/device_identity_service.dart';

class TransferCancelledException implements Exception {
  const TransferCancelledException([this.message = 'Transfer was cancelled']);
  final String message;
  @override
  String toString() => 'TransferCancelledException: $message';
}

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
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = ((uri) => 'DIRECT');

  final ValueNotifier<PendingTransferRequest?> incomingRequestNotifier =
      ValueNotifier(null);
  final ValueNotifier<TransferProgressState?> progressNotifier =
      ValueNotifier(null);

  final Set<String> _processedTransferIds = {};
  final Set<String> _cancelledTransferIds = {};

  HttpClientRequest? _activeOutgoingRequest;
  IOSink? _activeIncomingSink;
  File? _activeIncomingTempFile;
  HttpRequest? _activeIncomingHttpRequest;
  String? _activeTargetHost;
  int? _activeTargetPort;

  final Map<String, TransferToken> _activeTokens = {};
  final Map<String, Completer<TransferRequestOutcome>> _outgoingRequests = {};
  final Map<String, List<TransferFileItem>> _outgoingFileItems = {};
  final Map<String, PendingTransferRequest> _acceptedRequests = {};
  final Map<String, Set<String>> _receivedFilesPerTransfer = {};

  ValueNotifier<String?> lastSenderMessageNotifier = ValueNotifier(null);

  bool isTransferCancelled(String? transferId) {
    if (transferId == null) return false;
    return _cancelledTransferIds.contains(transferId);
  }

  Future<void> cancelTransfer(String transferId) async {
    if (kDebugMode) {
      debugPrint('[DropLAN TransferService] cancelTransfer called for: $transferId');
    }
    _cancelledTransferIds.add(transferId);

    // 1. Instantly set progress status to cancelled
    final current = progressNotifier.value;
    final cancelledFiles = current?.files.map((f) {
      if (f.status == FileTransferStatus.completed) return f;
      return PerFileTransferState(
        fileId: f.fileId,
        fileName: f.fileName,
        fileSize: f.fileSize,
        bytesTransferred: f.bytesTransferred,
        status: FileTransferStatus.cancelled,
        errorMessage: 'Cancelled',
      );
    }).toList() ?? const [];

    progressNotifier.value = TransferProgressState(
      transferId: transferId,
      currentFileName: current?.currentFileName ?? 'Transfer',
      currentFileIndex: current?.currentFileIndex ?? 1,
      totalFiles: current?.totalFiles ?? 1,
      currentFileBytesTransferred: current?.currentFileBytesTransferred ?? 0,
      currentFileSizeBytes: current?.currentFileSizeBytes ?? 0,
      overallBytesTransferred: current?.overallBytesTransferred ?? 0,
      overallTotalBytes: current?.overallTotalBytes ?? 0,
      status: TransferProgressStatus.cancelled,
      files: cancelledFiles,
      errorMessage: 'Transfer cancelled by user',
    );

    // 2. Abort active outgoing HTTP upload request if present
    if (_activeOutgoingRequest != null) {
      try {
        _activeOutgoingRequest?.abort();
      } catch (e) {
        if (kDebugMode) debugPrint('[DropLAN TransferService] Error aborting outgoing request: $e');
      }
      _activeOutgoingRequest = null;
    }

    // 3. Abort active incoming file sink & temp file if present
    if (_activeIncomingSink != null) {
      try {
        await _activeIncomingSink?.close();
      } catch (_) {}
      _activeIncomingSink = null;
    }

    if (_activeIncomingTempFile != null) {
      try {
        if (await _activeIncomingTempFile?.exists() == true) {
          if (kDebugMode) {
            debugPrint('[DropLAN TransferService] Deleting incomplete temp file on cancel: ${_activeIncomingTempFile?.path}');
          }
          await _activeIncomingTempFile?.delete();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[DropLAN TransferService] Error deleting temp file: $e');
      }
      _activeIncomingTempFile = null;
    }

    if (_activeIncomingHttpRequest != null) {
      try {
        _activeIncomingHttpRequest?.response.statusCode = 499;
        await _activeIncomingHttpRequest?.response.close();
      } catch (_) {}
      _activeIncomingHttpRequest = null;
    }

    // 4. Send cancellation notification HTTP POST to peer device
    final host = _activeTargetHost;
    final port = _activeTargetPort;
    if (host != null && port != null) {
      try {
        final uri = Uri.http('$host:$port', DropLanConfig.transferCancelPath);
        final req = await _client.postUrl(uri);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'transferId': transferId,
          'senderDeviceId': DeviceIdentityService.identity.deviceId,
        }));
        final resp = await req.close();
        await resp.drain();
      } catch (e) {
        if (kDebugMode) debugPrint('[DropLAN TransferService] Peer cancel notify error: $e');
      }
    }
  }

  Future<void> handleCancelNotification(String transferId) async {
    if (kDebugMode) {
      debugPrint('[DropLAN TransferService] Peer notification cancelled transfer: $transferId');
    }
    _cancelledTransferIds.add(transferId);

    if (_activeIncomingSink != null) {
      try {
        await _activeIncomingSink?.close();
      } catch (_) {}
      _activeIncomingSink = null;
    }

    if (_activeIncomingTempFile != null) {
      try {
        if (await _activeIncomingTempFile?.exists() == true) {
          await _activeIncomingTempFile?.delete();
        }
      } catch (_) {}
      _activeIncomingTempFile = null;
    }

    if (_activeOutgoingRequest != null) {
      try {
        _activeOutgoingRequest?.abort();
      } catch (_) {}
      _activeOutgoingRequest = null;
    }

    final current = progressNotifier.value;
    final cancelledFiles = current?.files.map((f) {
      if (f.status == FileTransferStatus.completed) return f;
      return PerFileTransferState(
        fileId: f.fileId,
        fileName: f.fileName,
        fileSize: f.fileSize,
        bytesTransferred: f.bytesTransferred,
        status: FileTransferStatus.cancelled,
        errorMessage: 'Cancelled',
      );
    }).toList() ?? const [];

    progressNotifier.value = TransferProgressState(
      transferId: transferId,
      currentFileName: current?.currentFileName ?? 'Transfer',
      currentFileIndex: current?.currentFileIndex ?? 1,
      totalFiles: current?.totalFiles ?? 1,
      currentFileBytesTransferred: current?.currentFileBytesTransferred ?? 0,
      currentFileSizeBytes: current?.currentFileSizeBytes ?? 0,
      overallBytesTransferred: current?.overallBytesTransferred ?? 0,
      overallTotalBytes: current?.overallTotalBytes ?? 0,
      status: TransferProgressStatus.cancelled,
      files: cancelledFiles,
      errorMessage: 'Transfer cancelled by peer device',
    );
  }

  Future<TransferRequestOutcome> sendTransferRequest({
    required String targetHost,
    required int targetPort,
    required List<Map<String, dynamic>> selectedFileDetails,
    String? localHost,
    int? senderPort,
  }) async {
    final transferId = _generateUuidV4();
    final ownIdentity = DeviceIdentityService.identity;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] MAC TRANSFER START transferId=$transferId time=${DateTime.now().toIso8601String()}');
    }

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
      'senderPort': senderPort ?? DropLanConfig.port,
      'files': fileItems.map((f) => f.toJson()).toList(),
    };

    final completer = Completer<TransferRequestOutcome>();
    _outgoingRequests[transferId] = completer;

    // 35 second fallback timeout for sender
    final timer = Timer(const Duration(seconds: 35), () {
      if (_outgoingRequests.containsKey(transferId)) {
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=TIMEOUT time=${DateTime.now().toIso8601String()}');
        }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Timestamp] MAC REQUEST CONNECT transferId=$transferId uri=$uri time=${DateTime.now().toIso8601String()}');
      }
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));

      final response = await request.close();
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Timestamp] MAC REQUEST BODY SENT transferId=$transferId time=${DateTime.now().toIso8601String()}');
      }
      final responseBody = await utf8.decoder.bind(response).join();

      if (kDebugMode) {
        debugPrint(
            '[DropLAN Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=${response.statusCode} time=${DateTime.now().toIso8601String()}');
      }

      if (response.statusCode != HttpStatus.ok) {
        timer.cancel();
        _outgoingFileItems.remove(transferId);
        _outgoingRequests.remove(transferId);
        return TransferRequestOutcome(
          status: TransferResultStatus.failed,
          message: 'Receiver rejected initial handshake (${response.statusCode}): $responseBody',
        );
      }

      final result = await completer.future;
      timer.cancel();
      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=EXCEPTION error=$e time=${DateTime.now().toIso8601String()}');
      }
      timer.cancel();
      _outgoingFileItems.remove(transferId);
      _outgoingRequests.remove(transferId);
      return TransferRequestOutcome(
        status: TransferResultStatus.failed,
        message: 'Network error: $e',
      );
    }
  }

  List<PerFileTransferState> _buildSenderFileStates(
    List<FileToSend> filesToSend,
    int activeIndex,
    int currentFileSent,
    FileTransferStatus activeStatus, {
    String? errorMessage,
  }) {
    return List<PerFileTransferState>.generate(filesToSend.length, (idx) {
      final f = filesToSend[idx];
      if (idx < activeIndex) {
        return PerFileTransferState(
          fileId: f.fileItem.fileId,
          fileName: f.fileItem.fileName,
          fileSize: f.fileItem.fileSize,
          bytesTransferred: f.fileItem.fileSize,
          status: FileTransferStatus.completed,
        );
      } else if (idx == activeIndex) {
        return PerFileTransferState(
          fileId: f.fileItem.fileId,
          fileName: f.fileItem.fileName,
          fileSize: f.fileItem.fileSize,
          bytesTransferred: currentFileSent,
          status: activeStatus,
          errorMessage: errorMessage,
        );
      } else {
        return PerFileTransferState(
          fileId: f.fileItem.fileId,
          fileName: f.fileItem.fileName,
          fileSize: f.fileItem.fileSize,
          bytesTransferred: 0,
          status: activeStatus == FileTransferStatus.cancelled
              ? FileTransferStatus.cancelled
              : FileTransferStatus.waiting,
        );
      }
    });
  }

  Future<bool> sendTransferFiles({
    required String targetHost,
    required int targetPort,
    required String transferId,
    required String transferToken,
    required List<FileToSend> filesToSend,
  }) async {
    if (isTransferCancelled(transferId)) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Sender] sendTransferFiles called for cancelled transfer $transferId');
      }
      return false;
    }
    _activeTargetHost = targetHost;
    _activeTargetPort = targetPort;

    final overallTotalBytes =
        filesToSend.fold<int>(0, (sum, f) => sum + f.fileItem.fileSize);
    int completedFilesBytes = 0;

    for (int i = 0; i < filesToSend.length; i++) {
      if (isTransferCancelled(transferId)) {
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Transfer $transferId was cancelled before file ${i + 1}');
        }
        _activeOutgoingRequest = null;
        return false;
      }

      final fileToSend = filesToSend[i];
      final fileItem = fileToSend.fileItem;
      final isContentUri = fileToSend.localPath.startsWith('content://');

      if (!isContentUri) {
        final file = File(fileToSend.localPath);
        if (!await file.exists()) {
          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Sender] File not found on sender: ${fileToSend.localPath}');
          }
          if (!isTransferCancelled(transferId)) {
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
          }
          return false;
        }
      }

      if (!isTransferCancelled(transferId)) {
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
          files: _buildSenderFileStates(
              filesToSend, i, 0, FileTransferStatus.transferring),
        );
      }

      try {
        final uri =
            Uri.http('$targetHost:$targetPort', DropLanConfig.transferFilePath);
        if (kDebugMode) {
          debugPrint('[DropLAN Stream Sender] Opening connection to $uri');
          debugPrint(
              '[DropLAN Stream Sender] transferId: $transferId, fileId: ${fileItem.fileId}, fileName: ${fileItem.fileName}, expectedSize: ${fileItem.fileSize}');
        }
        final request = await _client.postUrl(uri);
        _activeOutgoingRequest = request;

        request.headers.contentType = ContentType.binary;
        request.headers.set('authorization', 'Bearer $transferToken');
        request.headers.set('x-transfer-id', transferId);
        request.headers.set('x-file-id', fileItem.fileId);
        request.headers.set(
            'x-file-name', Uri.encodeComponent(fileItem.fileName));
        request.contentLength = fileItem.fileSize;

        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Connection opened. Streaming file data...');
        }

        int currentFileSent = 0;
        int lastProgressUpdateMs = 0;
        final fileStream = _openFileStream(
          fileToSend.localPath,
          transferId,
          (chunkLength) {
            currentFileSent += chunkLength;
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (nowMs - lastProgressUpdateMs >= 50 ||
                currentFileSent == fileItem.fileSize) {
              lastProgressUpdateMs = nowMs;
              if (!isTransferCancelled(transferId)) {
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
                  files: _buildSenderFileStates(
                      filesToSend, i, currentFileSent, FileTransferStatus.transferring),
                );
              }
            }
          },
        );

        await request.addStream(fileStream);
        if (isTransferCancelled(transferId)) {
          request.abort();
          _activeOutgoingRequest = null;
          return false;
        }

        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Finished writing stream to socket. Bytes sent: $currentFileSent / ${fileItem.fileSize}');
        }

        final response = await request.close();
        _activeOutgoingRequest = null;

        if (isTransferCancelled(transferId)) {
          return false;
        }

        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Response HTTP Status: ${response.statusCode}');
        }

        if (response.statusCode != HttpStatus.ok) {
          final responseBody = await utf8.decoder.bind(response).join();
          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Sender] Upload failed status ${response.statusCode}, body: $responseBody');
          }
          if (!isTransferCancelled(transferId)) {
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
              files: _buildSenderFileStates(
                  filesToSend, i, currentFileSent, FileTransferStatus.failed,
                  errorMessage: 'Upload failed (${response.statusCode})'),
            );
          }
          return false;
        }

        await response.drain();
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Connection closed cleanly for ${fileItem.fileName}');
        }

        completedFilesBytes += fileItem.fileSize;
      } catch (e, st) {
        _activeOutgoingRequest = null;

        if (isTransferCancelled(transferId) || e is TransferCancelledException) {
          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Sender] Outgoing transfer cancelled for $transferId');
          }
          return false;
        }

        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Sender] Exception during file upload: $e\n$st');
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
          status: TransferProgressStatus.failed,
          errorMessage: 'Transfer network error: $e',
          files: _buildSenderFileStates(
              filesToSend, i, 0, FileTransferStatus.failed,
              errorMessage: 'Network error'),
        );
        return false;
      }
    }

    if (isTransferCancelled(transferId)) {
      return false;
    }

    final completedFiles = filesToSend.map((f) {
      return PerFileTransferState(
        fileId: f.fileItem.fileId,
        fileName: f.fileItem.fileName,
        fileSize: f.fileItem.fileSize,
        bytesTransferred: f.fileItem.fileSize,
        status: FileTransferStatus.completed,
      );
    }).toList();

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
      files: completedFiles,
    );

    return true;
  }

  Future<Map<String, dynamic>> handleIncomingRequest(
      Map<String, dynamic> body, String clientRemoteHost) async {
    final pendingRequest = PendingTransferRequest.fromJson(body);

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID handleIncomingRequest START transferId=${pendingRequest.transferId} time=${DateTime.now().toIso8601String()}');
    }

    if (pendingRequest.transferId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] REJECTED: transferId is empty');
      }
      return {
        'status': 'rejected',
        'error': 'Transfer ID is empty',
        'code': 'EMPTY_TRANSFER_ID',
      };
    }

    if (_processedTransferIds.contains(pendingRequest.transferId)) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] REJECTED: Duplicate transfer ID ${pendingRequest.transferId}');
      }
      return {
        'status': 'rejected',
        'error': 'Duplicate transfer ID',
        'code': 'BUSY_OR_DUPLICATE',
      };
    }

    if (incomingRequestNotifier.value != null) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] REJECTED: Receiver busy with pending request ${incomingRequestNotifier.value?.transferId}');
      }
      return {
        'status': 'rejected',
        'error': 'Receiver is busy with another incoming transfer',
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

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID incomingRequestNotifier UPDATED transferId=${requestWithHost.transferId} time=${DateTime.now().toIso8601String()}');
    }

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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN] Sending accept to $uri for transferId: $transferId');
      }
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      await res.drain();
      if (kDebugMode) {
        debugPrint(
            '[DropLAN] Accept request completed with status: ${res.statusCode}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[DropLAN] Error sending accept request: $e\n$st');
      }
    }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN] Sending reject to $uri for transferId: $transferId');
      }
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      await res.drain();
      if (kDebugMode) {
        debugPrint(
            '[DropLAN] Reject request completed with status: ${res.statusCode}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[DropLAN] Error sending reject request: $e\n$st');
      }
    }
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
    final clientIp =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final authHeader = request.headers.value('authorization');

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] Connection opened from $clientIp for endpoint ${request.uri.path}');
      request.headers.forEach((name, values) {
        debugPrint(
            '[DropLAN Stream Receiver] Request Header: $name = ${values.join(", ")}');
      });
    }

    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Missing or invalid Authorization header');
      }
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
    final declaredSize = contentLengthHeader != null
        ? int.tryParse(contentLengthHeader) ?? -1
        : -1;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] transferId: $transferId, fileId: $fileId, fileName: $rawFileName, declaredSize: $declaredSize');
    }

    // 1. Check pending accepted request
    final pendingReq = _acceptedRequests[transferId];
    if (pendingReq == null) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Transfer ID $transferId not active or accepted');
      }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Invalid or expired token for fileId $fileId');
      }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Sender device ID mismatch');
      }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Token transfer ID mismatch');
      }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] File ID $fileId not found in transfer metadata');
      }
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
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Filename mismatch: got $rawFileName, expected ${expectedFileItem.fileName}');
      }
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Filename does not match expected metadata',
        'FILENAME_MISMATCH',
      );
      return;
    }

    if (declaredSize != -1 && declaredSize != expectedFileItem.fileSize) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Size mismatch: got $declaredSize, expected ${expectedFileItem.fileSize}');
      }
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Declared content length does not match expected size',
        'SIZE_MISMATCH',
      );
      return;
    }

    final expectedSize = expectedFileItem.fileSize;

    late final File targetFile;
    late final File tempFile;
    late final IOSink sink;

    try {
      // Resolve target file path first to place temp file on the EXACT SAME storage filesystem/volume
      targetFile =
          await _resolveSafeDestinationFile(expectedFileItem.fileName);

      // Create temp file in a .tmp directory INSIDE the same destination directory
      final tempDir = Directory(p.join(targetFile.parent.path, '.tmp'));
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      tempFile =
          File(p.join(tempDir.path, 'droplan_${transferId}_$fileId.tmp'));

      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Temp file path: ${tempFile.path}');
        debugPrint(
            '[DropLAN Stream Receiver] Target destination path: ${targetFile.path}');
      }

      if (await tempFile.exists()) {
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Receiver] Deleting existing stale temp file at ${tempFile.path}');
        }
        await tempFile.delete();
      }

      sink = tempFile.openWrite();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Error setting up destination file/temp file: $e\n$st');
      }
      _setReceiverProgressFailed(
          transferId, 'Could not create destination file: $e');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'Could not create destination file: $e',
        'FILE_CREATION_ERROR',
      );
      return;
    }

    _activeIncomingHttpRequest = request;
    _activeIncomingSink = sink;
    _activeIncomingTempFile = tempFile;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] Opened write sink for ${tempFile.path}');
    }

    int actualBytesReceived = 0;
    bool sizeExceeded = false;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] Start reading request stream for $rawFileName. Expected size: $expectedSize bytes');
    }

    try {
      await for (final chunk in request) {
        if (isTransferCancelled(transferId)) {
          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Receiver] Stream reading aborted for $rawFileName due to cancellation');
          }
          await sink.close();
          _activeIncomingSink = null;
          if (await tempFile.exists()) {
            try {
              await tempFile.delete();
            } catch (_) {}
          }
          _activeIncomingTempFile = null;
          _activeIncomingHttpRequest = null;
          return;
        }

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
      _activeIncomingSink = null;

      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Stream read complete. Expected: $expectedSize, Actual bytes received: $actualBytesReceived');
      }
    } catch (e, st) {
      _activeIncomingSink = null;
      if (isTransferCancelled(transferId)) {
        if (await tempFile.exists()) {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
        _activeIncomingTempFile = null;
        _activeIncomingHttpRequest = null;
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Exception receiving stream for $rawFileName: $e\n$st');
      }

      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      _setReceiverProgressFailed(
          transferId, 'Error receiving stream for $rawFileName: $e');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'Error writing stream: $e',
        'STREAM_ERROR',
      );
      return;
    }

    if (isTransferCancelled(transferId)) {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      _activeIncomingTempFile = null;
      _activeIncomingHttpRequest = null;
      return;
    }

    if (sizeExceeded || actualBytesReceived != expectedSize) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] Byte count mismatch: expected $expectedSize, got $actualBytesReceived (sizeExceeded: $sizeExceeded)');
      }
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      _setReceiverProgressFailed(transferId,
          'Byte count mismatch for $rawFileName: expected $expectedSize, got $actualBytesReceived');
      await _sendErrorResponse(
        request,
        HttpStatus.badRequest,
        'Byte count mismatch: expected $expectedSize, got $actualBytesReceived',
        'BYTE_COUNT_MISMATCH',
      );
      return;
    }

    // Pre-finalization checks
    final tempExists = await tempFile.exists();
    final tempSize = tempExists ? await tempFile.length() : -1;

    if (kDebugMode) {
      debugPrint('[DropLAN Stream Receiver] ANDROID RECEIVE:');
      debugPrint('  transferId=$transferId');
      debugPrint('  file=$rawFileName');
      debugPrint('  expectedBytes=$expectedSize');
      debugPrint('  receivedBytes=$actualBytesReceived');
      debugPrint('  tempPath=${tempFile.path}');
      debugPrint('  tempFileExists=$tempExists');
      debugPrint('  tempFileSize=$tempSize');
      debugPrint('  finalPath=${targetFile.path}');
    }

    if (!tempExists || tempSize != expectedSize || isTransferCancelled(transferId)) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] ANDROID RECEIVE: Pre-finalization verification failed or cancelled');
      }
      if (tempExists) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      if (!isTransferCancelled(transferId)) {
        _setReceiverProgressFailed(transferId,
            'Temporary file size mismatch for $rawFileName: expected $expectedSize, got $tempSize');
        await _sendErrorResponse(
          request,
          HttpStatus.internalServerError,
          'Temporary file size mismatch before finalization',
          'PRE_FINALIZATION_MISMATCH',
        );
      }
      return;
    }

    // Finalization
    String finalizationOp = 'rename';
    Object? finalizationException;

    if (kDebugMode) {
      debugPrint('[DropLAN Stream Receiver] ANDROID RECEIVE: finalization started');
    }

    try {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] ANDROID RECEIVE: finalization operation=tempFile.rename');
      }
      await tempFile.rename(targetFile.path);
    } catch (e) {
      finalizationOp = 'copy_fallback';
      finalizationException = e;
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] ANDROID RECEIVE: finalization operation=copy_fallback (rename failed: $e)');
      }
      try {
        await _copyFileChunked(tempFile, targetFile);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (copyError, copySt) {
        finalizationException = copyError;
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Stream Receiver] ANDROID RECEIVE: finalization exception=$copyError\n$copySt');
        }
      }
    }

    // Ensure temp file is cleaned up
    if (await tempFile.exists()) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }

    if (isTransferCancelled(transferId)) {
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
      return;
    }

    // Post-finalization verification
    final finalExists = await targetFile.exists();
    final finalSize = finalExists ? await targetFile.length() : -1;

    if (kDebugMode) {
      debugPrint('[DropLAN Stream Receiver] ANDROID RECEIVE:');
      debugPrint('  finalization operation=$finalizationOp');
      if (finalizationException != null) {
        debugPrint('  finalization exception=$finalizationException');
      }
      debugPrint('  finalFileExists=$finalExists');
      debugPrint('  finalFileSize=$finalSize');
      debugPrint(
          '  finalization completed=${finalExists && finalSize == expectedSize}');
    }

    if (!finalExists || finalSize != expectedSize) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Stream Receiver] ANDROID RECEIVE: Final file verification failed: exists=$finalExists, expectedSize=$expectedSize, finalSize=$finalSize');
      }
      if (finalExists) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
      _setReceiverProgressFailed(transferId,
          'Final destination file verification failed for $rawFileName');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'File finalization failed: ${finalizationException ?? "Size or existence mismatch"}',
        'FINALIZATION_ERROR',
      );
      return;
    }

    _markFileReceived(
        transferId, fileId, tokenString, pendingReq, targetFile.path);

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'status': 'file_received', 'fileId': fileId}));
    await request.response.close();
    _activeIncomingTempFile = null;
    _activeIncomingHttpRequest = null;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] Connection closed cleanly for fileId $fileId');
    }
  }

  int _lastReceiverUpdateMs = 0;

  List<PerFileTransferState> _buildReceiverFileStates(
    String transferId,
    PendingTransferRequest pendingReq,
    String activeFileId,
    int activeFileBytes,
    FileTransferStatus activeStatus, {
    String? errorMessage,
  }) {
    final alreadyReceivedSet = _receivedFilesPerTransfer[transferId] ?? {};
    final perFileStates = <PerFileTransferState>[];

    for (int i = 0; i < pendingReq.files.length; i++) {
      final f = pendingReq.files[i];
      if (f.fileId == activeFileId) {
        perFileStates.add(PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: activeFileBytes,
          status: activeStatus,
          errorMessage: errorMessage,
        ));
      } else if (alreadyReceivedSet.contains(f.fileId)) {
        perFileStates.add(PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: f.fileSize,
          status: FileTransferStatus.completed,
        ));
      } else {
        perFileStates.add(PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: 0,
          status: activeStatus == FileTransferStatus.cancelled
              ? FileTransferStatus.cancelled
              : FileTransferStatus.waiting,
        ));
      }
    }

    return perFileStates;
  }

  void _updateReceiverProgress({
    required String transferId,
    required String currentFileName,
    required PendingTransferRequest pendingReq,
    required String currentFileId,
    required int currentFileBytes,
    required int currentFileSize,
  }) {
    if (isTransferCancelled(transferId)) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastReceiverUpdateMs < 50 &&
        currentFileBytes < currentFileSize) {
      return;
    }
    _lastReceiverUpdateMs = nowMs;

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
      files: _buildReceiverFileStates(transferId, pendingReq, currentFileId,
          currentFileBytes, FileTransferStatus.transferring),
    );
  }

  void _setReceiverProgressFailed(String transferId, String message) {
    if (isTransferCancelled(transferId)) {
      return;
    }

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
        files: current.files.map((f) {
          if (f.status == FileTransferStatus.transferring) {
            return PerFileTransferState(
              fileId: f.fileId,
              fileName: f.fileName,
              fileSize: f.fileSize,
              bytesTransferred: f.bytesTransferred,
              status: FileTransferStatus.failed,
              errorMessage: message,
            );
          }
          return f;
        }).toList(),
      );
    }
  }

  void _markFileReceived(
    String transferId,
    String fileId,
    String tokenString,
    PendingTransferRequest pendingReq,
    String savedPath,
  ) {
    if (isTransferCancelled(transferId)) {
      return;
    }
    final set = _receivedFilesPerTransfer.putIfAbsent(transferId, () => {});
    set.add(fileId);

    if (set.length >= pendingReq.files.length) {
      // All files in batch received!
      final completedFiles = pendingReq.files.map((f) {
        return PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: f.fileSize,
          status: FileTransferStatus.completed,
        );
      }).toList();

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
        destinationPath: savedPath,
        files: completedFiles,
      );

      // Invalidate token after batch completion
      invalidateToken(tokenString);

      _acceptedRequests.remove(transferId);
      _receivedFilesPerTransfer.remove(transferId);
    }
  }

  Future<void> _copyFileChunked(File source, File destination) async {
    final reader = source.openRead();
    final writer = destination.openWrite();
    try {
      await writer.addStream(reader);
      await writer.flush();
      await writer.close();
    } catch (e) {
      try {
        await writer.close();
      } catch (_) {}
      rethrow;
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
      String baseDownloadsPath = '';
      try {
        final systemDownloads = await getDownloadsDirectory();
        baseDownloadsPath = systemDownloads?.path ?? '';
      } catch (_) {}

      if (baseDownloadsPath.isEmpty) {
        final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
        if (home.isNotEmpty) {
          baseDownloadsPath = p.join(home, 'Downloads');
        }
      }

      if (baseDownloadsPath.isEmpty) {
        baseDownloadsPath = Directory.systemTemp.path;
      }

      downloadsDir = Directory(p.join(baseDownloadsPath, 'DropLAN'));
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

  Stream<List<int>> _openFileStream(
    String path,
    String transferId,
    void Function(int chunkLength) onChunk,
  ) async* {
    if (path.startsWith('content://') && Platform.isAndroid) {
      const channel = MethodChannel('com.example.droplan/uri_stream');
      final String? streamId =
          await channel.invokeMethod<String>('openStream', {'uri': path});

      if (streamId == null) {
        throw Exception('Failed to open content stream for $path');
      }

      try {
        while (!isTransferCancelled(transferId)) {
          final chunk = await channel.invokeMethod<Uint8List>(
              'readChunk', {'streamId': streamId, 'chunkSize': 64 * 1024});
          if (chunk == null || chunk.isEmpty) {
            break;
          }
          onChunk(chunk.length);
          yield chunk;
        }
      } finally {
        await channel.invokeMethod('closeStream', {'streamId': streamId});
      }
    } else {
      final file = File(path);
      await for (final chunk in file.openRead()) {
        if (isTransferCancelled(transferId)) {
          throw const TransferCancelledException();
        }
        onChunk(chunk.length);
        yield chunk;
      }
    }
  }
}
