import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:path_provider/path_provider.dart';

import 'demo_upload_adapter.dart';
import 'upload_tile.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartUploadDemoApp());
}

class SmartUploadDemoApp extends StatelessWidget {
  const SmartUploadDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Smart Upload',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF3D5AFE),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF3D5AFE),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const UploadDemoPage(),
      );
}

class UploadDemoPage extends StatefulWidget {
  const UploadDemoPage({super.key});

  @override
  State<UploadDemoPage> createState() => _UploadDemoPageState();
}

class _UploadDemoPageState extends State<UploadDemoPage> {
  /// Lets the uploader park transfers instead of hammering a dead connection.
  final ManualNetworkMonitor _network = ManualNetworkMonitor();

  SmartUploader? _uploader;
  StreamSubscription<UploadEvent>? _events;
  final List<UploadTask> _tasks = <UploadTask>[];
  String? _lastEvent;
  bool _flaky = false;
  bool _compress = true;

  @override
  void initState() {
    super.initState();
    unawaited(_createUploader());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_uploader?.dispose());
    unawaited(_network.dispose());
    super.dispose();
  }

  /// Builds the uploader. Everything interesting about the package is here.
  Future<void> _createUploader() async {
    final Directory support = await getApplicationSupportDirectory();

    final SmartUploader uploader = SmartUploader(
      // Swap this for your own UploadAdapter — see rest_upload_adapter.dart.
      adapter: DemoUploadAdapter(failureRate: _flaky ? 0.25 : 0.0),
      config: SmartUploadConfig(
        chunkSize: 512 * 1024,
        maxConcurrentUploads: 2,
        maxRetries: 3,
        retryDelay: const Duration(seconds: 1),
        compressor: const ImageCompressor(),
        // File-backed state means an upload survives the app being killed.
        storage: FileUploadStorage(
          Directory('${support.path}/smart_upload_state'),
        ),
        networkMonitor: _network,
        waitForNetwork: true,
      ),
    );

    final StreamSubscription<UploadEvent> events =
        uploader.events.listen(_onEvent);

    if (!mounted) {
      await uploader.dispose();
      await events.cancel();
      return;
    }
    setState(() {
      _uploader = uploader;
      _events = events;
    });
    await _offerResume(uploader);
  }

  /// Rebuilds the list on every event, and keeps a one-line log for the
  /// status bar.
  void _onEvent(UploadEvent event) {
    if (!mounted) return;
    setState(() {
      _lastEvent = switch (event) {
        UploadRetryEvent(
          :final int attempt,
          :final SmartUploadException error
        ) =>
          'Retry #$attempt after ${error.code}',
        UploadCompressedEvent(:final double savedFraction) =>
          'Compressed, saved ${(savedFraction * 100).round()}%',
        UploadPausedEvent(waitingForNetwork: true) => 'Waiting for network…',
        UploadFailedEvent(:final SmartUploadException error) =>
          'Failed: ${error.message}',
        UploadCompletedEvent(:final UploadResult result) =>
          'Completed → ${result.url}',
        _ => event.status.name,
      };
    });
  }

  /// Offers to continue anything that was interrupted by an earlier run.
  Future<void> _offerResume(SmartUploader uploader) async {
    final List<UploadRecord> pending = await uploader.pendingUploads();
    if (pending.isEmpty || !mounted) return;

    final bool resume = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Unfinished uploads'),
            content: Text(
              '${pending.length} upload(s) were interrupted. Continue them '
              'from where they stopped?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Discard'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Resume'),
              ),
            ],
          ),
        ) ??
        false;

    for (final UploadRecord record in pending) {
      if (!resume) {
        await uploader.config.storage.delete(record.uploadId);
        continue;
      }
      try {
        final UploadTask task = await uploader.resume(record.uploadId);
        if (mounted) setState(() => _tasks.add(task));
      } on SmartUploadException catch (e) {
        _snack('Could not resume ${record.fileName}: ${e.message}');
      }
    }
  }

  Future<void> _pickFiles() async {
    final FilePickerResult? picked =
        await FilePicker.platform.pickFiles(allowMultiple: true);
    final List<File> files = <File>[
      for (final PlatformFile file in picked?.files ?? <PlatformFile>[])
        if (file.path != null) File(file.path!),
    ];
    if (files.isEmpty) return;
    await _enqueue(files);
  }

  /// Writes a large file to disk so the chunking, pausing and resuming are
  /// visible without picking anything.
  Future<void> _addDemoFile() async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File(
      '${dir.path}/demo_${DateTime.now().millisecondsSinceEpoch}.bin',
    );
    final RandomAccessFile handle = await file.open(mode: FileMode.write);
    final Uint8List block = Uint8List(1024 * 1024);
    final Random random = Random();
    for (int i = 0; i < block.length; i += 64) {
      block[i] = random.nextInt(256);
    }
    for (int i = 0; i < 24; i++) {
      await handle.writeFrom(block);
    }
    await handle.close();
    await _enqueue(<File>[file]);
  }

  Future<void> _enqueue(List<File> files) async {
    final SmartUploader? uploader = _uploader;
    if (uploader == null) return;
    try {
      final List<UploadTask> tasks = await uploader.uploadMultiple(
        files: files,
        options: _compress
            ? const UploadOptions(
                compress: true,
                quality: 80,
                maxWidth: 1920,
                maxHeight: 1920,
              )
            : const UploadOptions(),
      );
      setState(() => _tasks.addAll(tasks));
    } on SmartUploadException catch (e) {
      _snack(e.message);
    }
  }

  /// A failed task is terminal, so retrying means starting a fresh task from
  /// the persisted record — which still knows which chunks landed.
  Future<void> _retry(UploadTask task) async {
    final SmartUploader? uploader = _uploader;
    if (uploader == null) return;
    try {
      final UploadTask retried = await uploader.resume(task.id);
      setState(() {
        final int index = _tasks.indexOf(task);
        if (index >= 0) {
          _tasks[index] = retried;
        } else {
          _tasks.add(retried);
        }
      });
    } on SmartUploadException catch (e) {
      _snack('Cannot retry: ${e.message}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final SmartUploader? uploader = _uploader;

    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_smart_upload'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Pause all',
            onPressed: uploader == null ? null : () => uploader.pauseAll(),
            icon: const Icon(Icons.pause),
          ),
          IconButton(
            tooltip: 'Resume all',
            onPressed: uploader == null ? null : () => uploader.resumeAll(),
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Cancel all',
            onPressed: uploader == null ? null : () => uploader.cancelAll(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: uploader == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                _Controls(
                  offline: !_network.online,
                  flaky: _flaky,
                  compress: _compress,
                  onOfflineChanged: (bool value) =>
                      setState(() => _network.online = !value),
                  onFlakyChanged: (bool value) {
                    setState(() => _flaky = value);
                    _snack(
                      value
                          ? '25% of chunks will now fail — watch the retries'
                          : 'Failures disabled (applies to new uploads)',
                    );
                  },
                  onCompressChanged: (bool value) =>
                      setState(() => _compress = value),
                  onPick: _pickFiles,
                  onDemo: _addDemoFile,
                ),
                const Divider(height: 1),
                Expanded(
                  child: _tasks.isEmpty
                      ? const _EmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _tasks.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 16),
                          itemBuilder: (BuildContext context, int index) =>
                              UploadTile(
                            task: _tasks[index],
                            onRetry: () => _retry(_tasks[index]),
                          ),
                        ),
                ),
                if (_lastEvent != null)
                  Container(
                    width: double.infinity,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      _lastEvent!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.offline,
    required this.flaky,
    required this.compress,
    required this.onOfflineChanged,
    required this.onFlakyChanged,
    required this.onCompressChanged,
    required this.onPick,
    required this.onDemo,
  });

  final bool offline;
  final bool flaky;
  final bool compress;
  final ValueChanged<bool> onOfflineChanged;
  final ValueChanged<bool> onFlakyChanged;
  final ValueChanged<bool> onCompressChanged;
  final VoidCallback onPick;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Select files'),
                ),
                OutlinedButton.icon(
                  onPressed: onDemo,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Add 24 MB demo file'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilterChip(
                  label: const Text('Compress images'),
                  selected: compress,
                  onSelected: onCompressChanged,
                ),
                FilterChip(
                  label: const Text('Simulate offline'),
                  selected: offline,
                  onSelected: onOfflineChanged,
                ),
                FilterChip(
                  label: const Text('Simulate flaky server'),
                  selected: flaky,
                  onSelected: onFlakyChanged,
                ),
              ],
            ),
          ],
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.cloud_upload_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                'Add a few files to watch them chunk, compress, retry and '
                'resume. Two upload at a time; the rest wait in the queue.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
}
