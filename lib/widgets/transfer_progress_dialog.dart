import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
    return ValueListenableBuilder<TransferProgressState?>(
      valueListenable: TransferService.instance.progressNotifier,
      builder: (context, state, _) {
        if (state == null) {
          return const SizedBox.shrink();
        }

        final isCompleted = state.status == TransferProgressStatus.completed;
        final isFailed = state.status == TransferProgressStatus.failed;

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFF334155), width: 1.5),
          ),
          backgroundColor: const Color(0xFF141C2E),
          elevation: 16,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isCompleted
                      ? const Color(0xFF10B981).withValues(alpha: 0.2)
                      : isFailed
                          ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                          : const Color(0xFF6366F1).withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCompleted
                        ? const Color(0xFF10B981).withValues(alpha: 0.4)
                        : isFailed
                            ? const Color(0xFFF87171).withValues(alpha: 0.4)
                            : const Color(0xFF818CF8).withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(
                  isCompleted
                      ? Icons.check_circle_rounded
                      : isFailed
                          ? Icons.error_rounded
                          : Icons.sync_rounded,
                  color: isCompleted
                      ? const Color(0xFF10B981)
                      : isFailed
                          ? const Color(0xFFF87171)
                          : const Color(0xFF818CF8),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  isCompleted
                      ? 'Transfer Complete'
                      : isFailed
                          ? 'Transfer Failed'
                          : 'Transferring Files...',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
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
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFF87171),
                  ),
                ),
                const SizedBox(height: 12),
              ] else if (isCompleted) ...[
                Text(
                  state.totalFiles == 1
                      ? 'Successfully received ${state.currentFileName}'
                      : 'Successfully received ${state.totalFiles} files',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFF8FAFC),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.task_alt_rounded,
                        color: Color(0xFF10B981),
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '100% • ${_formatFileSize(state.overallTotalBytes)} transferred',
                          style: GoogleFonts.plusJakartaSans(
                            color: const Color(0xFF10B981),
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Saved to:',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    color: const Color(0xFFCBD5E1),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B0F19),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF334155),
                    ),
                  ),
                  child: SelectableText(
                    _formatDestinationPath(state.destinationPath),
                    style: GoogleFonts.firaCode(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF818CF8),
                    ),
                  ),
                ),
              ] else ...[
                Text(
                  'File ${state.currentFileIndex} of ${state.totalFiles}: ${state.currentFileName}',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: state.overallProgress,
                    minHeight: 10,
                    backgroundColor: const Color(0xFF0B0F19),
                    color: const Color(0xFF6366F1),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'File: ${_formatFileSize(state.currentFileBytesTransferred)} / ${_formatFileSize(state.currentFileSizeBytes)}',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFFCBD5E1),
                      ),
                    ),
                    Text(
                      '${(state.overallProgress * 100).toStringAsFixed(0)}%',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF818CF8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Overall: ${_formatFileSize(state.overallBytesTransferred)} / ${_formatFileSize(state.overallTotalBytes)}',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFCBD5E1),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (isCompleted || isFailed)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () {
                    TransferService.instance.progressNotifier.value = null;
                    Navigator.of(context).maybePop();
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  child: Text(isCompleted ? 'Done' : 'Close'),
                ),
              ),
          ],
        );
      },
    );
  }
}
