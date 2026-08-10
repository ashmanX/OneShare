import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/device_identity_service.dart';
import 'package:droplan/services/droplan_discovery_service.dart';
import 'package:droplan/services/droplan_http_server.dart';
import 'package:droplan/services/transfer_service.dart';
import 'package:droplan/widgets/incoming_transfer_dialog.dart';
import 'package:droplan/widgets/transfer_progress_dialog.dart';

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
    return MaterialApp(
      title: 'DropLAN',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
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
    with WidgetsBindingObserver {
  late final String _deviceName;
  late final DropLanHttpServer _httpServer;
  late final DropLanDiscoveryService _discoveryService;

  final List<SelectedFile> _selectedFiles = [];

  bool _isSendingRequest = false;
  bool _isProgressDialogOpen = false;

  @override
  void initState() {
    super.initState();

    _deviceName = DeviceIdentityService.identity.deviceName;
    _httpServer = DropLanHttpServer();
    _discoveryService = DropLanDiscoveryService();

    WidgetsBinding.instance.addObserver(this);

    TransferService.instance.incomingRequestNotifier
        .addListener(_onIncomingTransferRequest);

    TransferService.instance.progressNotifier
        .addListener(_onTransferProgressChanged);

    _startServicesIfForeground();
  }

  @override
  void dispose() {
    TransferService.instance.incomingRequestNotifier
        .removeListener(_onIncomingTransferRequest);

    TransferService.instance.progressNotifier
        .removeListener(_onTransferProgressChanged);

    WidgetsBinding.instance.removeObserver(this);

    _stopServices();

    super.dispose();
  }

  void _onIncomingTransferRequest() {
    final request =
        TransferService.instance.incomingRequestNotifier.value;

    if (request == null || !mounted) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }

      if (Platform.isMacOS) {
        try {
          await const MethodChannel(
            'com.example.droplan/nsd_control',
          ).invokeMethod('activateApp');
        } catch (error) {
          print(
            'DropLAN: failed to activate macOS app: $error',
          );
        }
      }

      if (!mounted) {
        return;
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => IncomingTransferDialog(
          request: request,
        ),
      );
    });
  }

  void _onTransferProgressChanged() {
    final state = TransferService.instance.progressNotifier.value;

    if (state == null || !mounted) {
      return;
    }

    if (!_isProgressDialogOpen &&
        state.status == TransferProgressStatus.transferring) {
      _isProgressDialogOpen = true;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const TransferProgressDialog(),
      ).then((_) {
        _isProgressDialogOpen = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startServicesIfForeground();
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopServices();
    }
  }

  Future<void> _startServicesIfForeground() async {
    final lifecycleState =
        WidgetsBinding.instance.lifecycleState;

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
    final pickedFiles = await openFiles();

    if (pickedFiles.isEmpty) {
      return;
    }

    final newFiles = <SelectedFile>[];

    for (final file in pickedFiles) {
      final size = await file.length();

      newFiles.add(
        SelectedFile(
          name: file.name,
          size: size,
          path: file.path,
        ),
      );
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
  }

  void _removeFile(int index) {
    setState(() {
      _selectedFiles.removeAt(index);
    });
  }

  Future<void> _sendTransferToDevice(
    DiscoveredDevice device,
  ) async {
    if (_selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please select files to send first',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );

      return;
    }

    if (_isSendingRequest) {
      return;
    }

    setState(() {
      _isSendingRequest = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Sending transfer request to '
          '${device.deviceName}...',
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );

    final filePayloads = _selectedFiles.map((f) {
      return {
        'name': f.name,
        'size': f.size,
      };
    }).toList();

    final outcome =
        await TransferService.instance.sendTransferRequest(
      targetHost: device.host,
      targetPort: device.port,
      selectedFileDetails: filePayloads,
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
            outcome.fileItems!.length ==
                _selectedFiles.length) {
          final filesToSend = <FileToSend>[];

          for (int i = 0;
              i < outcome.fileItems!.length;
              i++) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Request rejected by '
              '${device.deviceName}.',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );

        break;

      case TransferResultStatus.expired:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Request to ${device.deviceName} '
              'expired (no response).',
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );

        break;

      case TransferResultStatus.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Transfer request failed: '
              '${outcome.message}',
            ),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );

        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),

              Text(
                'DropLAN',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 4),

              Text(
                'Fast file sharing on your local network',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color:
                      theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 24),

              Text(
                'This device',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 8),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smartphone,
                        color:
                            theme.colorScheme.primary,
                        size: 28,
                      ),

                      const SizedBox(width: 16),

                      Text(
                        _deviceName,
                        style:
                            theme.textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Text(
                'Nearby devices',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 8),

              ValueListenableBuilder<
                  List<DiscoveredDevice>>(
                valueListenable:
                    _discoveryService
                        .discoveredDevicesNotifier,
                builder: (
                  context,
                  devices,
                  _,
                ) {
                  if (devices.isEmpty) {
                    return Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),

                            const SizedBox(width: 12),

                            Expanded(
                              child: Text(
                                'Searching for DropLAN devices...',
                                style: theme
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                  color: theme
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection:
                          Axis.horizontal,
                      itemCount: devices.length,
                      separatorBuilder: (
                        _,
                        _,
                      ) =>
                          const SizedBox(width: 8),
                      itemBuilder: (
                        context,
                        index,
                      ) {
                        final device =
                            devices[index];

                        return SizedBox(
                          width: 190,
                          child: Card(
                            child: InkWell(
                              borderRadius:
                                  BorderRadius.circular(
                                12,
                              ),
                              onTap: _isSendingRequest
                                  ? null
                                  : () =>
                                      _sendTransferToDevice(
                                        device,
                                      ),
                              child: Padding(
                                padding:
                                    const EdgeInsets
                                        .all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  mainAxisAlignment:
                                      MainAxisAlignment
                                          .center,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.devices,
                                          size: 20,
                                          color: theme
                                              .colorScheme
                                              .primary,
                                        ),

                                        const SizedBox(
                                          width: 6,
                                        ),

                                        Expanded(
                                          child: Text(
                                            device
                                                .deviceName,
                                            style: theme
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                              fontWeight:
                                                  FontWeight
                                                      .bold,
                                            ),
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow
                                                    .ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(
                                      height: 6,
                                    ),

                                    Text(
                                      '${device.host}:${device.port}',
                                      style: theme
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                        color: theme
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                    ),

                                    const SizedBox(
                                      height: 6,
                                    ),

                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.send,
                                          size: 14,
                                          color:
                                              Colors.blue,
                                        ),

                                        const SizedBox(
                                          width: 4,
                                        ),

                                        Text(
                                          'Tap to Send',
                                          style: theme
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                            color: Colors
                                                .blue
                                                .shade700,
                                            fontWeight:
                                                FontWeight
                                                    .w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),

              if (_selectedFiles.isNotEmpty) ...[
                const SizedBox(height: 16),

                Text(
                  'Selected files',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 8),

                Expanded(
                  child: ListView.separated(
                    itemCount:
                        _selectedFiles.length,
                    separatorBuilder: (
                      _,
                      _,
                    ) =>
                        const SizedBox(height: 8),
                    itemBuilder: (
                      context,
                      index,
                    ) {
                      final file =
                          _selectedFiles[index];

                      return Card(
                        child: ListTile(
                          leading: const Icon(
                            Icons.insert_drive_file,
                          ),
                          title: Text(
                            file.name,
                            maxLines: 2,
                            overflow:
                                TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _formatFileSize(
                              file.size,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.close,
                            ),
                            tooltip: 'Remove',
                            onPressed: () =>
                                _removeFile(index),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else
                const Spacer(),

              const SizedBox(height: 16),

              FilledButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.upload),
                label: const Text('Send files'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(
                    vertical: 18,
                  ),
                  textStyle:
                      theme.textTheme.titleMedium,
                ),
              ),

              const SizedBox(height: 12),

              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.download),
                label: const Text('Receive files'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(
                    vertical: 18,
                  ),
                  textStyle:
                      theme.textTheme.titleMedium,
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}