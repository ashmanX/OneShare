import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/device_identity_service.dart';
import 'package:droplan/services/droplan_discovery_service.dart';
import 'package:droplan/services/droplan_http_server.dart';
import 'package:droplan/services/transfer_service.dart';
import 'package:droplan/widgets/incoming_transfer_dialog.dart';

void main() {
  runApp(const DropLanApp());
}

class SelectedFile {
  const SelectedFile({
    required this.name,
    required this.size,
    required this.path,
  });

  final String name;
  final int size;
  final String path;
}

class DropLanApp extends StatelessWidget {
  const DropLanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(
      ThemeData.dark().textTheme,
    );

    const darkColorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF6366F1), // Modern Indigo
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFF312E81),
      onPrimaryContainer: Color(0xFFE0E7FF),
      secondary: Color(0xFF06B6D4), // Modern Cyan
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFF164E63),
      onSecondaryContainer: Color(0xFFCFFAFE),
      surface: Color(0xFF0A0E1A), // Deep Space Dark
      onSurface: Color(0xFFFFFFFF), // Pure white text
      surfaceContainerLowest: Color(0xFF0B0F19),
      surfaceContainerHigh: Color(0xFF141C2E),
      onSurfaceVariant: Color(0xFFCBD5E1), // Slate 300
      outline: Color(0xFF475569),
      outlineVariant: Color(0xFF334155),
      error: Color(0xFFF87171),
      onError: Color(0xFF0F172A),
    );

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF0A0E1A),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return MaterialApp(
      title: 'AirShare',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        textTheme: textTheme,
        useMaterial3: true,
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF141C2E),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFF334155), width: 1.5),
          ),
          titleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          contentTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: const Color(0xFFCBD5E1),
          ),
        ),
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        textTheme: textTheme,
        useMaterial3: true,
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF141C2E),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFF334155), width: 1.5),
          ),
          titleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          contentTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: const Color(0xFFCBD5E1),
          ),
        ),
      ),
      home: const DropLanHomeScreen(),
    );
  }
}

class DropLanHomeScreen extends StatefulWidget {
  const DropLanHomeScreen({super.key});

  @override
  State<DropLanHomeScreen> createState() => _DropLanHomeScreenState();
}

