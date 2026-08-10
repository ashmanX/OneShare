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
  State<IncomingTransferDialog> createState() => _IncomingTransferDialogState();
}

class _IncomingTransferDialogState extends State<IncomingTransferDialog> {
  late int _remainingSeconds;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = 30;
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds <= 1) {
        timer.cancel();
        if (mounted) {
          Navigator.of(context).maybePop();
        }
      } else {
        if (mounted) {
          setState(() {
            _remainingSeconds--;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = widget.request;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.swap_horizontal_circle,
              color: theme.colorScheme.primary, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Incoming Transfer'),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${req.senderDeviceName} wants to send you ${req.files.length} file${req.files.length > 1 ? 's' : ''}:',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(maxHeight: 140),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.all(8),
                itemCount: req.files.length,
                separatorBuilder: (_, _) => const Divider(height: 8),
                itemBuilder: (context, index) {
                  final file = req.files[index];
                  return Row(
                    children: [
                      const Icon(Icons.insert_drive_file, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          file.fileName,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatFileSize(file.fileSize),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total size: ${_formatFileSize(req.totalSize)}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Expires in ${_remainingSeconds}s',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            TransferService.instance
                .rejectIncomingRequest(req.transferId, 'user_rejected');
            Navigator.of(context).pop();
          },
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () {
            TransferService.instance.acceptIncomingRequest(req.transferId);
            Navigator.of(context).pop();
          },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}
