import 'dart:async';

class TransferFileItem {
  const TransferFileItem({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
  });

  final String fileId;
  final String fileName;
  final int fileSize;

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
      };

  factory TransferFileItem.fromJson(Map<String, dynamic> json) {
    return TransferFileItem(
      fileId: json['fileId'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
    );
  }
}

enum TransferResultStatus {
  accepted,
  rejected,
  expired,
  failed,
}

class TransferRequestOutcome {
  const TransferRequestOutcome({
    required this.status,
    this.transferId,
    this.transferToken,
    this.reason,
    this.message,
    this.fileItems,
  });

  final TransferResultStatus status;
  final String? transferId;
  final String? transferToken;
  final String? reason;
  final String? message;
  final List<TransferFileItem>? fileItems;
}

class PendingTransferRequest {
  PendingTransferRequest({
    required this.transferId,
    required this.senderDeviceId,
    required this.senderDeviceName,
    required this.senderHost,
    required this.senderPort,
    required this.files,
    required this.receivedAt,
    this.timer,
  });

  final String transferId;
  final String senderDeviceId;
  final String senderDeviceName;
  final String senderHost;
  final int senderPort;
  final List<TransferFileItem> files;
  final DateTime receivedAt;
  Timer? timer;

  int get totalSize => files.fold(0, (sum, item) => sum + item.fileSize);

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'senderDeviceId': senderDeviceId,
        'senderDeviceName': senderDeviceName,
        'senderHost': senderHost,
        'senderPort': senderPort,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory PendingTransferRequest.fromJson(Map<String, dynamic> json) {
    final filesList = (json['files'] as List<dynamic>?)
            ?.map((e) => TransferFileItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return PendingTransferRequest(
      transferId: json['transferId'] as String? ?? '',
      senderDeviceId: json['senderDeviceId'] as String? ?? '',
      senderDeviceName: json['senderDeviceName'] as String? ?? '',
      senderHost: json['senderHost'] as String? ?? '',
      senderPort: (json['senderPort'] as num?)?.toInt() ?? 4040,
      files: filesList,
      receivedAt: DateTime.now(),
    );
  }
}

class TransferToken {
  const TransferToken({
    required this.token,
    required this.transferId,
    required this.senderDeviceId,
    required this.allowedFileIds,
    required this.expiresAt,
  });

  final String token;
  final String transferId;
  final String senderDeviceId;
  final Set<String> allowedFileIds;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

enum TransferProgressStatus {
  idle,
  transferring,
  completed,
  failed,
  cancelled,
}

enum FileTransferStatus {
  waiting,
  transferring,
  completed,
  failed,
  cancelled,
}

class PerFileTransferState {
  const PerFileTransferState({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.bytesTransferred,
    required this.status,
    this.errorMessage,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
  final int bytesTransferred;
  final FileTransferStatus status;
  final String? errorMessage;

  double get progress => fileSize == 0
      ? 1.0
      : (bytesTransferred / fileSize).clamp(0.0, 1.0);
}

class TransferProgressState {
  const TransferProgressState({
    required this.transferId,
    required this.currentFileName,
    required this.currentFileIndex,
    required this.totalFiles,
    required this.currentFileBytesTransferred,
    required this.currentFileSizeBytes,
    required this.overallBytesTransferred,
    required this.overallTotalBytes,
    required this.status,
    this.files = const [],
    this.errorMessage,
    this.destinationPath,
  });

  final String transferId;
  final String currentFileName;
  final int currentFileIndex;
  final int totalFiles;
  final int currentFileBytesTransferred;
  final int currentFileSizeBytes;
  final int overallBytesTransferred;
  final int overallTotalBytes;
  final TransferProgressStatus status;
  final List<PerFileTransferState> files;
  final String? errorMessage;
  final String? destinationPath;

  double get currentFileProgress => currentFileSizeBytes == 0
      ? 1.0
      : (currentFileBytesTransferred / currentFileSizeBytes).clamp(0.0, 1.0);

  double get overallProgress => overallTotalBytes == 0
      ? 1.0
      : (overallBytesTransferred / overallTotalBytes).clamp(0.0, 1.0);
}