class _DropLanHomeScreenState extends State<DropLanHomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final String _deviceName;
  late final DropLanHttpServer _httpServer;
  late final DropLanDiscoveryService _discoveryService;

  late final AnimationController _radarAnimationController;

  final List<SelectedFile> _selectedFiles = [];

  bool _isSendingRequest = false;
  bool _isIncomingDialogOpen = false;

  @override
  void initState() {
    super.initState();

    _deviceName = DeviceIdentityService.identity.deviceName;
    _httpServer = DropLanHttpServer();
    _discoveryService = DropLanDiscoveryService();

    _radarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    WidgetsBinding.instance.addObserver(this);

    TransferService.instance.incomingRequestNotifier
        .addListener(_onIncomingTransferRequest);

    TransferService.instance.progressNotifier
        .addListener(_onTransferProgressChanged);

    _startServicesIfForeground();
  }

  @override
  void dispose() {
    _radarAnimationController.dispose();

    TransferService.instance.incomingRequestNotifier
        .removeListener(_onIncomingTransferRequest);

    TransferService.instance.progressNotifier
        .removeListener(_onTransferProgressChanged);

    WidgetsBinding.instance.removeObserver(this);

    _stopServices();

    super.dispose();
  }

  void _onIncomingTransferRequest() {
    final request = TransferService.instance.incomingRequestNotifier.value;

    if (request == null || !mounted) {
      return;
    }

    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID UI LISTENER FIRED transferId=${request.transferId} time=${DateTime.now().toIso8601String()}');
    }

    if (_isIncomingDialogOpen) {
      return;
    }

    _isIncomingDialogOpen = true;

    if (Platform.isMacOS) {
      const MethodChannel('com.example.droplan/nsd_control')
          .invokeMethod('activateApp')
          .catchError((_) {});
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => IncomingTransferDialog(
        request: request,
      ),
    ).then((_) {
      _isIncomingDialogOpen = false;
      if (TransferService.instance.incomingRequestNotifier.value?.transferId ==
          request.transferId) {
        TransferService.instance.incomingRequestNotifier.value = null;
      }
    });
  }

  void _onTransferProgressChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kDebugMode) {
      debugPrint('[DropLAN Timestamp] ANDROID lifecycle: ${state.name}');
    }

    if (state == AppLifecycleState.resumed) {
      _startServicesIfForeground(isResume: true);
      return;
    }

    if (state == AppLifecycleState.detached) {
      _stopServices();
    }
  }

  Future<void> _startServicesIfForeground({bool isResume = false}) async {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;

    if (lifecycleState != null &&
        lifecycleState != AppLifecycleState.resumed &&
        lifecycleState != AppLifecycleState.inactive) {
      return;
    }

    await _httpServer.start();

    if (_httpServer.isRunning) {
      await _discoveryService.startAdvertising(
        _deviceName,
        DropLanConfig.port,
        isResume: isResume,
      );

      await _discoveryService.startDiscovery();
    }
  }

  Future<void> _stopServices() async {
    await _discoveryService.stopDiscovery();
    await _discoveryService.stopAdvertising();

    _discoveryService.clearDiscoveredDevices();

    await _httpServer.stop();
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _pickFiles() async {
    try {
      final newFiles = <SelectedFile>[];

      if (Platform.isAndroid) {
        const channel = MethodChannel('com.example.droplan/instant_picker');
        final List<dynamic>? res =
            await channel.invokeListMethod<dynamic>('pickFiles');

        if (res == null || res.isEmpty) {
          return;
        }

        for (final item in res) {
          if (item is Map) {
            final name = item['name'] as String? ?? 'file';
            final size = (item['size'] as num?)?.toInt() ?? 0;
            final path = item['path'] as String? ?? '';

            if (path.isNotEmpty) {
              newFiles.add(
                SelectedFile(
                  name: name,
                  size: size,
                  path: path,
                ),
              );
            }
          }
        }
      } else {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          withData: false,
          withReadStream: false,
        );

        if (result == null || result.files.isEmpty) {
          return;
        }

        for (final file in result.files) {
          if (file.path == null) {
            continue;
          }

          newFiles.add(
            SelectedFile(
              name: file.name,
              size: file.size,
              path: file.path!,
            ),
          );
        }
      }

      if (!mounted || newFiles.isEmpty) {
        return;
      }

      setState(() {
        for (final file in newFiles) {
          final isDuplicate = _selectedFiles.any(
            (existing) =>
                existing.name == file.name &&
                existing.size == file.size &&
                existing.path == file.path,
          );

          if (!isDuplicate) {
            _selectedFiles.add(file);
          }
        }
      });
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AirShare: file picker error: $error');
      }
    }
  }

  void _removeFile(int index) {
    setState(() {
      _selectedFiles.removeAt(index);
    });
  }

  void _showModernToast({
    required String message,
    required IconData icon,
    required Color accentColor,
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: duration,
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        padding: EdgeInsets.zero,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh
                .withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.2),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: accentColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title,
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      message,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: title != null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendTransferToDevice(
    DiscoveredDevice device,
  ) async {
    if (_selectedFiles.isEmpty) {
      _showModernToast(
        title: 'No Files Selected',
        message: 'Please select files to send first before tapping a device.',
        icon: Icons.file_present_rounded,
        accentColor: const Color(0xFF6366F1), // Indigo
      );

      return;
    }

    if (_isSendingRequest) {
      return;
    }

    setState(() {
      _isSendingRequest = true;
    });

    _showModernToast(
      title: 'Connecting',
      message: 'Sending transfer request to ${device.deviceName}...',
      icon: Icons.send_rounded,
      accentColor: const Color(0xFF06B6D4), // Cyan
      duration: const Duration(seconds: 4),
    );

    final filePayloads = _selectedFiles.map((f) {
      return {
        'name': f.name,
        'size': f.size,
      };
    }).toList();

    final outcome = await TransferService.instance.sendTransferRequest(
      targetHost: device.host,
      targetPort: device.port,
      selectedFileDetails: filePayloads,
      senderPort: _httpServer.port,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isSendingRequest = false;
    });

    switch (outcome.status) {
      case TransferResultStatus.accepted:
        if (outcome.transferId != null &&
            outcome.transferToken != null &&
            outcome.fileItems != null &&
            outcome.fileItems!.length == _selectedFiles.length) {
          final filesToSend = <FileToSend>[];

          for (int i = 0; i < outcome.fileItems!.length; i++) {
            filesToSend.add(
              FileToSend(
                fileItem: outcome.fileItems![i],
                localPath: _selectedFiles[i].path,
              ),
            );
          }

          TransferService.instance.sendTransferFiles(
            targetHost: device.host,
            targetPort: device.port,
            transferId: outcome.transferId!,
            transferToken: outcome.transferToken!,
            filesToSend: filesToSend,
          );
        }

        break;

      case TransferResultStatus.rejected:
        _showModernToast(
          title: 'Request Declined',
          message: 'Request rejected by ${device.deviceName}.',
          icon: Icons.cancel_rounded,
          accentColor: const Color(0xFFEF4444), // Red
        );

        break;

      case TransferResultStatus.expired:
        _showModernToast(
          title: 'Request Expired',
          message: '${device.deviceName} did not respond in time.',
          icon: Icons.timer_off_rounded,
          accentColor: const Color(0xFFF59E0B), // Amber
        );

        break;

      case TransferResultStatus.failed:
        _showModernToast(
          title: 'Transfer Failed',
          message: outcome.message ?? 'Failed to connect to ${device.deviceName}.',
          icon: Icons.error_outline_rounded,
          accentColor: const Color(0xFFEF4444), // Red
        );

        break;
    }
  }

  Future<void> _confirmAndCancelTransfer() async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFF334155), width: 1.5),
          ),
          backgroundColor: const Color(0xFF141C2E),
          title: Text(
            'Cancel Transfer?',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          content: Text(
            'Are you sure you want to cancel the active file transfer?',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 14,
              color: const Color(0xFFCBD5E1),
            ),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                foregroundColor: const Color(0xFFCBD5E1),
                side: const BorderSide(color: Color(0xFF475569)),
              ),
              child: const Text('Keep Transferring'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
              ),
              child: const Text('Yes, Cancel'),
            ),
          ],
        );
      },
    );

    if (shouldCancel == true && mounted) {
      final activeTransferId =
          TransferService.instance.progressNotifier.value?.transferId;

      if (activeTransferId != null) {
        await TransferService.instance.cancelTransfer(activeTransferId);
      } else {
        TransferService.instance.progressNotifier.value = null;
      }

      if (!mounted) return;

      setState(() {
        _selectedFiles.clear();
        _isSendingRequest = false;
      });

      _showModernToast(
        title: 'Transfer Cancelled',
        message: 'File transfer was stopped.',
        icon: Icons.cancel_outlined,
        accentColor: const Color(0xFFEF4444),
      );
    }
  }

  static const List<Offset> _spatialSlots = [
    Offset(0.20, 0.20),
    Offset(0.75, 0.25),
    Offset(0.30, 0.70),
    Offset(0.80, 0.75),
    Offset(0.50, 0.15),
    Offset(0.15, 0.75),
    Offset(0.65, 0.50),
    Offset(0.35, 0.45),
    Offset(0.85, 0.45),
    Offset(0.45, 0.80),
    Offset(0.10, 0.45),
    Offset(0.55, 0.70),
  ];

  static IconData _getDeviceIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('mac') ||
        lower.contains('apple') ||
        lower.contains('imac')) {
      return Icons.desktop_mac_rounded;
    } else if (lower.contains('windows') ||
        lower.contains('pc') ||
        lower.contains('desktop')) {
      return Icons.computer_rounded;
    } else if (lower.contains('laptop') ||
        lower.contains('notebook') ||
        lower.contains('book')) {
      return Icons.laptop_rounded;
    } else if (lower.contains('android') ||
        lower.contains('phone') ||
        lower.contains('mobile') ||
        lower.contains('pixel') ||
        lower.contains('galaxy') ||
        lower.contains('iphone')) {
      return Icons.smartphone_rounded;
    }
    return Icons.devices_rounded;
  }

  static IconData _getFileIcon(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp'].contains(ext)) {
      return Icons.image_rounded;
    } else if (['mp4', 'mkv', 'mov', 'avi', 'webm'].contains(ext)) {
      return Icons.movie_rounded;
    } else if (['mp3', 'wav', 'aac', 'flac', 'm4a'].contains(ext)) {
      return Icons.audiotrack_rounded;
    } else if (['pdf'].contains(ext)) {
      return Icons.picture_as_pdf_rounded;
    } else if (['zip', 'tar', 'gz', '7z', 'rar'].contains(ext)) {
      return Icons.folder_zip_rounded;
    } else if (['txt', 'md', 'json', 'dart', 'js', 'html', 'css']
        .contains(ext)) {
      return Icons.description_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  static Color _getFileColor(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].contains(ext)) {
      return const Color(0xFF38BDF8); // Cyan
    } else if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) {
      return const Color(0xFFA855F7); // Purple
    } else if (['mp3', 'wav', 'aac'].contains(ext)) {
      return const Color(0xFFF59E0B); // Amber
    } else if (['pdf'].contains(ext)) {
      return const Color(0xFFEF4444); // Red
    } else if (['zip', 'tar', 'gz'].contains(ext)) {
      return const Color(0xFF10B981); // Emerald
    }
    return const Color(0xFF818CF8); // Indigo
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSelectedFiles = _selectedFiles.isNotEmpty;
    final progressState = TransferService.instance.progressNotifier.value;
    final isTransferring = progressState != null;

    final totalSelectedSize = _selectedFiles.fold<int>(
      0,
      (sum, item) => sum + item.size,
    );

    // Dynamic Heading Text based on state
    final String headingText;
    if (isTransferring) {
      headingText = progressState.status == TransferProgressStatus.completed
          ? 'Transfer complete'
          : progressState.status == TransferProgressStatus.failed
              ? 'Transfer failed'
              : 'Transfer in progress';
    } else if (hasSelectedFiles) {
      headingText = 'Select device';
    } else {
      headingText = 'Nearby Devices';
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Bar Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Top Left: AirShare Branding
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [Color(0xFF818CF8), Color(0xFF6366F1)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ).createShader(bounds),
                        child: Text(
                          'AirShare',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            color: Colors.white,
                          ),
                        ),
                      ),

                      // Top Right: Device Name Box Container (Modern Box Shape with Rounded Corners)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh
                              .withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.6),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF10B981)
                                        .withValues(alpha: 0.6),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _getDeviceIcon(_deviceName),
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: Text(
                                _deviceName,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                  letterSpacing: 0.2,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          headingText,
                          key: ValueKey(headingText),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Spatial Device Canvas Area OR Inline Transfer UI
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: isTransferring
                      ? _buildInlineTransferCard(context, progressState)
                      : Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.center,
                          children: [
                            // Animated Radar Lines Background
                            Positioned.fill(
                              child: AnimatedBuilder(
                                animation: _radarAnimationController,
                                builder: (context, _) {
                                  return CustomPaint(
                                    painter: RadarBackgroundPainter(
                                      animationValue:
                                          _radarAnimationController.value,
                                      theme: theme,
                                    ),
                                  );
                                },
                              ),
                            ),

                            // Central Radar Icon & Glow — ALWAYS anchored exactly at (width/2, height/2)
                            Center(
                              child: AnimatedBuilder(
                                animation: _radarAnimationController,
                                builder: (context, child) {
                                  final pulse = 1.0 +
                                      (0.05 *
                                          (1.0 -
                                              (_radarAnimationController.value -
                                                      0.5)
                                                  .abs() *
                                                  2.0));
                                  return Transform.scale(
                                    scale: pulse,
                                    child: child,
                                  );
                                },
                                child: Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainerHigh
                                        .withValues(alpha: 0.95),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.4),
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.25),
                                        blurRadius: 20,
                                        spreadRadius: 2,
                                      ),
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.4),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    Icons.wifi_tethering_rounded,
                                    size: 38,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),

                            // Devices Builder & Scanning Subtitles
                            ValueListenableBuilder<List<DiscoveredDevice>>(
                              valueListenable: _discoveryService
                                  .discoveredDevicesNotifier,
                              builder: (context, devices, _) {
                                if (devices.isEmpty) {
                                  return Positioned(
                                    left: 20,
                                    right: 20,
                                    bottom: 24,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Scanning for nearby devices...',
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                            color: theme.colorScheme.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Make sure AirShare is open on nearby devices',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                final sortedDevices =
                                    List<DiscoveredDevice>.from(devices)
                                      ..sort((a, b) =>
                                          a.deviceId.compareTo(b.deviceId));

                                return LayoutBuilder(
                                  builder: (context, constraints) {
                                    // Compact Card Size (118 x 88)
                                    const cardWidth = 118.0;
                                    const cardHeight = 88.0;
                                    final availWidth =
                                        (constraints.maxWidth - cardWidth)
                                            .clamp(0.0, double.infinity);
                                    final availHeight =
                                        (constraints.maxHeight - cardHeight)
                                            .clamp(0.0, double.infinity);

                                    return SizedBox.expand(
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          for (int i = 0;
                                              i < sortedDevices.length;
                                              i++)
                                            _buildSpatialDeviceCard(
                                              context: context,
                                              device: sortedDevices[i],
                                              slotIndex: i,
                                              availWidth: availWidth,
                                              availHeight: availHeight,
                                              cardWidth: cardWidth,
                                              cardHeight: cardHeight,
                                              hasSelectedFiles:
                                                  hasSelectedFiles,
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                ),
              ),
            ),

            // Selected Files Section (Only visible when files are selected and NOT transferring)
            if (hasSelectedFiles && !isTransferring) ...[
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh
                      .withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.6),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 4, right: 4, bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Selected files',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_selectedFiles.length} • ${_formatFileSize(totalSelectedSize)}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            onPressed: _pickFiles,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add files'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              foregroundColor: theme.colorScheme.primary,
                              textStyle: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _selectedFiles.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.4),
                        ),
                        itemBuilder: (context, index) {
                          final file = _selectedFiles[index];
                          final fileColor = _getFileColor(file.name);
                          return ListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            leading: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: fileColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                _getFileIcon(file.name),
                                color: fileColor,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            subtitle: Text(
                              _formatFileSize(file.size),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              tooltip: 'Remove',
                              onPressed: () => _removeFile(index),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (!hasSelectedFiles && !isTransferring) ...[
              // Primary Action: Select Files to Send (Initial State)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary,
                          const Color(0xFF4F46E5),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.upload_file_rounded, size: 22),
                      label: const Text('Select Files to send'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInlineTransferCard(
    BuildContext context,
    TransferProgressState state,
  ) {
    final theme = Theme.of(context);
    final isCompleted = state.status == TransferProgressStatus.completed;
    final isFailed = state.status == TransferProgressStatus.failed;
    final isCancelled = state.status == TransferProgressStatus.cancelled;
    final isTransferring = state.status == TransferProgressStatus.transferring;

    // Header Status Text & Color
    final String titleText;
    final Color accentColor;
    final IconData statusIcon;

    if (isCompleted) {
      titleText = 'Transfer complete';
      accentColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle_rounded;
    } else if (isFailed) {
      titleText = 'Transfer failed';
      accentColor = const Color(0xFFEF4444);
      statusIcon = Icons.error_rounded;
    } else if (isCancelled) {
      titleText = 'Transfer cancelled';
      accentColor = const Color(0xFFF59E0B);
      statusIcon = Icons.cancel_rounded;
    } else {
      titleText = 'Transferring files';
      accentColor = theme.colorScheme.primary;
      statusIcon = Icons.sync_rounded;
    }

    final files = state.files;
    final completedCount =
        files.where((f) => f.status == FileTransferStatus.completed).length;
    final fileCountText = isCompleted
        ? '$completedCount of ${state.totalFiles} files'
        : 'File ${state.currentFileIndex} of ${state.totalFiles}';

    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. TOP OVERALL PROGRESS HEADER
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF141C2E),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF334155)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(statusIcon, color: accentColor, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          titleText,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${(state.overallProgress * 100).toStringAsFixed(0)}%',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Overall Linear Progress Indicator
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: state.overallProgress,
                    minHeight: 8,
                    backgroundColor: const Color(0xFF0A0E1A),
                    color: accentColor,
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_formatFileSize(state.overallBytesTransferred)} / ${_formatFileSize(state.overallTotalBytes)}',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFCBD5E1),
                      ),
                    ),
                    Text(
                      fileCountText,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 2. SCROLLABLE PER-FILE LIST
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Files',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: const Color(0xFFE2E8F0),
              ),
            ),
          ),
          const SizedBox(height: 8),

          Expanded(
            child: files.isEmpty
                ? Center(
                    child: Text(
                      state.currentFileName,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final f = files[index];
                      final isFileActive =
                          f.status == FileTransferStatus.transferring;
                      final isFileDone =
                          f.status == FileTransferStatus.completed;
                      final isFileFailed =
                          f.status == FileTransferStatus.failed;
                      final isFileCancelled =
                          f.status == FileTransferStatus.cancelled;

                      final Color rowBg = isFileActive
                          ? const Color(0xFF1E293B)
                          : const Color(0xFF111827);
                      final Color rowBorder = isFileActive
                          ? theme.colorScheme.primary.withValues(alpha: 0.6)
                          : const Color(0xFF1F2937);

                      final String statusLabel;
                      final Color statusColor;
                      final IconData fileIconData;

                      if (isFileDone) {
                        statusLabel = 'Complete';
                        statusColor = const Color(0xFF10B981);
                        fileIconData = Icons.check_circle_rounded;
                      } else if (isFileFailed) {
                        statusLabel = 'Failed';
                        statusColor = const Color(0xFFEF4444);
                        fileIconData = Icons.error_outline_rounded;
                      } else if (isFileCancelled) {
                        statusLabel = 'Cancelled';
                        statusColor = const Color(0xFFF59E0B);
                        fileIconData = Icons.cancel_outlined;
                      } else if (isFileActive) {
                        statusLabel =
                            '${(f.progress * 100).toStringAsFixed(0)}%';
                        statusColor = theme.colorScheme.primary;
                        fileIconData = Icons.sync_rounded;
                      } else {
                        statusLabel = 'Waiting';
                        statusColor = const Color(0xFF64748B);
                        fileIconData = Icons.insert_drive_file_outlined;
                      }

                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: rowBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: rowBorder),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                fileIconData,
                                color: statusColor,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    f.fileName,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 14,
                                      fontWeight: isFileActive
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      color: isFileActive
                                          ? Colors.white
                                          : const Color(0xFFCBD5E1),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isFileDone
                                        ? '${_formatFileSize(f.fileSize)} / ${_formatFileSize(f.fileSize)}'
                                        : isFileActive
                                            ? '${_formatFileSize(f.bytesTransferred)} / ${_formatFileSize(f.fileSize)}'
                                            : _formatFileSize(f.fileSize),
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 12,
                                      color: const Color(0xFF94A3B8),
                                    ),
                                  ),
                                  if (isFileActive) ...[
                                    const SizedBox(height: 6),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: f.progress,
                                        minHeight: 4,
                                        backgroundColor:
                                            const Color(0xFF0A0E1A),
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              statusLabel,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),

          // 3. BOTTOM ACTION BUTTON
          SizedBox(
            width: double.infinity,
            child: isTransferring
                ? OutlinedButton.icon(
                    onPressed: _confirmAndCancelTransfer,
                    icon: const Icon(Icons.cancel_outlined, size: 20),
                    label: const Text('Cancel transfer'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      foregroundColor: const Color(0xFFF87171),
                      side: const BorderSide(
                        color: Color(0xFFEF4444),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  )
                : FilledButton(
                    onPressed: () {
                      TransferService.instance.progressNotifier.value = null;
                      setState(() {
                        _selectedFiles.clear();
                        _isSendingRequest = false;
                      });
                    },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: isCompleted
                          ? const Color(0xFF10B981)
                          : theme.colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    child: const Text('Done'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpatialDeviceCard({
    required BuildContext context,
    required DiscoveredDevice device,
    required int slotIndex,
    required double availWidth,
    required double availHeight,
    required double cardWidth,
    required double cardHeight,
    required bool hasSelectedFiles,
  }) {
    final theme = Theme.of(context);
    final normOffset = _spatialSlots[slotIndex % _spatialSlots.length];

    final left = (availWidth * normOffset.dx).clamp(0.0, availWidth);
    final top = (availHeight * normOffset.dy).clamp(0.0, availHeight);

    final iconData = _getDeviceIcon(device.deviceName);

    return Positioned(
      left: left,
      top: top,
      child: AnimatedScale(
        scale: _isSendingRequest ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap:
                _isSendingRequest ? null : () => _sendTransferToDevice(device),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: cardWidth,
              height: cardHeight,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh
                    .withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: hasSelectedFiles
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  width: hasSelectedFiles ? 2.0 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: hasSelectedFiles
                        ? theme.colorScheme.primary.withValues(alpha: 0.35)
                        : Colors.black.withValues(alpha: 0.3),
                    blurRadius: hasSelectedFiles ? 14 : 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    alignment: Alignment.topRight,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          iconData,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surfaceContainerHigh,
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: 0.6),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.deviceName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RadarBackgroundPainter extends CustomPainter {
  RadarBackgroundPainter({required this.animationValue, required this.theme});

  final double animationValue;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide * 0.45;

    final circlePaint = Paint()
      ..color = theme.colorScheme.primary.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (int i = 1; i <= 3; i++) {
      final radius = (maxRadius / 3) * i;
      canvas.drawCircle(center, radius, circlePaint);
    }

    final pulseRadius = (maxRadius * (animationValue % 1.0));
    final pulseOpacity = (1.0 - (animationValue % 1.0)).clamp(0.0, 1.0) * 0.15;
    final pulsePaint = Paint()
      ..color = theme.colorScheme.primary.withValues(alpha: pulseOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(center, pulseRadius, pulsePaint);

    final linePaint = Paint()
      ..color = theme.colorScheme.outlineVariant.withValues(alpha: 0.12)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      linePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant RadarBackgroundPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}