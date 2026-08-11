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

  // BUG-11 FIX: Split into separate sender/receiver notifiers so simultaneous
  // send+receive operations do not overwrite each other's progress display.
  final ValueNotifier<TransferProgressState?> sendProgressNotifier =
      ValueNotifier(null);
  final ValueNotifier<TransferProgressState?> receiveProgressNotifier =
      ValueNotifier(null);

  // BUG-07 FIX: Use LinkedHashSet so we can evict oldest entries when the
  // sets grow beyond the max cap, preventing unbounded memory growth.
  final _processedTransferIds = <String>{};
  final _cancelledTransferIds = <String>{};
  static const int _maxIdSetSize = 500;
  static const int _idSetEvictCount = 100;

  void _addProcessedId(String id) {
    if (_processedTransferIds.length >= _maxIdSetSize) {
      final toRemove = _processedTransferIds.take(_idSetEvictCount).toList();
      _processedTransferIds.removeAll(toRemove);
    }
    _processedTransferIds.add(id);
  }

  void _addCancelledId(String id) {
    if (_cancelledTransferIds.length >= _maxIdSetSize) {
      final toRemove = _cancelledTransferIds.take(_idSetEvictCount).toList();
      _cancelledTransferIds.removeAll(toRemove);
    }
    _cancelledTransferIds.add(id);
  }

  HttpClientRequest? _activeOutgoingRequest;
  IOSink? _activeIncomingSink;
  File? _activeIncomingTempFile;
  HttpRequest? _activeIncomingHttpRequest;
  String? _activeTargetHost;
  int? _activeTargetPort;

  // BUG-01 FIX: Completer used to cancel a pending outgoing transfer request
  // before the 35-second timeout fires.
  Completer<TransferRequestOutcome>? _outgoingCancelCompleter;

  final Map<String, TransferToken> _activeTokens = {};
  final Map<String, Completer<TransferRequestOutcome>> _outgoingRequests = {};
  final Map<String, List<TransferFileItem>> _outgoingFileItems = {};
  final Map<String, PendingTransferRequest> _acceptedRequests = {};
  final Map<String, Set<String>> _receivedFilesPerTransfer = {};

  ValueNotifier<String?> lastSenderMessageNotifier = ValueNotifier(null);

  final Map<String, Set<String>> _cancelledFileIdsPerTransfer = {};

  bool isTransferCancelled(String? transferId) {
    if (transferId == null) return false;
    return _cancelledTransferIds.contains(transferId);
  }

  bool isFileCancelled(String? transferId, String? fileId) {
    if (transferId == null || fileId == null) return false;
    if (isTransferCancelled(transferId)) return true;
    final set = _cancelledFileIdsPerTransfer[transferId];
    return set != null && set.contains(fileId);
  }

  Future<void> cancelSingleFile(String transferId, String fileId) async {
    if (kDebugMode) {
      debugPrint(
          '[DropLAN TransferService] cancelSingleFile called for: transferId=$transferId, fileId=$fileId');
    }
    final set = _cancelledFileIdsPerTransfer.putIfAbsent(transferId, () => {});
    set.add(fileId);

    // 1. Notify peer about single file cancellation
    final host = _activeTargetHost;
    final port = _activeTargetPort;
    if (host != null && port != null) {
      try {
        final uri = Uri.http('$host:$port', DropLanConfig.transferCancelFilePath);
        final req = await _client.postUrl(uri);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'transferId': transferId,
          'fileId': fileId,
          'senderDeviceId': DeviceIdentityService.identity.deviceId,
        }));
        final resp = await req.close();
        await resp.drain();
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
              '[DropLAN TransferService] Peer file cancel notify error: $e');
        }
      }
    }

    _abortIfActiveFile(transferId, fileId);
    _updateNotifiersForFileCancel(transferId, fileId);
  }

  Future<void> handleCancelFileNotification(
      String transferId, String fileId) async {
    if (kDebugMode) {
      debugPrint(
          '[DropLAN TransferService] Peer notification cancelled file: transferId=$transferId, fileId=$fileId');
    }
    final set = _cancelledFileIdsPerTransfer.putIfAbsent(transferId, () => {});
    set.add(fileId);

    _abortIfActiveFile(transferId, fileId);
    _updateNotifiersForFileCancel(transferId, fileId);
  }

  void _abortIfActiveFile(String transferId, String fileId) {
    final currentRecv = receiveProgressNotifier.value;
    if (currentRecv != null && currentRecv.transferId == transferId) {
      for (final f in currentRecv.files) {
        if (f.fileId == fileId && f.status == FileTransferStatus.transferring) {
          try {
            _activeIncomingSink?.close();
          } catch (_) {}
          _activeIncomingSink = null;

          if (_activeIncomingTempFile != null) {
            try {
              _activeIncomingTempFile?.delete();
            } catch (_) {}
            _activeIncomingTempFile = null;
          }

          try {
            _activeIncomingHttpRequest?.response.detachSocket().then((s) => s.destroy());
          } catch (_) {}
          _activeIncomingHttpRequest = null;
        }
      }
    }

    final currentSend = sendProgressNotifier.value;
    if (currentSend != null && currentSend.transferId == transferId) {
      for (final f in currentSend.files) {
        if (f.fileId == fileId && f.status == FileTransferStatus.transferring) {
          try {
            _activeOutgoingRequest?.abort();
          } catch (_) {}
          _activeOutgoingRequest = null;
        }
      }
    }
  }

  void _updateNotifiersForFileCancel(String transferId, String fileId) {
    final sendVal = sendProgressNotifier.value;
    if (sendVal != null && sendVal.transferId == transferId) {
      final updatedFiles = sendVal.files.map((f) {
        if (f.fileId == fileId) {
          return PerFileTransferState(
            fileId: f.fileId,
            fileName: f.fileName,
            fileSize: f.fileSize,
            bytesTransferred: 0,
            status: FileTransferStatus.cancelled,
            errorMessage: 'Cancelled',
          );
        }
        return f;
      }).toList();

      final allTerminal = updatedFiles.every((f) =>
          f.status == FileTransferStatus.completed ||
          f.status == FileTransferStatus.cancelled ||
          f.status == FileTransferStatus.failed);

      final hasCompleted =
          updatedFiles.any((f) => f.status == FileTransferStatus.completed);

      sendProgressNotifier.value = TransferProgressState(
        transferId: sendVal.transferId,
        currentFileName: sendVal.currentFileName,
        currentFileIndex: sendVal.currentFileIndex,
        totalFiles: sendVal.totalFiles,
        currentFileBytesTransferred: sendVal.currentFileBytesTransferred,
        currentFileSizeBytes: sendVal.currentFileSizeBytes,
        overallBytesTransferred: sendVal.overallBytesTransferred,
        overallTotalBytes: sendVal.overallTotalBytes,
        status: allTerminal
            ? (hasCompleted
                ? TransferProgressStatus.completed
                : TransferProgressStatus.cancelled)
            : sendVal.status,
        files: updatedFiles,
        errorMessage: sendVal.errorMessage,
        destinationPath: sendVal.destinationPath,
      );
    }

    final recvVal = receiveProgressNotifier.value;
    if (recvVal != null && recvVal.transferId == transferId) {
      final updatedFiles = recvVal.files.map((f) {
        if (f.fileId == fileId) {
          return PerFileTransferState(
            fileId: f.fileId,
            fileName: f.fileName,
            fileSize: f.fileSize,
            bytesTransferred: 0,
            status: FileTransferStatus.cancelled,
            errorMessage: 'Cancelled',
          );
        }
        return f;
      }).toList();

      final allTerminal = updatedFiles.every((f) =>
          f.status == FileTransferStatus.completed ||
          f.status == FileTransferStatus.cancelled ||
          f.status == FileTransferStatus.failed);

      final hasCompleted =
          updatedFiles.any((f) => f.status == FileTransferStatus.completed);

      receiveProgressNotifier.value = TransferProgressState(
        transferId: recvVal.transferId,
        currentFileName: recvVal.currentFileName,
        currentFileIndex: recvVal.currentFileIndex,
        totalFiles: recvVal.totalFiles,
        currentFileBytesTransferred: recvVal.currentFileBytesTransferred,
        currentFileSizeBytes: recvVal.currentFileSizeBytes,
        overallBytesTransferred: recvVal.overallBytesTransferred,
        overallTotalBytes: recvVal.overallTotalBytes,
        status: allTerminal
            ? (hasCompleted
                ? TransferProgressStatus.completed
                : TransferProgressStatus.cancelled)
            : recvVal.status,
        files: updatedFiles,
        errorMessage: recvVal.errorMessage,
        destinationPath: recvVal.destinationPath,
      );
    }
  }

  // ──────────────────────────────────────────────────────────
  // BUG-01 FIX: Cancel an outgoing request that is waiting for acceptance.
  // ──────────────────────────────────────────────────────────

  /// Cancels an outgoing transfer request that is currently waiting for the
  /// receiver to accept/reject. This resolves [sendTransferRequest]'s future
  /// immediately with a [cancelled] outcome instead of waiting 35 seconds,
  /// and sends an HTTP POST cancel notification to the peer so their incoming
  /// dialog auto-dismisses.
  void cancelOutgoingRequest([String? transferId]) {
    final targetId = (transferId != null && transferId.isNotEmpty)
        ? transferId
        : _outgoingRequests.keys.firstOrNull;

    final host = _activeTargetHost;
    final port = _activeTargetPort;
    if (targetId != null && host != null && port != null) {
      _sendCancelNotificationToPeer(host, port, targetId);
    }

    final cancelCompleter = _outgoingCancelCompleter;
    if (cancelCompleter != null && !cancelCompleter.isCompleted) {
      cancelCompleter.complete(
        const TransferRequestOutcome(
          status: TransferResultStatus.failed,
          message: 'Transfer request cancelled by user',
        ),
      );
    }
    // Also complete any pending completer waiting on accept/reject
    if (targetId != null && _outgoingRequests.containsKey(targetId)) {
      _outgoingFileItems.remove(targetId);
      _outgoingRequests.remove(targetId)?.complete(
            const TransferRequestOutcome(
              status: TransferResultStatus.failed,
              message: 'Transfer request cancelled by user',
            ),
          );
    }
  }

  Future<void> _sendCancelNotificationToPeer(
      String host, int port, String transferId) async {
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
      if (kDebugMode) {
        debugPrint('[DropLAN TransferService] Peer cancel notify error: $e');
      }
    }
  }

  // ──────────────────────────────────────────────────────────
  // Cancel transfer
  // ──────────────────────────────────────────────────────────

  Future<void> cancelTransfer(String transferId) async {
    if (kDebugMode) {
      debugPrint('[DropLAN TransferService] cancelTransfer called for: $transferId');
    }
    _addCancelledId(transferId);

    // BUG-08 FIX: Clean up _acceptedRequests and _activeTokens on cancel so
    // stale tokens cannot be used after a transfer is cancelled.
    _cleanupTransferState(transferId);

    // 1. Instantly set progress status to cancelled on the SENDER notifier.
    final current = sendProgressNotifier.value;
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

    sendProgressNotifier.value = TransferProgressState(
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

    // BUG-04 FIX: Send cancel notification to peer BEFORE aborting the local
    // HTTP request. This gives the receiver a chance to set the "cancelled"
    // state before the connection drop triggers a "failed" state.
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

    // 2. Abort active outgoing HTTP upload request if present.
    if (_activeOutgoingRequest != null) {
      try {
        _activeOutgoingRequest?.abort();
      } catch (e) {
        if (kDebugMode) debugPrint('[DropLAN TransferService] Error aborting outgoing request: $e');
      }
      _activeOutgoingRequest = null;
    }

    // 3. Abort active incoming file sink & temp file if present.
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
  }

  /// Cleans up per-transfer state (accepted request entry + token).
  /// Called on both cancel and normal completion to prevent leaks.
  void _cleanupTransferState(String transferId) {
    // BUG-08 FIX: Remove acceptedRequest entry.
    _acceptedRequests.remove(transferId);

    // BUG-08 FIX: Find and invalidate the token for this transfer.
    final tokenKey = _activeTokens.entries
        .where((e) => e.value.transferId == transferId)
        .map((e) => e.key)
        .firstOrNull;
    if (tokenKey != null) {
      _activeTokens.remove(tokenKey);
    }
  }

  Future<void> handleCancelNotification(String transferId) async {
    if (kDebugMode) {
      debugPrint('[DropLAN TransferService] Peer notification cancelled transfer: $transferId');
    }
    _addCancelledId(transferId);

    // If an incoming request dialog is open on this device for this transferId,
    // cancel its timer and clear the notifier so the dialog auto-dismisses.
    if (incomingRequestNotifier.value?.transferId == transferId) {
      incomingRequestNotifier.value?.timer?.cancel();
      incomingRequestNotifier.value = null;
    }

    // BUG-08 FIX: Clean up receiver-side state on peer cancel.
    _cleanupTransferState(transferId);

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

    // Update the RECEIVER progress notifier on cancel notification.
    final current = receiveProgressNotifier.value;
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

    receiveProgressNotifier.value = TransferProgressState(
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
    _activeTargetHost = targetHost;
    _activeTargetPort = targetPort;
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

    // BUG-01 FIX: Set up the cancel completer so cancelOutgoingRequest() can
    // resolve this future immediately without waiting for the 35s timeout.
    final cancelCompleter = Completer<TransferRequestOutcome>();
    _outgoingCancelCompleter = cancelCompleter;

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
        _outgoingCancelCompleter = null;
        _outgoingFileItems.remove(transferId);
        _outgoingRequests.remove(transferId);
        return TransferRequestOutcome(
          status: TransferResultStatus.failed,
          message: 'Receiver rejected initial handshake (${response.statusCode}): $responseBody',
        );
      }

      // BUG-01 FIX: Race the response completer against the cancel completer.
      // Whichever fires first wins.
      final result = await Future.any([
        completer.future,
        cancelCompleter.future,
      ]);
      timer.cancel();
      _outgoingCancelCompleter = null;
      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=EXCEPTION error=$e time=${DateTime.now().toIso8601String()}');
      }
      timer.cancel();
      _outgoingCancelCompleter = null;
      _outgoingFileItems.remove(transferId);
      _outgoingRequests.remove(transferId);
      return TransferRequestOutcome(
        status: TransferResultStatus.failed,
        message: 'Network error: $e',
      );
    }
  }

  List<PerFileTransferState> _buildSenderFileStates(
    String transferId,
    List<FileToSend> filesToSend,
    int activeIndex,
    int currentFileSent,
    FileTransferStatus activeStatus, {
    String? errorMessage,
  }) {
    return List<PerFileTransferState>.generate(filesToSend.length, (idx) {
      final f = filesToSend[idx];
      if (isFileCancelled(transferId, f.fileItem.fileId)) {
        return PerFileTransferState(
          fileId: f.fileItem.fileId,
          fileName: f.fileItem.fileName,
          fileSize: f.fileItem.fileSize,
          bytesTransferred: 0,
          status: FileTransferStatus.cancelled,
          errorMessage: 'Cancelled',
        );
      } else if (idx < activeIndex) {
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

    try {
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

        if (isFileCancelled(transferId, fileItem.fileId)) {
          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Sender] File ${fileItem.fileName} was cancelled, skipping.');
          }
          continue;
        }

        final isContentUri = fileToSend.localPath.startsWith('content://');

        if (!isContentUri) {
          final file = File(fileToSend.localPath);
          if (!await file.exists()) {
            if (kDebugMode) {
              debugPrint(
                  '[DropLAN Stream Sender] File not found on sender: ${fileToSend.localPath}');
            }
            if (!isTransferCancelled(transferId)) {
              sendProgressNotifier.value = TransferProgressState(
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
          sendProgressNotifier.value = TransferProgressState(
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
                transferId, filesToSend, i, 0, FileTransferStatus.transferring),
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
                if (!isTransferCancelled(transferId) &&
                    !isFileCancelled(transferId, fileItem.fileId)) {
                  sendProgressNotifier.value = TransferProgressState(
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
                        transferId, filesToSend, i, currentFileSent, FileTransferStatus.transferring),
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

          if (isFileCancelled(transferId, fileItem.fileId)) {
            request.abort();
            _activeOutgoingRequest = null;
            continue;
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

          if (isFileCancelled(transferId, fileItem.fileId)) {
            continue;
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
            if (!isTransferCancelled(transferId) &&
                !isFileCancelled(transferId, fileItem.fileId)) {
              sendProgressNotifier.value = TransferProgressState(
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
                    transferId, filesToSend, i, currentFileSent, FileTransferStatus.failed,
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

          if (isFileCancelled(transferId, fileItem.fileId)) {
            if (kDebugMode) {
              debugPrint(
                  '[DropLAN Stream Sender] File ${fileItem.fileName} was cancelled, continuing to next.');
            }
            continue;
          }

          if (kDebugMode) {
            debugPrint(
                '[DropLAN Stream Sender] Exception during file upload: $e\n$st');
          }
          sendProgressNotifier.value = TransferProgressState(
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
                transferId, filesToSend, i, 0, FileTransferStatus.failed,
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

      sendProgressNotifier.value = TransferProgressState(
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
    } finally {
      // BUG-22 FIX: Always clear _activeTargetHost/Port after a transfer ends
      // (success, failure, or cancellation) to prevent stale cancel
      // notifications being sent to the wrong peer on the next transfer.
      _activeTargetHost = null;
      _activeTargetPort = null;
    }
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

    _addProcessedId(pendingRequest.transferId);

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

      // BUG-05/06 FIX: If the sender returns 410 Gone, the request was
      // accepted too late. Clean up receiver state and notify the user.
      if (res.statusCode == HttpStatus.gone) {
        if (kDebugMode) {
          debugPrint('[DropLAN] Sender returned 410 — request expired. Cleaning up receiver state.');
        }
        _cleanupTransferState(transferId);
        receiveProgressNotifier.value = TransferProgressState(
          transferId: transferId,
          currentFileName: 'Transfer',
          currentFileIndex: 1,
          totalFiles: request.files.length,
          currentFileBytesTransferred: 0,
          currentFileSizeBytes: 0,
          overallBytesTransferred: 0,
          overallTotalBytes: request.totalSize,
          status: TransferProgressStatus.failed,
          errorMessage: 'The sender is no longer waiting — request expired.',
        );
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

  /// Handles an accept response from the receiver.
  /// Returns [true] if the accept was processed, [false] if the request had
  /// already timed out (BUG-05/06 fix — caller should respond with HTTP 410).
  bool handleAcceptResponse(Map<String, dynamic> body) {
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
      return true;
    }
    // BUG-05/06: Transfer already timed out — signal the HTTP layer to 410.
    return false;
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

    // 6. Expected filename check
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

    // 7. Size check — BUG-12 FIX: Skip the pre-flight content-length check
    // when expectedFileItem.fileSize == 0 (e.g. cloud files whose size was
    // not known at selection time). The actual byte-count check after the
    // stream is complete serves as the real guard for known-size files.
    if (expectedFileItem.fileSize > 0 &&
        declaredSize != -1 &&
        declaredSize != expectedFileItem.fileSize) {
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

    // BUG-12 FIX: When expectedSize is 0 (unknown at selection time), use the
    // declared content-length as the authoritative expected size so the
    // byte-count verification after the stream will pass.
    final expectedSize = (expectedFileItem.fileSize == 0 && declaredSize > 0)
        ? declaredSize
        : expectedFileItem.fileSize;

    late final File targetFile;
    late final File tempFile;
    late final IOSink sink;

    try {
      // Resolve target file path first to place temp file in the EXACT SAME destination directory
      targetFile =
          await _resolveSafeDestinationFile(expectedFileItem.fileName);

      // Create temp file directly in the destination directory with a hidden dot prefix.
      // Keeping tempFile and targetFile in the exact same directory guarantees that
      // tempFile.rename() is an instant, atomic OS inode operation (0ms, 0 extra disk I/O, 0 memory allocated).
      tempFile =
          File(p.join(targetFile.parent.path, '.droplan_${transferId}_$fileId.tmp'));

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
    int unflushedBytes = 0;
    const flushThreshold = 2 * 1024 * 1024; // 2 MB backpressure threshold
    bool sizeExceeded = false;

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Stream Receiver] Start reading request stream for $rawFileName. Expected size: $expectedSize bytes');
    }

    try {
      await for (final chunk in request) {
        if (isTransferCancelled(transferId) || isFileCancelled(transferId, fileId)) {
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
        unflushedBytes += chunk.length;

        // Only enforce the size ceiling when the expected size is known (> 0).
        if (expectedSize > 0 && actualBytesReceived > expectedSize) {
          sizeExceeded = true;
          break;
        }
        sink.add(chunk);

        // Periodically flush sink every 2MB to apply backpressure on socket stream,
        // preventing RAM buffers from expanding infinitely during multi-gigabyte transfers.
        if (unflushedBytes >= flushThreshold) {
          unflushedBytes = 0;
          await sink.flush();
        }

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

    // BUG-12 FIX: For files with known size, verify byte count. For
    // expectedSize==0 (unknown at selection time but stream EOF reached), skip
    // the strict equality check — accept whatever was received.
    if (sizeExceeded || (expectedSize > 0 && actualBytesReceived != expectedSize)) {
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

    // BUG-12 FIX: For size=0 expected (unknown-size cloud files), skip the
    // pre-finalization size comparison.
    final prefinalizationOk = tempExists &&
        (expectedSize == 0 || tempSize == expectedSize) &&
        !isTransferCancelled(transferId);

    if (!prefinalizationOk) {
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
          '  finalization completed=${finalExists && (expectedSize == 0 || finalSize == expectedSize)}');
    }

    // BUG-12 FIX: For expected size 0, accept any non-empty (or zero-byte)
    // final file. For known sizes, verify exact match.
    final finalVerificationOk = finalExists &&
        (expectedSize == 0 || finalSize == expectedSize);

    if (!finalVerificationOk) {
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
      if (isFileCancelled(transferId, f.fileId)) {
        perFileStates.add(PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: 0,
          status: FileTransferStatus.cancelled,
          errorMessage: 'Cancelled',
        ));
      } else if (f.fileId == activeFileId) {
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

    // BUG-11 FIX: Write receiver updates to the dedicated receiveProgressNotifier.
    receiveProgressNotifier.value = TransferProgressState(
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

    final current = receiveProgressNotifier.value;
    if (current != null) {
      // BUG-11 FIX: Write to receiveProgressNotifier.
      receiveProgressNotifier.value = TransferProgressState(
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

      // BUG-11 FIX: Write completion to receiveProgressNotifier.
      receiveProgressNotifier.value = TransferProgressState(
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

      // Invalidate token after batch completion.
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
