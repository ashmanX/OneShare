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
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID IncomingTransferDialog BUILD/SHOW transferId=${widget.request.transferId} time=${DateTime.now().toIso8601String()}');
    }

    TransferService.instance.incomingRequestNotifier
        .addListener(_onIncomingRequestChanged);

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

  void _onIncomingRequestChanged() {
    if (_isClosing) return;
    final current = TransferService.instance.incomingRequestNotifier.value;
    if (current == null || current.transferId != widget.request.transferId) {
      _isClosing = true;
      _countdownTimer?.cancel();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop('cancelled_by_sender');
      }
    }
  }

  @override
  void dispose() {
    TransferService.instance.incomingRequestNotifier
        .removeListener(_onIncomingRequestChanged);
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
    if (_isClosing) return;
    _isClosing = true;
    _countdownTimer?.cancel();

    final transferId = widget.request.transferId;

    TransferService.instance.acceptIncomingRequest(transferId);

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop('accepted');
    }
  }

  void _rejectAndClose(String reason) {
    if (_isClosing) return;
    _isClosing = true;
    _countdownTimer?.cancel();

    final transferId = widget.request.transferId;

    TransferService.instance.rejectIncomingRequest(
      transferId,
      reason,
    );

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop('rejected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;

    final fileCount = request.files.length;
    final fileLabel = fileCount == 1 ? 'file' : 'files';

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: Color(0xFF1F2232), width: 1),
      ),
      backgroundColor: const Color(0xFF12141D),
      elevation: 20,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 320,
          maxWidth: 440,
          maxHeight: 560,
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A233D),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.swap_horizontal_circle_rounded,
                      size: 28,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Incoming\nTransfer',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              'From ',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                color: const Color(0xFF8E95A5),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                request.senderDeviceName,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  color: const Color(0xFF38BDF8),
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

              const SizedBox(height: 20),

              Text(
                'Wants to share $fileCount $fileLabel with you:',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF8E95A5),
                ),
              ),

              const SizedBox(height: 10),

              Container(
                constraints: const BoxConstraints(
                  maxHeight: 200,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF090B10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF1F2232),
                  ),
                ),
                child: Scrollbar(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: fileCount,
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      color: Color(0xFF1F2232),
                    ),
                    itemBuilder: (context, index) {
                      final file = request.files[index];

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A233D),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.insert_drive_file_rounded,
                                color: Color(0xFF38BDF8),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                file.fileName,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _formatFileSize(file.fileSize),
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF8E95A5),
                              ),
                            ),
                          ],
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _remainingSeconds <= 10
                          ? const Color(0xFFEF4444).withValues(alpha: 0.15)
                          : const Color(0xFF1A233D),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _remainingSeconds <= 10
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF38BDF8).withValues(alpha: 0.6),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: _remainingSeconds <= 10
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF38BDF8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_remainingSeconds}s',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _remainingSeconds <= 10
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF38BDF8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          _rejectAndClose('user_rejected');
                        },
                        icon: const Icon(Icons.close_rounded, size: 16),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Decline',
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          foregroundColor: const Color(0xFFEF4444),
                          side: BorderSide(
                            color: const Color(0xFFEF4444).withValues(alpha: 0.35),
                            width: 1,
                          ),
                          textStyle: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF0EA5E9), Color(0xFF0284C7)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0EA5E9)
                                  .withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _acceptAndClose,
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Accept',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
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