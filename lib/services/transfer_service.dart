import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/models/transfer_models.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/encrypted_stream.dart';
import 'package:oneshare/services/crypto/log_sanitizer.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';

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

  // SESSION-SCOPED I/O: All I/O handles are keyed by transferId so
  // concurrent send+receive operations never collide.
  final Map<String, HttpClientRequest?> _activeOutgoingRequests = {};
  final Map<String, IOSink?> _activeIncomingSinks = {};
  final Map<String, File?> _activeIncomingTempFiles = {};
  final Map<String, HttpRequest?> _activeIncomingHttpRequests = {};
  final Map<String, String> _transferTargetHost = {};
  final Map<String, int> _transferTargetPort = {};

  final Map<String, int> _activeSenderCurrentFileBytes = {};

  // SESSION-SCOPED cancel completers: keyed by transferId so cancelling one
  // outgoing request doesn't affect another.
  final Map<String, Completer<TransferRequestOutcome>> _outgoingCancelCompleters = {};

  final Map<String, TransferToken> _activeTokens = {};
  final Map<String, Completer<TransferRequestOutcome>> _outgoingRequests = {};
  final Map<String, List<TransferFileItem>> _outgoingFileItems = {};
  final Map<String, PendingTransferRequest> _acceptedRequests = {};
  final Map<String, Set<String>> _receivedFilesPerTransfer = {};

  final Map<String, E2eeSession> _outgoingE2eeSessions = {};
  final Map<String, E2eeSession> _incomingE2eeSessions = {};
  final Set<String> _completedHandshakeTransferIds = <String>{};
  static const int _maxHandshakeIdSetSize = 500;
  static const int _handshakeIdSetEvictCount = 100;
  final Map<String, Completer<void>> _transferLocks = {};

  /// Acquires the shared per-transfer lifecycle lock to serialize control processing,
  /// full cancellation, single-file cancellation, and session cleanup.
  Future<T> synchronizedTransfer<T>(String transferId, Future<T> Function() block) async {
    while (_transferLocks.containsKey(transferId)) {
      await _transferLocks[transferId]!.future;
    }
    final completer = Completer<void>();
    _transferLocks[transferId] = completer;
    try {
      return await block();
    } finally {
      _transferLocks.remove(transferId);
      completer.complete();
    }
  }

  /// Whether the transfer has ever derived keys or completed its E2EE handshake.
  bool hasCompletedHandshake(String transferId) {
    if (_completedHandshakeTransferIds.contains(transferId)) return true;
    final session = getSession(transferId);
    return session != null &&
        (session.state == E2eeSessionState.keysDerived ||
            session.state == E2eeSessionState.active ||
            session.state == E2eeSessionState.destroyed);
  }

  /// Records that a transfer successfully derived keys / completed handshake with bounded retention.
  void markHandshakeCompleted(String transferId) {
    if (_completedHandshakeTransferIds.length >= _maxHandshakeIdSetSize) {
      final toRemove = _completedHandshakeTransferIds.take(_handshakeIdSetEvictCount).toList();
      _completedHandshakeTransferIds.removeAll(toRemove);
    }
    _completedHandshakeTransferIds.add(transferId);
  }

  /// Atomically processes an incoming authenticated cancellation under the shared transfer lifecycle lock.
  ///
  /// The lock covers:
  /// - HMAC verification
  /// - Replay-cache lookup
  /// - Sequence validation
  /// - Business action execution (_handleCancelNotificationInternal)
  /// - Replay-cache insertion
  /// - Sequence advancement
  /// - Session cleanup and destruction
  Future<ControlMessageEvaluation> handleAuthenticatedCancelNotification({
    required String transferId,
    required Map<String, dynamic> fullBody,
  }) async {
    return synchronizedTransfer(transferId, () async {
      final session = getSession(transferId);
      if (session == null || session.incomingCtrlChannel == null) {
        return ControlMessageEvaluation.duplicateOrExpired();
      }

      try {
        final eval = await session.incomingCtrlChannel!.processIncomingControlMessage(
          fullBody: fullBody,
          action: () async {
            // Execute cancellation business action WITHOUT destroying the session yet,
            // so processIncomingControlMessage can complete cache insertion and sequence advancement.
            await _handleCancelNotificationInternal(transferId, skipSessionCleanup: true);
            return {'status': 'cancellation_acknowledged'};
          },
        );
        return eval;
      } finally {
        // Destroy session and clean up transfer state now that control message handling has committed
        _cleanupTransferState(transferId);
      }
    });
  }

  /// Atomically processes an incoming authenticated single-file cancellation under the shared transfer lifecycle lock.
  ///
  /// The lock covers HMAC verification, replay cache check, sequence validation, file stream abortion,
  /// replay cache recording, and sequence advancement. Does NOT destroy the session.
  Future<ControlMessageEvaluation> handleAuthenticatedCancelFileNotification({
    required String transferId,
    required String fileId,
    required Map<String, dynamic> fullBody,
  }) async {
    return synchronizedTransfer(transferId, () async {
      final session = getSession(transferId);
      if (session == null || session.incomingCtrlChannel == null) {
        return ControlMessageEvaluation.duplicateOrExpired();
      }

      return session.incomingCtrlChannel!.processIncomingControlMessage(
        fullBody: fullBody,
        action: () async {
          await _handleCancelFileNotificationInternal(transferId, fileId);
          return {'status': 'file_cancellation_acknowledged'};
        },
      );
    });
  }

  /// Whether a transfer is known to this node (active session, pre-handshake, or terminal).
  bool isKnownTransfer(String transferId) {
    if (transferId.isEmpty) return false;
    if (_incomingE2eeSessions.containsKey(transferId) ||
        _outgoingE2eeSessions.containsKey(transferId)) {
      return true;
    }
    if (_completedHandshakeTransferIds.contains(transferId) ||
        _cancelledTransferIds.contains(transferId) ||
        _processedTransferIds.contains(transferId)) {
      return true;
    }
    if (_acceptedRequests.containsKey(transferId) ||
        _outgoingRequests.containsKey(transferId) ||
        _activeIncomingSinks.containsKey(transferId) ||
        _activeOutgoingRequests.containsKey(transferId)) {
      return true;
    }
    if (incomingRequestNotifier.value?.transferId == transferId) {
      return true;
    }
    final sendVal = sendProgressNotifier.value;
    if (sendVal != null && sendVal.transferId == transferId) {
      return true;
    }
    final recvVal = receiveProgressNotifier.value;
    if (recvVal != null && recvVal.transferId == transferId) {
      return true;
    }
    return false;
  }

  TrustStore _trustStore = TrustStore();

  /// The active trust store instance.
  TrustStore get trustStore => _trustStore;

  /// Injects a custom TrustStore instance (e.g. backed by InMemoryKeyStorage in tests).
  @visibleForTesting
  set trustStore(TrustStore store) {
    _trustStore = store;
  }

  /// Gets the active E2eeSession for a given [transferId].
  E2eeSession? getSession(String transferId) =>
      _incomingE2eeSessions[transferId] ?? _outgoingE2eeSessions[transferId];

  @visibleForTesting
  E2eeSession? getIncomingSessionForTesting(String transferId) =>
      _incomingE2eeSessions[transferId];

  @visibleForTesting
  void injectIncomingSessionForTesting(String transferId, E2eeSession session) {
    _incomingE2eeSessions[transferId] = session;
  }

  @visibleForTesting
  E2eeSession? getOutgoingSessionForTesting(String transferId) =>
      _outgoingE2eeSessions[transferId];

  @visibleForTesting
  void injectOutgoingSessionForTesting(String transferId, E2eeSession session) {
    _outgoingE2eeSessions[transferId] = session;
  }

  @visibleForTesting
  void setTransferTargetForTesting(String transferId, {required String host, required int port}) {
    _transferTargetHost[transferId] = host;
    _transferTargetPort[transferId] = port;
  }

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
    await synchronizedTransfer(transferId, () async {
      if (isTransferCancelled(transferId)) {
        if (kDebugMode) {
          debugPrint(
              '[OneShare TransferService] cancelSingleFile ignored because transfer $transferId is already cancelled');
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[OneShare TransferService] cancelSingleFile called for: transferId=$transferId, fileId=$fileId');
      }
      final set = _cancelledFileIdsPerTransfer.putIfAbsent(transferId, () => {});
      set.add(fileId);

      // 1. Notify peer about single file cancellation
      final host = _transferTargetHost[transferId];
      final port = _transferTargetPort[transferId];
      if (host != null && port != null) {
        try {
          Map<String, dynamic>? payload = {
            'transferId': transferId,
            'fileId': fileId,
            'senderDeviceId': DeviceIdentityService.identity.deviceId,
          };
          final session = _outgoingE2eeSessions[transferId] ?? _incomingE2eeSessions[transferId];
          if (session != null && session.outgoingCtrlChannel != null) {
            try {
              payload = await session.outgoingCtrlChannel!.signControlMessage(payload);
            } catch (e) {
              payload = null;
              if (kDebugMode) {
                debugPrint('[OneShare TransferService] Error signing file cancel message (suppressing peer notify): $e');
              }
            }
          }
          if (payload != null) {
            final uri = Uri.http('$host:$port', OneShareConfig.transferCancelFilePath);
            final req = await _client.postUrl(uri);
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode(payload));
            final resp = await req.close();
            await resp.drain();
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
                '[OneShare TransferService] Peer file cancel notify error: $e');
          }
        }
      }

      _abortIfActiveFile(transferId, fileId);
      _updateNotifiersForFileCancel(transferId, fileId);
    });
  }

  Future<void> handleCancelFileNotification(
      String transferId, String fileId) async {
    await synchronizedTransfer(transferId, () async {
      await _handleCancelFileNotificationInternal(transferId, fileId);
    });
  }

  Future<void> _handleCancelFileNotificationInternal(
      String transferId, String fileId) async {
    if (isTransferCancelled(transferId)) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare TransferService] handleCancelFileNotification ignored: transfer $transferId already cancelled');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint(
          '[OneShare TransferService] Peer notification cancelled file: transferId=$transferId, fileId=$fileId');
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
            _activeIncomingSinks[transferId]?.close();
          } catch (_) {}
          _activeIncomingSinks.remove(transferId);

          final tempFile = _activeIncomingTempFiles[transferId];
          if (tempFile != null) {
            try {
              tempFile.delete();
            } catch (_) {}
            _activeIncomingTempFiles.remove(transferId);
          }

          try {
            _activeIncomingHttpRequests[transferId]?.response.detachSocket().then((s) => s.destroy());
          } catch (_) {}
          _activeIncomingHttpRequests.remove(transferId);
        }
      }
    }

    final currentSend = sendProgressNotifier.value;
    if (currentSend != null && currentSend.transferId == transferId) {
      for (final f in currentSend.files) {
        if (f.fileId == fileId && f.status == FileTransferStatus.transferring) {
          try {
            _activeOutgoingRequests[transferId]?.abort();
          } catch (_) {}
          _activeOutgoingRequests.remove(transferId);
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

      final allCompleted = updatedFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled = updatedFiles.any((f) => f.status == FileTransferStatus.cancelled) || isTransferCancelled(transferId);

      final TransferProgressStatus newStatus;
      if (!allTerminal) {
        newStatus = sendVal.status;
      } else if (allCompleted) {
        newStatus = TransferProgressStatus.completed;
      } else if (anyCancelled) {
        newStatus = TransferProgressStatus.cancelled;
      } else {
        newStatus = TransferProgressStatus.failed;
      }

      sendProgressNotifier.value = TransferProgressState(
        transferId: sendVal.transferId,
        currentFileName: sendVal.currentFileName,
        currentFileIndex: sendVal.currentFileIndex,
        totalFiles: sendVal.totalFiles,
        currentFileBytesTransferred: sendVal.currentFileBytesTransferred,
        currentFileSizeBytes: sendVal.currentFileSizeBytes,
        overallBytesTransferred: sendVal.overallBytesTransferred,
        overallTotalBytes: sendVal.overallTotalBytes,
        status: newStatus,
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

      final allCompleted = updatedFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled = updatedFiles.any((f) => f.status == FileTransferStatus.cancelled) || isTransferCancelled(transferId);

      final TransferProgressStatus newStatus;
      if (!allTerminal) {
        newStatus = recvVal.status;
      } else if (allCompleted) {
        newStatus = TransferProgressStatus.completed;
      } else if (anyCancelled) {
        newStatus = TransferProgressStatus.cancelled;
      } else {
        newStatus = TransferProgressStatus.failed;
      }

      receiveProgressNotifier.value = TransferProgressState(
        transferId: recvVal.transferId,
        currentFileName: recvVal.currentFileName,
        currentFileIndex: recvVal.currentFileIndex,
        totalFiles: recvVal.totalFiles,
        currentFileBytesTransferred: recvVal.currentFileBytesTransferred,
        currentFileSizeBytes: recvVal.currentFileSizeBytes,
        overallBytesTransferred: recvVal.overallBytesTransferred,
        overallTotalBytes: recvVal.overallTotalBytes,
        status: newStatus,
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

    if (targetId != null) {
      final host = _transferTargetHost[targetId];
      final port = _transferTargetPort[targetId];
      if (host != null && port != null) {
        _sendCancelNotificationToPeer(host, port, targetId);
      }
    }

    // Complete the per-transfer cancel completer
    if (targetId != null) {
      final cancelCompleter = _outgoingCancelCompleters[targetId];
      if (cancelCompleter != null && !cancelCompleter.isCompleted) {
        cancelCompleter.complete(
          const TransferRequestOutcome(
            status: TransferResultStatus.failed,
            message: 'Transfer request cancelled by user',
          ),
        );
      }
      _outgoingCancelCompleters.remove(targetId);
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
      final uri = Uri.http('$host:$port', OneShareConfig.transferCancelPath);
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
        debugPrint('[OneShare TransferService] Peer cancel notify error: $e');
      }
    }
  }

  // ──────────────────────────────────────────────────────────
  // Cancel transfer
  // ──────────────────────────────────────────────────────────

  Future<void> cancelTransfer(String transferId) async {
    await synchronizedTransfer(transferId, () async {
      if (kDebugMode) {
        debugPrint('[OneShare TransferService] cancelTransfer called for: $transferId');
      }
      if (isTransferCancelled(transferId)) {
        if (kDebugMode) {
          debugPrint('[OneShare TransferService] cancelTransfer: already cancelled $transferId');
        }
        return;
      }
      _addCancelledId(transferId);

      // 1. Capture peer host, port, session, and outgoing control channel before any state mutation
      final host = _transferTargetHost[transferId] ?? _acceptedRequests[transferId]?.senderHost;
      final port = _transferTargetPort[transferId] ?? _acceptedRequests[transferId]?.senderPort;
      final session = _outgoingE2eeSessions[transferId] ?? _incomingE2eeSessions[transferId];
      final ctrlChannel = session?.outgoingCtrlChannel;

      // 2. Sign outgoing cancel notification before cleanup
      Map<String, dynamic>? payload = {
        'transferId': transferId,
        'senderDeviceId': DeviceIdentityService.identity.deviceId,
      };
      if (ctrlChannel != null) {
        try {
          payload = await ctrlChannel.signControlMessage(payload);
        } catch (e) {
          // Failure to sign on a post-handshake session must NEVER result in sending
          // an unsigned unauthenticated cancellation message.
          payload = null;
          if (kDebugMode) {
            debugPrint('[OneShare TransferService] Error signing cancel message (suppressing peer notify): $e');
          }
        }
      }

      // 3. Send cancel notification to peer BEFORE aborting local HTTP connections
      if (host != null && port != null && payload != null) {
        try {
          final uri = Uri.http('$host:$port', OneShareConfig.transferCancelPath);
          final req = await _client.postUrl(uri);
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(payload));
          final resp = await req.close();
          await resp.drain();
        } catch (e) {
          if (kDebugMode) debugPrint('[OneShare TransferService] Peer cancel notify error: $e');
        }
      }

      try {
        // 4. Update progress notifiers to cancelled
        final sendCurrent = sendProgressNotifier.value;
        final isOutgoing = _outgoingFileItems.containsKey(transferId);
        if ((sendCurrent != null && sendCurrent.transferId == transferId) || (isOutgoing && sendCurrent == null)) {
          final activeIndex = (sendCurrent?.currentFileIndex ?? 1) - 1;
          final currentSent = _activeSenderCurrentFileBytes[transferId] ?? 0;
          final outgoingItems = _outgoingFileItems[transferId];

          final List<PerFileTransferState> cancelledFiles;
          if (sendCurrent != null && sendCurrent.files.isNotEmpty) {
            cancelledFiles = sendCurrent.files.asMap().entries.map((entry) {
              final idx = entry.key;
              final f = entry.value;
              if (f.status == FileTransferStatus.completed) return f;
              final activeBytes = currentSent > f.bytesTransferred ? currentSent : f.bytesTransferred;
              final bytes = (idx == activeIndex) ? activeBytes : f.bytesTransferred;
              return PerFileTransferState(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
                bytesTransferred: bytes,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
            }).toList();
          } else if (outgoingItems != null && outgoingItems.isNotEmpty) {
            cancelledFiles = outgoingItems.asMap().entries.map((entry) {
              final idx = entry.key;
              final f = entry.value;
              final bytes = (idx == activeIndex && currentSent > 0) ? currentSent : 0;
              return PerFileTransferState(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
                bytesTransferred: bytes,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
            }).toList();
          } else {
            cancelledFiles = const [];
          }

          final totalBytes = (sendCurrent != null && sendCurrent.overallTotalBytes > 0)
              ? sendCurrent.overallTotalBytes
              : (outgoingItems?.fold<int>(0, (sum, f) => sum + f.fileSize) ?? 0);

          final overallTransferred = cancelledFiles.fold<int>(
            0,
            (sum, f) => sum + f.bytesTransferred,
          );

          final clampedIndex = activeIndex.clamp(0, cancelledFiles.isEmpty ? 0 : cancelledFiles.length - 1);
          final currentFileTransferred = cancelledFiles.isNotEmpty
              ? cancelledFiles[clampedIndex].bytesTransferred
              : 0;

          sendProgressNotifier.value = TransferProgressState(
            transferId: transferId,
            currentFileName: sendCurrent?.currentFileName ?? (outgoingItems?.isNotEmpty == true ? outgoingItems!.first.fileName : 'file'),
            currentFileIndex: sendCurrent?.currentFileIndex ?? 1,
            totalFiles: sendCurrent?.totalFiles ?? (outgoingItems?.length ?? 1),
            currentFileBytesTransferred: currentFileTransferred,
            currentFileSizeBytes: sendCurrent?.currentFileSizeBytes ?? (outgoingItems?.isNotEmpty == true ? outgoingItems!.first.fileSize : 0),
            overallBytesTransferred: overallTransferred,
            overallTotalBytes: totalBytes,
            status: TransferProgressStatus.cancelled,
            files: cancelledFiles,
            errorMessage: 'Transfer cancelled by user',
          );
        }

        final recvCurrent = receiveProgressNotifier.value;
        final isIncoming = _acceptedRequests.containsKey(transferId) || _activeIncomingSinks.containsKey(transferId);
        if ((recvCurrent != null && recvCurrent.transferId == transferId) || (isIncoming && recvCurrent == null)) {
          final cancelledFiles = recvCurrent?.files.map((f) {
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
            currentFileName: recvCurrent?.currentFileName ?? 'file',
            currentFileIndex: recvCurrent?.currentFileIndex ?? 1,
            totalFiles: recvCurrent?.totalFiles ?? 1,
            currentFileBytesTransferred: recvCurrent?.currentFileBytesTransferred ?? 0,
            currentFileSizeBytes: recvCurrent?.currentFileSizeBytes ?? 0,
            overallBytesTransferred: recvCurrent?.overallBytesTransferred ?? 0,
            overallTotalBytes: recvCurrent?.overallTotalBytes ?? 0,
            status: TransferProgressStatus.cancelled,
            files: cancelledFiles,
            errorMessage: 'Transfer cancelled by user',
          );
        }

        // 5. Abort active outgoing HTTP upload request FOR THIS TRANSFER ONLY.
        final outgoingReq = _activeOutgoingRequests[transferId];
        if (outgoingReq != null) {
          try {
            outgoingReq.abort();
          } catch (e) {
            if (kDebugMode) debugPrint('[OneShare TransferService] Error aborting outgoing request: $e');
          }
          _activeOutgoingRequests.remove(transferId);
        }

        // 6. Abort active incoming file sink & temp file FOR THIS TRANSFER ONLY.
        final incomingSink = _activeIncomingSinks[transferId];
        if (incomingSink != null) {
          try {
            await incomingSink.close();
          } catch (_) {}
          _activeIncomingSinks.remove(transferId);
        }

        final incomingTempFile = _activeIncomingTempFiles[transferId];
        if (incomingTempFile != null) {
          try {
            if (await incomingTempFile.exists()) {
              if (kDebugMode) {
                debugPrint('[OneShare TransferService] Deleting incomplete temp file on cancel: ${LogSanitizer.sanitizePath(incomingTempFile.path)}');
              }
              await incomingTempFile.delete();
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[OneShare TransferService] Error deleting temp file: ${LogSanitizer.redact(e.toString())}');
            }
          }
          _activeIncomingTempFiles.remove(transferId);
        }

        final incomingHttpReq = _activeIncomingHttpRequests[transferId];
        if (incomingHttpReq != null) {
          try {
            incomingHttpReq.response.statusCode = 499;
            await incomingHttpReq.response.close();
          } catch (_) {}
          _activeIncomingHttpRequests.remove(transferId);
        }
      } finally {
        // 7. Guaranteed finalization: clean up state and session keys
        _cleanupTransferState(transferId);
      }
    });
  }

  /// Cleans up per-transfer state (accepted request entry + token + I/O maps).
  /// Called on both cancel and normal completion to prevent leaks.
  /// Safe and idempotent for repeated calls.
  void _cleanupTransferState(String transferId) {
    // Remove acceptedRequest entry.
    _acceptedRequests.remove(transferId);

    // Find and invalidate the token for this transfer.
    final tokenKey = _activeTokens.entries
        .where((e) => e.value.transferId == transferId)
        .map((e) => e.key)
        .firstOrNull;
    if (tokenKey != null) {
      _activeTokens.remove(tokenKey);
    }

    // Clean up per-transfer I/O tracking maps.
    _transferTargetHost.remove(transferId);
    _transferTargetPort.remove(transferId);
    _activeSenderCurrentFileBytes.remove(transferId);
    _outgoingCancelCompleters.remove(transferId);

    // E2EE session cleanup and best-effort zeroization
    final outgoingSession = _outgoingE2eeSessions.remove(transferId);
    outgoingSession?.destroy();
    final incomingSession = _incomingE2eeSessions.remove(transferId);
    incomingSession?.destroy();
  }

  Future<void> handleCancelNotification(String transferId) async {
    await synchronizedTransfer(transferId, () async {
      await _handleCancelNotificationInternal(transferId);
    });
  }

  Future<void> _handleCancelNotificationInternal(String transferId, {bool skipSessionCleanup = false}) async {
    if (kDebugMode) {
      debugPrint('[OneShare TransferService] Peer notification cancelled transfer: $transferId');
    }
    if (isTransferCancelled(transferId)) {
      if (kDebugMode) {
        debugPrint('[OneShare TransferService] handleCancelNotification: already cancelled $transferId');
      }
      return;
    }
    _addCancelledId(transferId);

      // If an incoming request dialog is open on this device,
      // cancel its timer and clear the notifier so the dialog auto-dismisses.
      if (incomingRequestNotifier.value != null &&
          (incomingRequestNotifier.value?.transferId == transferId || transferId.isEmpty)) {
        incomingRequestNotifier.value?.timer?.cancel();
        incomingRequestNotifier.value = null;
      }

      try {
        // Abort I/O handles belonging to THIS transfer.
        final incomingSink = _activeIncomingSinks[transferId];
        if (incomingSink != null) {
          try {
            await incomingSink.close();
          } catch (_) {}
          _activeIncomingSinks.remove(transferId);
        }

        final incomingTempFile = _activeIncomingTempFiles[transferId];
        if (incomingTempFile != null) {
          try {
            if (await incomingTempFile.exists()) {
              await incomingTempFile.delete();
            }
          } catch (_) {}
          _activeIncomingTempFiles.remove(transferId);
        }

        final outgoingReq = _activeOutgoingRequests[transferId];
        if (outgoingReq != null) {
          try {
            outgoingReq.abort();
          } catch (_) {}
          _activeOutgoingRequests.remove(transferId);
        }

        final incomingHttpReq = _activeIncomingHttpRequests[transferId];
        if (incomingHttpReq != null) {
          try {
            incomingHttpReq.response.statusCode = 499;
            await incomingHttpReq.response.close();
          } catch (_) {}
          _activeIncomingHttpRequests.remove(transferId);
        }

        // Update SENDER progress notifier if it belongs to this transfer.
        final sendCurrent = sendProgressNotifier.value;
        final isOutgoing = _outgoingFileItems.containsKey(transferId);
        if ((sendCurrent != null && sendCurrent.transferId == transferId) || (isOutgoing && sendCurrent == null)) {
          final activeIndex = (sendCurrent?.currentFileIndex ?? 1) - 1;
          final currentSent = _activeSenderCurrentFileBytes[transferId] ?? 0;
          final outgoingItems = _outgoingFileItems[transferId];

          final List<PerFileTransferState> cancelledFiles;
          if (sendCurrent != null && sendCurrent.files.isNotEmpty) {
            cancelledFiles = sendCurrent.files.asMap().entries.map((entry) {
              final idx = entry.key;
              final f = entry.value;
              if (f.status == FileTransferStatus.completed) return f;
              final activeBytes = currentSent > f.bytesTransferred ? currentSent : f.bytesTransferred;
              final bytes = (idx == activeIndex) ? activeBytes : f.bytesTransferred;
              return PerFileTransferState(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
                bytesTransferred: bytes,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
            }).toList();
          } else if (outgoingItems != null && outgoingItems.isNotEmpty) {
            cancelledFiles = outgoingItems.asMap().entries.map((entry) {
              final idx = entry.key;
              final f = entry.value;
              final bytes = (idx == activeIndex && currentSent > 0) ? currentSent : 0;
              return PerFileTransferState(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
                bytesTransferred: bytes,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
            }).toList();
          } else {
            cancelledFiles = const [];
          }

          final totalBytes = (sendCurrent != null && sendCurrent.overallTotalBytes > 0)
              ? sendCurrent.overallTotalBytes
              : (outgoingItems?.fold<int>(0, (sum, f) => sum + f.fileSize) ?? 0);

          final overallTransferred = cancelledFiles.fold<int>(
            0,
            (sum, f) => sum + f.bytesTransferred,
          );

          final clampedIndex = activeIndex.clamp(0, cancelledFiles.isEmpty ? 0 : cancelledFiles.length - 1);
          final currentFileTransferred = cancelledFiles.isNotEmpty
              ? cancelledFiles[clampedIndex].bytesTransferred
              : 0;

          sendProgressNotifier.value = TransferProgressState(
            transferId: transferId,
            currentFileName: sendCurrent?.currentFileName ?? (outgoingItems?.isNotEmpty == true ? outgoingItems!.first.fileName : 'file'),
            currentFileIndex: sendCurrent?.currentFileIndex ?? 1,
            totalFiles: sendCurrent?.totalFiles ?? (outgoingItems?.length ?? 1),
            currentFileBytesTransferred: currentFileTransferred,
            currentFileSizeBytes: sendCurrent?.currentFileSizeBytes ?? (outgoingItems?.isNotEmpty == true ? outgoingItems!.first.fileSize : 0),
            overallBytesTransferred: overallTransferred,
            overallTotalBytes: totalBytes,
            status: TransferProgressStatus.cancelled,
            files: cancelledFiles,
            errorMessage: 'Transfer cancelled by peer device',
          );
        }

        // Update RECEIVER progress notifier if it belongs to this transfer.
        final recvCurrent = receiveProgressNotifier.value;
        final isIncoming = _acceptedRequests.containsKey(transferId) || _activeIncomingSinks.containsKey(transferId);
        if ((recvCurrent != null && recvCurrent.transferId == transferId) || (isIncoming && recvCurrent == null)) {
          final cancelledFiles = recvCurrent?.files.map((f) {
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
            currentFileName: recvCurrent?.currentFileName ?? 'file',
            currentFileIndex: recvCurrent?.currentFileIndex ?? 1,
            totalFiles: recvCurrent?.totalFiles ?? 1,
            currentFileBytesTransferred: recvCurrent?.currentFileBytesTransferred ?? 0,
            currentFileSizeBytes: recvCurrent?.currentFileSizeBytes ?? 0,
            overallBytesTransferred: recvCurrent?.overallBytesTransferred ?? 0,
            overallTotalBytes: recvCurrent?.overallTotalBytes ?? 0,
            status: TransferProgressStatus.cancelled,
            files: cancelledFiles,
            errorMessage: 'Transfer cancelled by peer device',
          );
        }
      } finally {
        if (!skipSessionCleanup) {
          _cleanupTransferState(transferId);
        }
      }
  }

  Future<TransferRequestOutcome> sendTransferRequest({
    required String targetHost,
    required int targetPort,
    required List<Map<String, dynamic>> selectedFileDetails,
    String? targetDeviceId,
    String? targetDeviceName,
    String? localHost,
    int? senderPort,
  }) async {
    final transferId = _generateUuidV4();
    _transferTargetHost[transferId] = targetHost;
    _transferTargetPort[transferId] = targetPort;
    final ownIdentity = DeviceIdentityService.identity;

    if (kDebugMode) {
      debugPrint(
          '[OneShare Timestamp] MAC TRANSFER START transferId=$transferId time=${DateTime.now().toIso8601String()}');
    }

    final fileItems = selectedFileDetails.map((f) {
      return TransferFileItem(
        fileId: _generateUuidV4(),
        fileName: f['name'] as String? ?? 'file',
        fileSize: f['size'] as int? ?? 0,
      );
    }).toList();

    _outgoingFileItems[transferId] = fileItems;

    // Resolve target peer in TrustStore to pin intendedReceiverIdentityPubKey
    Uint8List? intendedReceiverPubKey;
    if (targetDeviceId != null || targetDeviceName != null) {
      final candidates = await trustStore.findCandidatePeers(
        deviceId: targetDeviceId,
        deviceName: targetDeviceName,
      );
      // Only pin if there is an unambiguous (exactly 1) match that is manually verified
      if (candidates.length == 1 && candidates.first.trustLevel == TrustLevel.manuallyVerified) {
        intendedReceiverPubKey = candidates.first.identityPublicKeyBytes;
        if (kDebugMode) {
          debugPrint(
              '[OneShare Stream Sender] Pinned intendedReceiverIdentityPubKey for verified peer: ${candidates.first.deviceName} (${candidates.first.fingerprint.substring(0, 8)}...)');
        }
      }
    }

    // E2EE v2 Handshake Setup (Initiator)
    final manifestItems = fileItems
        .map((f) => ManifestFileItem(
              fileId: f.fileId,
              fileName: f.fileName,
              fileSize: f.fileSize,
            ))
        .toList();
    final manifestHash = await E2eeHandshake.computeManifestHash(manifestItems);

    final ephemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
    final ephemeralPubKey = Uint8List.fromList(
      (await ephemeralKeyPair.extractPublicKey()).bytes,
    );

    final session = E2eeSession(
      transferId: transferId,
      isInitiator: true,
      myIdentityKeyPair: ownIdentity.identityKeyPair,
      myIdentityPubKey: ownIdentity.identityPublicKeyBytes,
    );
    session.myEphemeralKeyPair = ephemeralKeyPair;
    session.myEphemeralPubKey = ephemeralPubKey;
    session.manifestHash = manifestHash;
    session.intendedReceiverIdentityPubKey = intendedReceiverPubKey;
    session.state = E2eeSessionState.msg1Sent;
    _outgoingE2eeSessions[transferId] = session;

    final signature = await E2eeHandshake.signMsg1(
      senderIdentityKeyPair: ownIdentity.identityKeyPair,
      transferId: transferId,
      manifestHash: manifestHash,
      senderEphemeralPubKey: ephemeralPubKey,
      intendedReceiverIdentityPubKey: intendedReceiverPubKey,
    );

    final payload = {
      'transferId': transferId,
      'senderDeviceId': ownIdentity.deviceId,
      'senderDeviceName': ownIdentity.deviceName,
      'senderHost': localHost ?? '127.0.0.1',
      'senderPort': senderPort ?? OneShareConfig.port,
      'files': fileItems.map((f) => f.toJson()).toList(),
      'e2ee': {
        'version': OneShareConfig.protocolVersion,
        'manifestHash': base64Encode(manifestHash),
        'senderIdentityPubKey': base64Encode(ownIdentity.identityPublicKeyBytes),
        'senderEphemeralPubKey': base64Encode(ephemeralPubKey),
        'senderEphemeralSig': base64Encode(signature),
        'intendedReceiverIdentityPubKey': intendedReceiverPubKey != null
            ? base64Encode(intendedReceiverPubKey)
            : null,
      },
    };

    final completer = Completer<TransferRequestOutcome>();
    _outgoingRequests[transferId] = completer;

    // BUG-01 FIX: Set up the cancel completer so cancelOutgoingRequest() can
    // resolve this future immediately without waiting for the 35s timeout.
    final cancelCompleter = Completer<TransferRequestOutcome>();
    _outgoingCancelCompleters[transferId] = cancelCompleter;

    // 35 second fallback timeout for sender
    final timer = Timer(const Duration(seconds: 35), () {
      if (_outgoingRequests.containsKey(transferId)) {
        if (kDebugMode) {
          debugPrint(
              '[OneShare Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=TIMEOUT time=${DateTime.now().toIso8601String()}');
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
          Uri.http('$targetHost:$targetPort', OneShareConfig.transferRequestPath);
      if (kDebugMode) {
        debugPrint(
            '[OneShare Timestamp] MAC REQUEST CONNECT transferId=$transferId uri=$uri time=${DateTime.now().toIso8601String()}');
      }
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));

      final response = await request.close();
      if (kDebugMode) {
        debugPrint(
            '[OneShare Timestamp] MAC REQUEST BODY SENT transferId=$transferId time=${DateTime.now().toIso8601String()}');
      }
      final responseBody = await utf8.decoder.bind(response).join();

      if (kDebugMode) {
        debugPrint(
            '[OneShare Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=${response.statusCode} time=${DateTime.now().toIso8601String()}');
      }

      if (response.statusCode != HttpStatus.ok) {
        timer.cancel();
        _outgoingCancelCompleters.remove(transferId);
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
      _outgoingCancelCompleters.remove(transferId);
      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Timestamp] MAC REQUEST RESPONSE/TIMEOUT transferId=$transferId status=EXCEPTION error=$e time=${DateTime.now().toIso8601String()}');
      }
      timer.cancel();
      _outgoingCancelCompleters.remove(transferId);
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
            '[OneShare Stream Sender] sendTransferFiles called for cancelled transfer $transferId');
      }
      return false;
    }
    _transferTargetHost[transferId] = targetHost;
    _transferTargetPort[transferId] = targetPort;
    _activeSenderCurrentFileBytes[transferId] = 0;

    // Pre-resolve any zero file sizes from disk if available
    final resolvedFiles = <FileToSend>[];
    for (final f in filesToSend) {
      var item = f.fileItem;
      if (item.fileSize == 0 && !f.localPath.startsWith('content://')) {
        try {
          final file = File(f.localPath);
          if (await file.exists()) {
            final len = await file.length();
            if (len > 0) {
              item = TransferFileItem(
                fileId: item.fileId,
                fileName: item.fileName,
                fileSize: len,
              );
            }
          }
        } catch (_) {}
      }
      resolvedFiles.add(FileToSend(fileItem: item, localPath: f.localPath));
    }
    filesToSend = resolvedFiles;

    final overallTotalBytes =
        filesToSend.fold<int>(0, (sum, f) => sum + f.fileItem.fileSize);
    int completedFilesBytes = 0;

    try {
      for (int i = 0; i < filesToSend.length; i++) {
        _activeSenderCurrentFileBytes[transferId] = 0;

        if (isTransferCancelled(transferId)) {
          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] Transfer $transferId was cancelled before file ${i + 1}');
          }
          _activeOutgoingRequests.remove(transferId);
          return false;
        }

        final fileToSend = filesToSend[i];
        final fileItem = fileToSend.fileItem;

        if (isFileCancelled(transferId, fileItem.fileId)) {
          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] File ${fileItem.fileName} was cancelled, skipping.');
          }
          continue;
        }

        final isContentUri = fileToSend.localPath.startsWith('content://');

        if (!isContentUri) {
          final file = File(fileToSend.localPath);
          if (!await file.exists()) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Sender] File not found on sender: ${fileToSend.localPath}');
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

        int currentFileSent = 0;

        try {
          final uri =
              Uri.http('$targetHost:$targetPort', OneShareConfig.transferFilePath);
          if (kDebugMode) {
            debugPrint('[OneShare Stream Sender] Opening connection to $uri');
            debugPrint(
                '[OneShare Stream Sender] transferId: $transferId, fileId: ${fileItem.fileId}, fileName: ${fileItem.fileName}, expectedSize: ${fileItem.fileSize}');
          }
          final request = await _client.postUrl(uri);
          _activeOutgoingRequests[transferId] = request;

          request.headers.contentType = ContentType.binary;
          request.headers.set('authorization', 'Bearer $transferToken');
          request.headers.set('x-transfer-id', transferId);
          request.headers.set('x-file-id', fileItem.fileId);
          request.headers.set(
              'x-file-name', Uri.encodeComponent(fileItem.fileName));
          // For E2EE v2 transfers, HTTP chunked transfer encoding is used so the
          // plaintext length is not leaked on the wire and ciphertext length is dynamic.
          final session = _outgoingE2eeSessions[transferId];
          if (session == null && fileItem.fileSize > 0) {
            request.contentLength = fileItem.fileSize;
          }

          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] Connection opened. Streaming file data...');
          }

          int lastProgressUpdateMs = 0;
          final fileStream = _openFileStream(
            fileToSend.localPath,
            transferId,
            (chunkLength) {
              currentFileSent += chunkLength;
              _activeSenderCurrentFileBytes[transferId] = currentFileSent;
              if (kDebugMode && (currentFileSent % (1024 * 1024) == 0 || currentFileSent < 100 * 1024)) {
                debugPrint('[DIAGNOSTIC] Sender chunk callback: currentFileSent: $currentFileSent');
              }
              final nowMs = DateTime.now().millisecondsSinceEpoch;

              final currentEffectiveSize = fileItem.fileSize > 0
                  ? fileItem.fileSize
                  : (currentFileSent > 0 ? currentFileSent : 1);
              final effectiveTotalBytes = overallTotalBytes > 0
                  ? overallTotalBytes
                  : (completedFilesBytes + currentEffectiveSize);

              if (nowMs - lastProgressUpdateMs >= 50 ||
                  (fileItem.fileSize > 0 && currentFileSent == fileItem.fileSize)) {
                lastProgressUpdateMs = nowMs;
                if (!isTransferCancelled(transferId) &&
                    !isFileCancelled(transferId, fileItem.fileId)) {
                  sendProgressNotifier.value = TransferProgressState(
                    transferId: transferId,
                    currentFileName: fileItem.fileName,
                    currentFileIndex: i + 1,
                    totalFiles: filesToSend.length,
                    currentFileBytesTransferred: currentFileSent,
                    currentFileSizeBytes: currentEffectiveSize,
                    overallBytesTransferred: completedFilesBytes + currentFileSent,
                    overallTotalBytes: effectiveTotalBytes,
                    status: TransferProgressStatus.transferring,
                    files: _buildSenderFileStates(
                        transferId, filesToSend, i, currentFileSent, FileTransferStatus.transferring),
                  );
                }
              }
            },
          );

          Stream<List<int>> streamToSend = fileStream;
          if (session != null) {
            final fileKey = await session.deriveFileKeyForId(fileItem.fileId);
            final writer = EncryptedStreamWriter(
              fileKey: fileKey,
              transferId: transferId,
              fileId: fileItem.fileId,
            );
            streamToSend = writer.encryptStream(fileStream);
          }

          await request.addStream(streamToSend);

          // Post-addStream safeguard: ensure UI reflects final byte count
          // even if the 50ms throttle skipped the last onChunk update.
          final finalEffectiveSize = fileItem.fileSize > 0
              ? fileItem.fileSize
              : currentFileSent;
          final finalTotalBytes = overallTotalBytes > 0
              ? overallTotalBytes
              : (completedFilesBytes + finalEffectiveSize);

          if (!isTransferCancelled(transferId) &&
              !isFileCancelled(transferId, fileItem.fileId)) {
            sendProgressNotifier.value = TransferProgressState(
              transferId: transferId,
              currentFileName: fileItem.fileName,
              currentFileIndex: i + 1,
              totalFiles: filesToSend.length,
              currentFileBytesTransferred: currentFileSent,
              currentFileSizeBytes: finalEffectiveSize,
              overallBytesTransferred: completedFilesBytes + currentFileSent,
              overallTotalBytes: finalTotalBytes,
              status: TransferProgressStatus.transferring,
              files: _buildSenderFileStates(
                  transferId, filesToSend, i, currentFileSent, FileTransferStatus.transferring),
            );
          }

          if (isTransferCancelled(transferId)) {
            request.abort();
            _activeOutgoingRequests.remove(transferId);
            return false;
          }

          if (isFileCancelled(transferId, fileItem.fileId)) {
            request.abort();
            _activeOutgoingRequests.remove(transferId);
            continue;
          }

          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] Finished writing stream to socket. Bytes sent: $currentFileSent / ${fileItem.fileSize}');
          }

          final response = await request.close();
          _activeOutgoingRequests.remove(transferId);

          if (isTransferCancelled(transferId)) {
            return false;
          }

          if (isFileCancelled(transferId, fileItem.fileId)) {
            continue;
          }

          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] Response HTTP Status: ${response.statusCode}');
          }

          if (response.statusCode != HttpStatus.ok) {
            final responseBody = await utf8.decoder.bind(response).join();
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Sender] Upload failed status ${response.statusCode}, body: $responseBody');
            }

            // Allow in-flight peer cancel HTTP notification to process if socket/HTTP 499 arrived first
            await Future.delayed(const Duration(milliseconds: 300));

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
                '[OneShare Stream Sender] Connection closed cleanly for ${fileItem.fileName}');
          }

          completedFilesBytes += fileItem.fileSize;
        } catch (e, st) {
          _activeOutgoingRequests.remove(transferId);
          if (kDebugMode) {
            debugPrint('[DIAGNOSTIC] sendTransferFiles catch block. error: $e');
            debugPrint('[DIAGNOSTIC] isTransferCancelled: ${isTransferCancelled(transferId)}');
            debugPrint('[DIAGNOSTIC] currentFileSent: $currentFileSent, _activeSenderCurrentFileBytes: ${_activeSenderCurrentFileBytes[transferId]}');
            debugPrint('[DIAGNOSTIC] completedFilesBytes: $completedFilesBytes');
          }

          if (isTransferCancelled(transferId) || e is TransferCancelledException) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Sender] Outgoing transfer cancelled for $transferId');
            }
            return false;
          }

          // Allow in-flight peer cancel HTTP notification to process if socket dropped first
          await Future.delayed(const Duration(milliseconds: 300));
          if (isTransferCancelled(transferId)) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Sender] Outgoing transfer marked cancelled after socket drop for $transferId');
            }
            return false;
          }

          if (isFileCancelled(transferId, fileItem.fileId)) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Sender] File ${fileItem.fileName} was cancelled, continuing to next.');
            }
            continue;
          }

          if (kDebugMode) {
            debugPrint(
                '[OneShare Stream Sender] Exception during file upload: $e\n$st');
          }
          final finalSent = currentFileSent > 0 ? currentFileSent : (_activeSenderCurrentFileBytes[transferId] ?? 0);
          sendProgressNotifier.value = TransferProgressState(
            transferId: transferId,
            currentFileName: fileItem.fileName,
            currentFileIndex: i + 1,
            totalFiles: filesToSend.length,
            currentFileBytesTransferred: finalSent,
            currentFileSizeBytes: fileItem.fileSize,
            overallBytesTransferred: completedFilesBytes + finalSent,
            overallTotalBytes: overallTotalBytes,
            status: TransferProgressStatus.failed,
            errorMessage: 'Transfer network error: $e',
            files: _buildSenderFileStates(
                transferId, filesToSend, i, finalSent, FileTransferStatus.failed,
                errorMessage: 'Network error'),
          );
          return false;
        }
      }

      final currentSendState = sendProgressNotifier.value;
      final finalFiles = filesToSend.map((f) {
        if (isFileCancelled(transferId, f.fileItem.fileId)) {
          final existing = currentSendState?.files.firstWhere(
            (sf) => sf.fileId == f.fileItem.fileId,
            orElse: () => PerFileTransferState(
              fileId: f.fileItem.fileId,
              fileName: f.fileItem.fileName,
              fileSize: f.fileItem.fileSize,
              bytesTransferred: 0,
              status: FileTransferStatus.cancelled,
              errorMessage: 'Cancelled',
            ),
          );
          return existing ??
              PerFileTransferState(
                fileId: f.fileItem.fileId,
                fileName: f.fileItem.fileName,
                fileSize: f.fileItem.fileSize,
                bytesTransferred: 0,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
        }
        return PerFileTransferState(
          fileId: f.fileItem.fileId,
          fileName: f.fileItem.fileName,
          fileSize: f.fileItem.fileSize,
          bytesTransferred: f.fileItem.fileSize,
          status: FileTransferStatus.completed,
        );
      }).toList();

      final allCompleted = finalFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled = finalFiles.any((f) => f.status == FileTransferStatus.cancelled) || isTransferCancelled(transferId);
      final anyFailed = finalFiles.any((f) => f.status == FileTransferStatus.failed);

      final TransferProgressStatus finalStatus;
      if (allCompleted) {
        finalStatus = TransferProgressStatus.completed;
      } else if (anyCancelled) {
        finalStatus = TransferProgressStatus.cancelled;
      } else if (anyFailed) {
        finalStatus = TransferProgressStatus.failed;
      } else {
        finalStatus = TransferProgressStatus.failed;
      }

      final finalOverallTransferred = finalFiles.fold<int>(
        0,
        (sum, f) => sum + f.bytesTransferred,
      );

      sendProgressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: filesToSend.last.fileItem.fileName,
        currentFileIndex: filesToSend.length,
        totalFiles: filesToSend.length,
        currentFileBytesTransferred: filesToSend.last.fileItem.fileSize,
        currentFileSizeBytes: filesToSend.last.fileItem.fileSize,
        overallBytesTransferred: finalOverallTransferred,
        overallTotalBytes: overallTotalBytes,
        status: finalStatus,
        files: finalFiles,
      );

      return true;
    } finally {
      // BUG-22 FIX: Always clear per-transfer host/port after a transfer ends
      // (success, failure, or cancellation) to prevent stale cancel
      // notifications being sent to the wrong peer on the next transfer.
      _transferTargetHost.remove(transferId);
      _transferTargetPort.remove(transferId);
    }
  }

  Future<Map<String, dynamic>> handleIncomingRequest(
      Map<String, dynamic> body, String clientRemoteHost) async {
    final pendingRequest = PendingTransferRequest.fromJson(body);

    if (kDebugMode) {
      debugPrint(
          '[OneShare Timestamp] ANDROID handleIncomingRequest START transferId=${pendingRequest.transferId} time=${DateTime.now().toIso8601String()}');
    }

    if (pendingRequest.transferId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] REJECTED: transferId is empty');
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
            '[OneShare Stream Receiver] REJECTED: Duplicate transfer ID ${pendingRequest.transferId}');
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
            '[OneShare Stream Receiver] REJECTED: Receiver busy with pending request ${incomingRequestNotifier.value?.transferId}');
      }
      return {
        'status': 'rejected',
        'error': 'Receiver is busy with another incoming transfer',
        'code': 'BUSY_OR_DUPLICATE',
      };
    }

    if (pendingRequest.files.isEmpty) {
      return {
        'status': 'rejected',
        'error': 'No files specified in transfer request',
        'code': 'EMPTY_FILE_LIST',
      };
    }

    if (pendingRequest.files.length > 100) {
      return {
        'status': 'rejected',
        'error': 'File count exceeds maximum allowed limit of 100 files',
        'code': 'EXCESSIVE_FILE_COUNT',
      };
    }

    const int maxSingleFileSize = 100 * 1024 * 1024 * 1024; // 100 GB
    for (final f in pendingRequest.files) {
      if (f.fileName.isEmpty || f.fileName.length > 255) {
        return {
          'status': 'rejected',
          'error': 'Invalid file name length: ${f.fileName}',
          'code': 'INVALID_FILE_NAME',
        };
      }
      if (f.fileName.contains('\x00') || f.fileName.contains('/') || f.fileName.contains('\\')) {
        return {
          'status': 'rejected',
          'error': 'File name contains disallowed path characters',
          'code': 'INVALID_FILE_NAME',
        };
      }
      if (f.fileSize < 0 || f.fileSize > maxSingleFileSize) {
        return {
          'status': 'rejected',
          'error': 'File size exceeds allowed limits: ${f.fileSize}',
          'code': 'EXCESSIVE_FILE_SIZE',
        };
      }
    }

    // E2EE Protocol v2 Validation & Handshake Verification
    final e2ee = pendingRequest.e2ee;
    if (e2ee == null) {
      if (kDebugMode) {
        debugPrint('[OneShare Stream Receiver] REJECTED: Missing E2EE block');
      }
      return {
        'status': 'rejected',
        'error': 'OneShare v2 requires End-to-End Encryption',
        'code': 'PROTOCOL_VERSION_MISMATCH',
      };
    }

    try {
      final rawVersion = e2ee['version'];
      if (rawVersion is! int || rawVersion != 2) {
        if (kDebugMode) {
          debugPrint('[OneShare Stream Receiver] REJECTED: Protocol version mismatch ($rawVersion)');
        }
        return {
          'status': 'rejected',
          'error': 'Unsupported protocol version: $rawVersion (expected integer 2)',
          'code': 'PROTOCOL_VERSION_MISMATCH',
        };
      }

      final manifestHashRaw = e2ee['manifestHash'];
      final senderIdentityPubKeyRaw = e2ee['senderIdentityPubKey'];
      final senderEphemeralPubKeyRaw = e2ee['senderEphemeralPubKey'];
      final senderEphemeralSigRaw = e2ee['senderEphemeralSig'];
      final intendedReceiverIdentityPubKeyRaw =
          e2ee['intendedReceiverIdentityPubKey'];

      if (manifestHashRaw is! String ||
          senderIdentityPubKeyRaw is! String ||
          senderEphemeralPubKeyRaw is! String ||
          senderEphemeralSigRaw is! String ||
          manifestHashRaw.isEmpty ||
          senderIdentityPubKeyRaw.isEmpty ||
          senderEphemeralPubKeyRaw.isEmpty ||
          senderEphemeralSigRaw.isEmpty) {
        return {
          'status': 'rejected',
          'error': 'Malformed E2EE handshake parameters',
          'code': 'INVALID_HANDSHAKE',
        };
      }

      final Uint8List manifestHash;
      final Uint8List senderIdentityPubKey;
      final Uint8List senderEphemeralPubKey;
      final Uint8List senderEphemeralSig;
      Uint8List? intendedReceiverIdentityPubKey;

      try {
        manifestHash = Uint8List.fromList(base64Decode(manifestHashRaw));
        senderIdentityPubKey = Uint8List.fromList(base64Decode(senderIdentityPubKeyRaw));
        senderEphemeralPubKey = Uint8List.fromList(base64Decode(senderEphemeralPubKeyRaw));
        senderEphemeralSig = Uint8List.fromList(base64Decode(senderEphemeralSigRaw));

        if (intendedReceiverIdentityPubKeyRaw != null) {
          if (intendedReceiverIdentityPubKeyRaw is! String) {
            return {
              'status': 'rejected',
              'error': 'Malformed intendedReceiverIdentityPubKey parameter',
              'code': 'INVALID_HANDSHAKE',
            };
          }
          if (intendedReceiverIdentityPubKeyRaw.isNotEmpty) {
            intendedReceiverIdentityPubKey = Uint8List.fromList(
              base64Decode(intendedReceiverIdentityPubKeyRaw),
            );
          }
        }
      } catch (_) {
        return {
          'status': 'rejected',
          'error': 'Invalid Base64 encoding in cryptographic parameters',
          'code': 'INVALID_HANDSHAKE',
        };
      }

      // Exact cryptographic byte-length checks
      if (manifestHash.length != 32 ||
          senderIdentityPubKey.length != 32 ||
          senderEphemeralPubKey.length != 32 ||
          senderEphemeralSig.length != 64 ||
          (intendedReceiverIdentityPubKey != null &&
              intendedReceiverIdentityPubKey.length != 32)) {
        return {
          'status': 'rejected',
          'error': 'Cryptographic parameter byte lengths invalid',
          'code': 'INVALID_HANDSHAKE',
        };
      }

      // 1. Verify manifest hash against received files list
      final manifestItems = pendingRequest.files
          .map((f) => ManifestFileItem(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
              ))
          .toList();
      final expectedManifestHash =
          await E2eeHandshake.computeManifestHash(manifestItems);

      bool manifestMatches = manifestHash.length == expectedManifestHash.length;
      if (manifestMatches) {
        for (int i = 0; i < manifestHash.length; i++) {
          if (manifestHash[i] != expectedManifestHash[i]) {
            manifestMatches = false;
            break;
          }
        }
      }

      if (!manifestMatches) {
        if (kDebugMode) {
          debugPrint('[OneShare Stream Receiver] REJECTED: Manifest hash mismatch');
        }
        return {
          'status': 'rejected',
          'error': 'File manifest integrity check failed',
          'code': 'MANIFEST_HASH_MISMATCH',
        };
      }

      // 2. Verify intended receiver identity binding (if specified)
      final ownIdentity = DeviceIdentityService.identity;
      if (intendedReceiverIdentityPubKey != null) {
        bool identityMatches = intendedReceiverIdentityPubKey.length ==
            ownIdentity.identityPublicKeyBytes.length;
        if (identityMatches) {
          for (int i = 0; i < intendedReceiverIdentityPubKey.length; i++) {
            if (intendedReceiverIdentityPubKey[i] !=
                ownIdentity.identityPublicKeyBytes[i]) {
              identityMatches = false;
              break;
            }
          }
        }
        if (!identityMatches) {
          if (kDebugMode) {
            debugPrint('[OneShare Stream Receiver] REJECTED: Intended receiver identity mismatch');
          }
          return {
            'status': 'rejected',
            'error': 'This transfer was addressed to a different device identity',
            'code': 'IDENTITY_MISMATCH',
          };
        }
      }

      // 3. Verify sender's Ed25519 signature on msg1
      final isSigValid = await E2eeHandshake.verifyMsg1(
        senderIdentityPubKey: senderIdentityPubKey,
        signatureBytes: senderEphemeralSig,
        transferId: pendingRequest.transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: senderEphemeralPubKey,
        intendedReceiverIdentityPubKey: intendedReceiverIdentityPubKey,
      );

      if (!isSigValid) {
        if (kDebugMode) {
          debugPrint('[OneShare Stream Receiver] REJECTED: Invalid msg1 signature');
        }
        return {
          'status': 'rejected',
          'error': 'Cryptographic handshake signature verification failed',
          'code': 'INVALID_SIGNATURE',
        };
      }

      // 4. Initialize receiver E2EE session and hold state
      final session = E2eeSession(
        transferId: pendingRequest.transferId,
        isInitiator: false,
        myIdentityKeyPair: ownIdentity.identityKeyPair,
        myIdentityPubKey: ownIdentity.identityPublicKeyBytes,
      );
      session.peerEphemeralPubKey = senderEphemeralPubKey;
      session.peerIdentityPubKey = senderIdentityPubKey;
      session.manifestHash = manifestHash;
      session.state = E2eeSessionState.msg1Received;
      _incomingE2eeSessions[pendingRequest.transferId] = session;

      // Evaluate peer trust level against trust store
      final senderFp =
          await DeviceIdentityService.computeFingerprint(senderIdentityPubKey);
      final evaluation = await trustStore.evaluatePeer(
        fingerprint: senderFp,
        deviceName: pendingRequest.senderDeviceName,
        deviceId: pendingRequest.senderDeviceId,
      );
      session.peerFingerprint = senderFp;
      session.peerDeviceId = pendingRequest.senderDeviceId;
      session.trustLevel = evaluation.trustLevel;

      // Reject changed identities for known manually verified peers
      if (evaluation.hasIdentityMismatchForDeviceName &&
          evaluation.mismatchedRecord?.trustLevel == TrustLevel.manuallyVerified) {
        if (kDebugMode) {
          debugPrint(
              '[OneShare Stream Receiver] SECURITY REJECTION: Known verified peer "${evaluation.mismatchedRecord!.deviceName}" presented altered identity key.');
        }
        // Preserve original verified record in trustStore untouched.
        // Clean up session and return HTTP 403 / IDENTITY_MISMATCH.
        _incomingE2eeSessions.remove(pendingRequest.transferId)?.destroy();
        return {
          'status': 'rejected',
          'error': 'Security warning: Known verified device presented an unexpected identity key.',
          'code': 'IDENTITY_MISMATCH',
        };
      }

      if (!evaluation.hasIdentityMismatchForDeviceName) {
        await trustStore.recordPeerEncounter(
          fingerprint: senderFp,
          identityPublicKeyBytes: senderIdentityPubKey,
          deviceName: pendingRequest.senderDeviceName,
          deviceId: pendingRequest.senderDeviceId,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Error verifying E2EE handshake: ${LogSanitizer.redact(e.toString())}');
      }
      _incomingE2eeSessions.remove(pendingRequest.transferId)?.destroy();
      return {
        'status': 'rejected',
        'error': 'Handshake verification failed',
        'code': 'HANDSHAKE_ERROR',
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
      e2ee: pendingRequest.e2ee,
    );

    requestWithHost.timer = Timer(const Duration(seconds: 30), () {
      _expireIncomingRequest(requestWithHost.transferId);
    });

    incomingRequestNotifier.value = requestWithHost;

    if (kDebugMode) {
      debugPrint(
          '[OneShare Timestamp] ANDROID incomingRequestNotifier UPDATED transferId=${requestWithHost.transferId} time=${DateTime.now().toIso8601String()}');
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

    _transferTargetHost[transferId] = request.senderHost;
    _transferTargetPort[transferId] = request.senderPort;

    _activeTokens[tokenString] = token;
    _acceptedRequests[transferId] = request;

    // Immediately populate receiveProgressNotifier with metadata so UI shows 0% and file list
    final initialFiles = request.files.map((f) {
      return PerFileTransferState(
        fileId: f.fileId,
        fileName: f.fileName,
        fileSize: f.fileSize,
        bytesTransferred: 0,
        status: FileTransferStatus.waiting,
      );
    }).toList();

    receiveProgressNotifier.value = TransferProgressState(
      transferId: transferId,
      currentFileName: request.files.firstOrNull?.fileName ?? 'Transfer',
      currentFileIndex: 1,
      totalFiles: request.files.length,
      currentFileBytesTransferred: 0,
      currentFileSizeBytes: request.files.firstOrNull?.fileSize ?? 0,
      overallBytesTransferred: 0,
      overallTotalBytes: request.totalSize,
      status: TransferProgressStatus.transferring,
      files: initialFiles,
    );

    final ownIdentity = DeviceIdentityService.identity;
    final session = _incomingE2eeSessions[transferId];
    final tokenHash = await E2eeHandshake.computeTokenHash(tokenString);

    Map<String, dynamic>? e2eePayload;
    if (session != null &&
        session.peerEphemeralPubKey != null &&
        session.peerIdentityPubKey != null &&
        session.manifestHash != null) {
      final ephemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPubKey = Uint8List.fromList(
        (await ephemeralKeyPair.extractPublicKey()).bytes,
      );
      session.myEphemeralKeyPair = ephemeralKeyPair;
      session.myEphemeralPubKey = ephemeralPubKey;
      session.tokenHash = tokenHash;

      final sig2 = await E2eeHandshake.signMsg2(
        receiverIdentityKeyPair: ownIdentity.identityKeyPair,
        transferId: transferId,
        manifestHash: session.manifestHash!,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: ephemeralPubKey,
        senderEphemeralPubKey: session.peerEphemeralPubKey!,
        senderIdentityPubKey: session.peerIdentityPubKey!,
      );

      final transcriptHash = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: session.manifestHash!,
        tokenHash: tokenHash,
        senderIdentityPubKey: session.peerIdentityPubKey!,
        receiverIdentityPubKey: ownIdentity.identityPublicKeyBytes,
        senderEphemeralPubKey: session.peerEphemeralPubKey!,
        receiverEphemeralPubKey: ephemeralPubKey,
      );

      final sharedSecret = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: ephemeralKeyPair,
        peerEphemeralPubKey: session.peerEphemeralPubKey!,
      );

      await session.deriveKeys(
        sharedSecret: sharedSecret,
        transcriptHash: transcriptHash,
      );
      session.state = E2eeSessionState.msg2Sent;
      markHandshakeCompleted(transferId);

      e2eePayload = {
        'version': OneShareConfig.protocolVersion,
        'receiverIdentityPubKey': base64Encode(ownIdentity.identityPublicKeyBytes),
        'receiverEphemeralPubKey': base64Encode(ephemeralPubKey),
        'receiverEphemeralSig': base64Encode(sig2),
      };
    }

    final payload = {
      'transferId': transferId,
      'receiverDeviceId': DeviceIdentityService.identity.deviceId,
      'transferToken': tokenString,
      ...?e2eePayload == null ? null : {'e2ee': e2eePayload},
    };

    try {
      final uri = Uri.http(
        '${request.senderHost}:${request.senderPort}',
        OneShareConfig.transferAcceptPath,
      );
      if (kDebugMode) {
        debugPrint(
            '[OneShare] Sending accept to $uri for transferId: ${LogSanitizer.truncateId(transferId)}');
      }
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      await res.drain();
      if (kDebugMode) {
        debugPrint(
            '[OneShare] Accept request completed with status: ${res.statusCode}');
      }

      // BUG-05/06 FIX: If the sender returns 410 Gone, the request was
      // accepted too late. Clean up receiver state and notify the user.
      if (res.statusCode == HttpStatus.gone) {
        if (kDebugMode) {
          debugPrint('[OneShare] Sender returned 410 — request expired. Cleaning up receiver state.');
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
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OneShare] Error sending accept request: ${LogSanitizer.redact(e.toString())}');
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
        OneShareConfig.transferRejectPath,
      );
      if (kDebugMode) {
        debugPrint(
            '[OneShare] Sending reject to $uri for transferId: ${LogSanitizer.truncateId(transferId)}');
      }
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      await res.drain();
      if (kDebugMode) {
        debugPrint(
            '[OneShare] Reject request completed with status: ${res.statusCode}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[OneShare] Error sending reject request: $e\n$st');
      }
    }
  }

  /// Handles an accept response from the receiver.
  /// Returns [true] if the accept was processed, [false] if the request had
  /// already timed out (BUG-05/06 fix — caller should respond with HTTP 410).
  Future<bool> handleAcceptResponse(Map<String, dynamic> body) async {
    final transferId = body['transferId'] as String?;
    final token = body['transferToken'] as String?;

    if (transferId != null && _outgoingRequests.containsKey(transferId)) {
      final fileItems = _outgoingFileItems[transferId];
      final session = _outgoingE2eeSessions[transferId];

      if (session != null) {
        final e2ee = body['e2ee'] as Map<String, dynamic>?;
        if (e2ee == null) {
          if (kDebugMode) {
            debugPrint('[OneShare] Transfer accept rejected: missing E2EE msg2');
          }
          _outgoingFileItems.remove(transferId);
          _outgoingRequests.remove(transferId)?.complete(
                const TransferRequestOutcome(
                  status: TransferResultStatus.failed,
                  message: 'Peer did not include E2EE handshake response',
                ),
              );
          return true;
        }

        try {
          final rawVersion = e2ee['version'];
          if (rawVersion is! int || rawVersion != 2) {
            throw const FormatException('Unsupported E2EE protocol version in accept response');
          }

          final receiverIdentityPubKeyRaw = e2ee['receiverIdentityPubKey'];
          final receiverEphemeralPubKeyRaw = e2ee['receiverEphemeralPubKey'];
          final receiverEphemeralSigRaw = e2ee['receiverEphemeralSig'];

          if (receiverIdentityPubKeyRaw is! String ||
              receiverEphemeralPubKeyRaw is! String ||
              receiverEphemeralSigRaw is! String ||
              receiverIdentityPubKeyRaw.isEmpty ||
              receiverEphemeralPubKeyRaw.isEmpty ||
              receiverEphemeralSigRaw.isEmpty ||
              token == null ||
              token.isEmpty) {
            throw const FormatException('Malformed E2EE accept parameters');
          }

          final Uint8List receiverIdentityPubKey;
          final Uint8List receiverEphemeralPubKey;
          final Uint8List receiverEphemeralSig;

          try {
            receiverIdentityPubKey = Uint8List.fromList(
                base64Decode(receiverIdentityPubKeyRaw));
            receiverEphemeralPubKey = Uint8List.fromList(
                base64Decode(receiverEphemeralPubKeyRaw));
            receiverEphemeralSig = Uint8List.fromList(
                base64Decode(receiverEphemeralSigRaw));
          } catch (_) {
            throw const FormatException('Invalid Base64 in E2EE accept parameters');
          }

          if (receiverIdentityPubKey.length != 32 ||
              receiverEphemeralPubKey.length != 32 ||
              receiverEphemeralSig.length != 64) {
            throw const FormatException('Invalid cryptographic parameter lengths in accept response');
          }

          session.peerIdentityPubKey = receiverIdentityPubKey;
          session.peerEphemeralPubKey = receiverEphemeralPubKey;

          final tokenHash = await E2eeHandshake.computeTokenHash(token);
          session.tokenHash = tokenHash;

          // Verify pinned receiver identity if specified in msg1
          if (session.intendedReceiverIdentityPubKey != null) {
            final pinned = session.intendedReceiverIdentityPubKey!;
            bool pinMatches = pinned.length == receiverIdentityPubKey.length;
            if (pinMatches) {
              for (int i = 0; i < pinned.length; i++) {
                if (pinned[i] != receiverIdentityPubKey[i]) {
                  pinMatches = false;
                  break;
                }
              }
            }
            if (!pinMatches) {
              if (kDebugMode) {
                debugPrint('[OneShare Stream Sender] ABORT: Receiver msg2 identity public key does not match pinned key');
              }
              throw StateError('Receiver identity mismatch: public key does not match pinned verified identity');
            }
          }

          // Verify receiver's signature on msg2
          final isSigValid = await E2eeHandshake.verifyMsg2(
            receiverIdentityPubKey: receiverIdentityPubKey,
            signatureBytes: receiverEphemeralSig,
            transferId: transferId,
            manifestHash: session.manifestHash!,
            tokenHash: tokenHash,
            receiverEphemeralPubKey: receiverEphemeralPubKey,
            senderEphemeralPubKey: session.myEphemeralPubKey!,
            senderIdentityPubKey: session.myIdentityPubKey,
          );

          if (!isSigValid) {
            throw StateError('Invalid cryptographic signature on msg2 from receiver');
          }

          // Compute transcript hash & derive keys
          final transcriptHash = await E2eeHandshake.computeTranscriptHash(
            transferId: transferId,
            manifestHash: session.manifestHash!,
            tokenHash: tokenHash,
            senderIdentityPubKey: session.myIdentityPubKey,
            receiverIdentityPubKey: receiverIdentityPubKey,
            senderEphemeralPubKey: session.myEphemeralPubKey!,
            receiverEphemeralPubKey: receiverEphemeralPubKey,
          );

          final sharedSecret = await E2eeHandshake.computeSharedSecret(
            myEphemeralKeyPair: session.myEphemeralKeyPair!,
            peerEphemeralPubKey: receiverEphemeralPubKey,
          );

          await session.deriveKeys(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
          );
          session.state = E2eeSessionState.keysDerived;
          markHandshakeCompleted(transferId);

          // Best-effort zeroization of ephemeral private key
          if (session.myEphemeralKeyPair != null) {
            try {
              final priv = await session.myEphemeralKeyPair!.extractPrivateKeyBytes();
              priv.fillRange(0, priv.length, 0);
            } catch (_) {}
            session.myEphemeralKeyPair = null;
          }

          // Evaluate receiver trust in TrustStore
          final receiverFp = await DeviceIdentityService.computeFingerprint(receiverIdentityPubKey);
          final eval = await trustStore.evaluatePeer(
            fingerprint: receiverFp,
            deviceName: 'Receiver',
            deviceId: body['receiverDeviceId'] as String? ?? '',
          );
          session.peerFingerprint = receiverFp;
          session.peerDeviceId = body['receiverDeviceId'] as String? ?? '';
          session.trustLevel = eval.trustLevel;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[OneShare] E2EE msg2 verification failed: $e');
          }
          _cleanupTransferState(transferId);
          _outgoingFileItems.remove(transferId);
          _outgoingRequests.remove(transferId)?.complete(
                TransferRequestOutcome(
                  status: TransferResultStatus.failed,
                  message: 'E2EE handshake verification failed: $e',
                ),
              );
          return true;
        }
      }

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
          '[OneShare Stream Receiver] Connection opened from $clientIp for endpoint ${request.uri.path}');
    }

    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Missing or invalid Authorization header');
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
          '[OneShare Stream Receiver] transferId: $transferId, fileId: $fileId, fileName: $rawFileName, declaredSize: $declaredSize');
    }

    // 1. Check pending accepted request
    final pendingReq = _acceptedRequests[transferId];
    if (pendingReq == null) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Transfer ID $transferId not active or accepted');
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
            '[OneShare Stream Receiver] Invalid or expired token for fileId $fileId');
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
            '[OneShare Stream Receiver] Sender device ID mismatch');
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
            '[OneShare Stream Receiver] Token transfer ID mismatch');
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
            '[OneShare Stream Receiver] File ID $fileId not found in transfer metadata');
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
            '[OneShare Stream Receiver] Filename mismatch: got $rawFileName, expected ${expectedFileItem.fileName}');
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
    // not known at selection time). Also skip for E2EE v2 transfers because
    // chunked transfer encoding is used and content-length is omitted.
    // The actual byte-count check after the stream is complete serves as the
    // real guard for known-size files.
    final session = _incomingE2eeSessions[transferId];
    if (session == null &&
        expectedFileItem.fileSize > 0 &&
        declaredSize != -1 &&
        declaredSize != expectedFileItem.fileSize) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Size mismatch: got $declaredSize, expected ${expectedFileItem.fileSize}');
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
    // declared content-length if provided (> 0). Otherwise, cap at maxUnknownFileSize (2 GB)
    // to prevent adversarial streams from filling storage.
    const int maxUnknownFileSize = 2 * 1024 * 1024 * 1024; // 2 GB
    final expectedSize = (expectedFileItem.fileSize == 0 && declaredSize > 0)
        ? declaredSize
        : (expectedFileItem.fileSize == 0 ? maxUnknownFileSize : expectedFileItem.fileSize);

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
          File(p.join(targetFile.parent.path, '.oneshare_${transferId}_$fileId.tmp'));

      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Temp file path: ${LogSanitizer.sanitizePath(tempFile.path)}');
        debugPrint(
            '[OneShare Stream Receiver] Target destination path: ${LogSanitizer.sanitizePath(targetFile.path)}');
      }

      if (await tempFile.exists()) {
        if (kDebugMode) {
          debugPrint(
              '[OneShare Stream Receiver] Deleting existing stale temp file at ${LogSanitizer.sanitizePath(tempFile.path)}');
        }
        await tempFile.delete();
      }

      sink = tempFile.openWrite();
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Error setting up destination file/temp file: ${LogSanitizer.redact(e.toString())}');
      }
      _setReceiverProgressFailed(
          transferId, 'Could not create destination file');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'Could not create destination file',
        'FILE_CREATION_ERROR',
      );
      return;
    }

    _activeIncomingHttpRequests[transferId] = request;
    _activeIncomingSinks[transferId] = sink;
    _activeIncomingTempFiles[transferId] = tempFile;

    if (kDebugMode) {
      debugPrint(
          '[OneShare Stream Receiver] Opened write sink for ${LogSanitizer.sanitizePath(tempFile.path)}');
    }

    int actualBytesReceived = 0;
    int unflushedBytes = 0;
    const flushThreshold = 2 * 1024 * 1024; // 2 MB backpressure threshold
    bool sizeExceeded = false;

    if (kDebugMode) {
      debugPrint(
          '[OneShare Stream Receiver] Start reading request stream for $rawFileName. Expected size: $expectedSize bytes');
    }

    try {
      final session = _incomingE2eeSessions[transferId];
      if (session != null) {
        // E2EE stream: pipe request through EncryptedStreamReader
        final fileKey = await session.deriveIncomingFileKeyForId(fileId);
        final reader = EncryptedStreamReader(
          fileKey: fileKey,
          transferId: transferId,
          fileId: fileId,
        );

        final decryptedStream = reader.processStream(request);
        await for (final chunk in decryptedStream) {
          if (isTransferCancelled(transferId) || isFileCancelled(transferId, fileId)) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Receiver] Stream reading aborted for $rawFileName due to cancellation');
            }
            await sink.close();
            _activeIncomingSinks.remove(transferId);
            if (await tempFile.exists()) {
              try {
                await tempFile.delete();
              } catch (_) {}
            }
            _activeIncomingTempFiles.remove(transferId);
            _activeIncomingHttpRequests.remove(transferId);
            return;
          }

          actualBytesReceived += chunk.length;
          unflushedBytes += chunk.length;

          if (expectedSize > 0 && actualBytesReceived > expectedSize) {
            sizeExceeded = true;
            break;
          }
          sink.add(chunk);

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
      } else {
        // Non-E2EE stream (legacy or tests)
        await for (final chunk in request) {
          if (isTransferCancelled(transferId) || isFileCancelled(transferId, fileId)) {
            if (kDebugMode) {
              debugPrint(
                  '[OneShare Stream Receiver] Stream reading aborted for $rawFileName due to cancellation');
            }
            await sink.close();
            _activeIncomingSinks.remove(transferId);
            if (await tempFile.exists()) {
              try {
                await tempFile.delete();
              } catch (_) {}
            }
            _activeIncomingTempFiles.remove(transferId);
            _activeIncomingHttpRequests.remove(transferId);
            return;
          }

          actualBytesReceived += chunk.length;
          unflushedBytes += chunk.length;
          if (kDebugMode && (actualBytesReceived % (1024 * 1024) == 0 || actualBytesReceived < 100 * 1024)) {
            debugPrint('[DIAGNOSTIC] Receiver chunk loop: actualBytesReceived: $actualBytesReceived');
          }

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
      }
      await sink.flush();
      await sink.close();
      _activeIncomingSinks.remove(transferId);

      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Stream read complete. Expected: $expectedSize, Actual bytes received: $actualBytesReceived');
      }
    } catch (e) {
      _activeIncomingSinks.remove(transferId);
      if (kDebugMode) {
        debugPrint('[DIAGNOSTIC] handleIncomingFileUpload catch block. error: $e');
        debugPrint('[DIAGNOSTIC] isTransferCancelled: ${isTransferCancelled(transferId)}');
        debugPrint('[DIAGNOSTIC] actualBytesReceived: $actualBytesReceived');
      }
      await Future.delayed(const Duration(milliseconds: 50));
      if (isTransferCancelled(transferId)) {
        if (await tempFile.exists()) {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
        _activeIncomingTempFiles.remove(transferId);
        _activeIncomingHttpRequests.remove(transferId);
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Exception receiving stream for $rawFileName: ${LogSanitizer.redact(e.toString())}');
      }

      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      _incomingE2eeSessions.remove(transferId)?.destroy();
      _setReceiverProgressFailed(
          transferId, 'Error receiving stream for $rawFileName');
      await _sendErrorResponse(
        request,
        HttpStatus.internalServerError,
        'Error receiving data stream',
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
      _activeIncomingTempFiles.remove(transferId);
      _activeIncomingHttpRequests.remove(transferId);
      return;
    }

    // BUG-12 FIX: For files with known size, verify byte count. For
    // expectedFileItem.fileSize == 0 (unknown at selection time), verify it didn't exceed
    // the 2 GB cap (sizeExceeded == false).
    final isKnownSize = expectedFileItem.fileSize > 0 || declaredSize > 0;
    if (sizeExceeded || (isKnownSize && actualBytesReceived != expectedSize)) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] Byte count mismatch: expected $expectedSize, got $actualBytesReceived (sizeExceeded: $sizeExceeded)');
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
        'Byte count mismatch',
        'BYTE_COUNT_MISMATCH',
      );
      return;
    }

    // Pre-finalization checks
    final tempExists = await tempFile.exists();
    final tempSize = tempExists ? await tempFile.length() : -1;

    if (kDebugMode) {
      debugPrint('[OneShare Stream Receiver] ANDROID RECEIVE:');
      debugPrint('  transferId=${LogSanitizer.truncateId(transferId)}');
      debugPrint('  file=$rawFileName');
      debugPrint('  expectedBytes=$expectedSize');
      debugPrint('  receivedBytes=$actualBytesReceived');
      debugPrint('  tempPath=${LogSanitizer.sanitizePath(tempFile.path)}');
      debugPrint('  tempFileExists=$tempExists');
      debugPrint('  tempFileSize=$tempSize');
      debugPrint('  finalPath=${LogSanitizer.sanitizePath(targetFile.path)}');
    }

    // BUG-12 FIX: For size=0 expected (unknown-size cloud files), skip the
    // strict pre-finalization size comparison with the cap.
    final prefinalizationOk = tempExists &&
        (!isKnownSize || tempSize == expectedSize) &&
        !isTransferCancelled(transferId);

    if (!prefinalizationOk) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] ANDROID RECEIVE: Pre-finalization verification failed or cancelled');
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
      debugPrint('[OneShare Stream Receiver] ANDROID RECEIVE: finalization started');
    }

    try {
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] ANDROID RECEIVE: finalization operation=tempFile.rename');
      }
      await tempFile.rename(targetFile.path);
    } catch (e) {
      finalizationOp = 'copy_fallback';
      finalizationException = e;
      if (kDebugMode) {
        debugPrint(
            '[OneShare Stream Receiver] ANDROID RECEIVE: finalization operation=copy_fallback (rename failed: $e)');
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
              '[OneShare Stream Receiver] ANDROID RECEIVE: finalization exception=$copyError\n$copySt');
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
      debugPrint('[OneShare Stream Receiver] ANDROID RECEIVE:');
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
            '[OneShare Stream Receiver] ANDROID RECEIVE: Final file verification failed: exists=$finalExists, expectedSize=$expectedSize, finalSize=$finalSize');
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
        'File finalization failed',
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
    _activeIncomingTempFiles.remove(transferId);
    _activeIncomingHttpRequests.remove(transferId);

    if (kDebugMode) {
      debugPrint(
          '[OneShare Stream Receiver] Connection closed cleanly for fileId $fileId');
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

    final totalExpected = pendingReq.files.length;
    final cancelledCount =
        pendingReq.files.where((f) => isFileCancelled(transferId, f.fileId)).length;

    if (set.length + cancelledCount >= totalExpected) {
      // All files in batch accounted for (received or cancelled)!
      final currentRecvState = receiveProgressNotifier.value;
      final finalFiles = pendingReq.files.map((f) {
        if (isFileCancelled(transferId, f.fileId)) {
          final existing = currentRecvState?.files.firstWhere(
            (sf) => sf.fileId == f.fileId,
            orElse: () => PerFileTransferState(
              fileId: f.fileId,
              fileName: f.fileName,
              fileSize: f.fileSize,
              bytesTransferred: 0,
              status: FileTransferStatus.cancelled,
              errorMessage: 'Cancelled',
            ),
          );
          return existing ??
              PerFileTransferState(
                fileId: f.fileId,
                fileName: f.fileName,
                fileSize: f.fileSize,
                bytesTransferred: 0,
                status: FileTransferStatus.cancelled,
                errorMessage: 'Cancelled',
              );
        }
        return PerFileTransferState(
          fileId: f.fileId,
          fileName: f.fileName,
          fileSize: f.fileSize,
          bytesTransferred: f.fileSize,
          status: FileTransferStatus.completed,
        );
      }).toList();

      final allCompleted =
          finalFiles.every((f) => f.status == FileTransferStatus.completed);
      final anyCancelled =
          finalFiles.any((f) => f.status == FileTransferStatus.cancelled) ||
              isTransferCancelled(transferId);
      final anyFailed =
          finalFiles.any((f) => f.status == FileTransferStatus.failed);

      final TransferProgressStatus finalStatus;
      if (allCompleted) {
        finalStatus = TransferProgressStatus.completed;
      } else if (anyCancelled) {
        finalStatus = TransferProgressStatus.cancelled;
      } else if (anyFailed) {
        finalStatus = TransferProgressStatus.failed;
      } else {
        finalStatus = TransferProgressStatus.failed;
      }

      final finalOverallTransferred = finalFiles.fold<int>(
        0,
        (sum, f) => sum + f.bytesTransferred,
      );

      receiveProgressNotifier.value = TransferProgressState(
        transferId: transferId,
        currentFileName: pendingReq.files.last.fileName,
        currentFileIndex: pendingReq.files.length,
        totalFiles: pendingReq.files.length,
        currentFileBytesTransferred: pendingReq.files.last.fileSize,
        currentFileSizeBytes: pendingReq.files.last.fileSize,
        overallBytesTransferred: finalOverallTransferred,
        overallTotalBytes: pendingReq.totalSize,
        status: finalStatus,
        destinationPath: savedPath,
        files: finalFiles,
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
      downloadsDir = Directory('/storage/emulated/0/Download/OneShare');
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

      downloadsDir = Directory(p.join(baseDownloadsPath, 'OneShare'));
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
      const channel = MethodChannel('com.oneshare.app/uri_stream');
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
        onChunk(chunk.length);
        if (isTransferCancelled(transferId)) {
          break;
        }
        yield chunk;
      }
    }
  }
}
