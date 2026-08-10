import 'dart:async';

import 'package:flutter/material.dart';

import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/transfer_service.dart';

class IncomingTransferDialog extends StatefulWidget {
  const IncomingTransferDialog({
    super.key,
    required this.request,
  });

  final PendingTransferRequest request;

  @override
  State<IncomingTransferDialog> createState() =>
      _IncomingTransferDialogState();
}

class _IncomingTransferDialogState extends State<IncomingTransferDialog> {
  Timer? _countdownTimer;
  int _remainingSeconds = 30;

  @override
  void initState() {
    super.initState();

    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_remainingSeconds <= 1) {
          timer.cancel();
          _rejectAndClose('timeout');
          return;
        }

        setState(() {
          _remainingSeconds--;
        });
      },
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void _acceptAndClose() {
    _countdownTimer?.cancel();

    final transferId = widget.request.transferId;

    TransferService.instance.acceptIncomingRequest(transferId);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _rejectAndClose(String reason) {
    _countdownTimer?.cancel();

    final transferId = widget.request.transferId;

    TransferService.instance.rejectIncomingRequest(
      transferId,
      reason,
    );

    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;

    final fileCount = request.files.length;
    final fileLabel = fileCount == 1 ? 'file' : 'files';

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 420,
          maxWidth: 560,
          maxHeight: 620,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.swap_horizontal_circle,
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Incoming Transfer',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              Text(
                '${request.senderDeviceName} wants to send you '
                '$fileCount $fileLabel.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 16),

              Container(
                constraints: const BoxConstraints(
                  maxHeight: 220,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Scrollbar(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: fileCount,
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                    itemBuilder: (context, index) {
                      final file = request.files[index];

                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.insert_drive_file,
                        ),
                        title: Text(
                          file.fileName,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          _formatFileSize(file.fileSize),
                          style: theme.textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Total: ${_formatFileSize(request.totalSize)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$_remainingSeconds s',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _remainingSeconds <= 10
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      _rejectAndClose('user_rejected');
                    },
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _acceptAndClose,
                    icon: const Icon(Icons.check),
                    label: const Text('Accept'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}