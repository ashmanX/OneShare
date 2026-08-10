import 'package:flutter/material.dart';

import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/transfer_service.dart';

class TransferProgressDialog extends StatelessWidget {
  const TransferProgressDialog({super.key});

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

    return ValueListenableBuilder<TransferProgressState?>(
      valueListenable: TransferService.instance.progressNotifier,
      builder: (context, state, _) {
        if (state == null) {
          return const SizedBox.shrink();
        }

        final isCompleted = state.status == TransferProgressStatus.completed;
        final isFailed = state.status == TransferProgressStatus.failed;

        return AlertDialog(
          title: Row(
            children: [
              Icon(
                isCompleted
                    ? Icons.check_circle
                    : isFailed
                        ? Icons.error
                        : Icons.sync,
                color: isCompleted
                    ? Colors.green
                    : isFailed
                        ? Colors.red
                        : theme.colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isCompleted
                      ? 'Transfer Complete'
                      : isFailed
                          ? 'Transfer Failed'
                          : 'Transferring Files...',
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isFailed) ...[
                Text(
                  state.errorMessage ?? 'An error occurred during transfer.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.red.shade800,
                  ),
                ),
                const SizedBox(height: 12),
              ] else ...[
                Text(
                  'File ${state.currentFileIndex} of ${state.totalFiles}: ${state.currentFileName}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: state.overallProgress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'File: ${_formatFileSize(state.currentFileBytesTransferred)} / ${_formatFileSize(state.currentFileSizeBytes)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${(state.overallProgress * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Overall: ${_formatFileSize(state.overallBytesTransferred)} / ${_formatFileSize(state.overallTotalBytes)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (isCompleted || isFailed)
              FilledButton(
                onPressed: () {
                  TransferService.instance.progressNotifier.value = null;
                  Navigator.of(context).maybePop();
                },
                child: const Text('Close'),
              ),
          ],
        );
      },
    );
  }
}
