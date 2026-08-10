import 'dart:io';

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

  static String _formatDestinationPath(String? path) {
    if (path == null || path.isEmpty) return '~/Downloads/DropLAN/';
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
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
              ] else if (isCompleted) ...[
                Text(
                  state.totalFiles == 1
                      ? 'Successfully received ${state.currentFileName}'
                      : 'Successfully received ${state.totalFiles} files',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.task_alt, color: Colors.green, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '100% • ${_formatFileSize(state.overallTotalBytes)} transferred',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.green.shade900,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Saved to:',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  _formatDestinationPath(state.destinationPath),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.primary,
                  ),
                ),
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
            if (isCompleted)
              FilledButton(
                onPressed: () {
                  TransferService.instance.progressNotifier.value = null;
                  Navigator.of(context).maybePop();
                },
                child: const Text('Done'),
              )
            else if (isFailed)
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
