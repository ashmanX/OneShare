import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID IncomingTransferDialog BUILD/SHOW transferId=${widget.request.transferId} time=${DateTime.now().toIso8601String()}');
    }

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
    final request = widget.request;

    final fileCount = request.files.length;
    final fileLabel = fileCount == 1 ? 'file' : 'files';

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF334155), width: 1.5),
      ),
      backgroundColor: const Color(0xFF141C2E),
      elevation: 16,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 380,
          maxWidth: 500,
          maxHeight: 600,
        ),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(
                      Icons.swap_horizontal_circle_rounded,
                      size: 28,
                      color: Color(0xFF818CF8),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Incoming Transfer',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              'From ',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 14,
                                color: const Color(0xFFCBD5E1),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                request.senderDeviceName,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14,
                                  color: const Color(0xFF818CF8),
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),

              Text(
                'Wants to share $fileCount $fileLabel with you:',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFF8FAFC),
                ),
              ),

              const SizedBox(height: 12),

              Container(
                constraints: const BoxConstraints(
                  maxHeight: 220,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0F19),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF334155),
                  ),
                ),
                child: Scrollbar(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: fileCount,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                    ),
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      color: Color(0xFF1E293B),
                    ),
                    itemBuilder: (context, index) {
                      final file = request.files[index];

                      return ListTile(
                        dense: true,
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.insert_drive_file_rounded,
                            color: Color(0xFF818CF8),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          file.fileName,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        trailing: Text(
                          _formatFileSize(file.fileSize),
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFCBD5E1),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total Size: ${_formatFileSize(request.totalSize)}',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _remainingSeconds <= 10
                          ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                          : const Color(0xFF6366F1).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _remainingSeconds <= 10
                            ? const Color(0xFFF87171)
                            : const Color(0xFF818CF8),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: _remainingSeconds <= 10
                              ? const Color(0xFFF87171)
                              : const Color(0xFF818CF8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_remainingSeconds}s',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _remainingSeconds <= 10
                                ? const Color(0xFFF87171)
                                : const Color(0xFF818CF8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      _rejectAndClose('user_rejected');
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      foregroundColor: const Color(0xFFF87171),
                      side: const BorderSide(
                        color: Color(0xFFEF4444),
                        width: 1.2,
                      ),
                      textStyle: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _acceptAndClose,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Accept'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
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