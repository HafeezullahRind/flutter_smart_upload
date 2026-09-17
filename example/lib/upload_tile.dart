import 'package:flutter/material.dart';
import 'package:flutter_smart_upload/flutter_smart_upload.dart';

/// One row of the upload list: name, progress bar, speed, ETA and controls.
///
/// Rebuilds from [UploadTask.progressStream] and [UploadTask.statusStream], so
/// it stays in sync without the parent having to pump state down.
class UploadTile extends StatelessWidget {
  const UploadTile({required this.task, required this.onRetry, super.key});

  final UploadTask task;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => StreamBuilder<UploadStatus>(
        stream: task.statusStream,
        initialData: task.status,
        builder: (BuildContext context, AsyncSnapshot<UploadStatus> snapshot) {
          final UploadStatus status = snapshot.data ?? task.status;
          return StreamBuilder<UploadProgress>(
            stream: task.progressStream,
            initialData: task.progress,
            builder: (
              BuildContext context,
              AsyncSnapshot<UploadProgress> progressSnapshot,
            ) =>
                _buildRow(
              context,
              status,
              progressSnapshot.data ?? task.progress,
            ),
          );
        },
      );

  Widget _buildRow(
    BuildContext context,
    UploadStatus status,
    UploadProgress progress,
  ) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  task.fileName,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _StatusChip(status: status, waiting: task.isWaitingForNetwork),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: status == UploadStatus.completed ? 1 : progress.fraction,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            color: switch (status) {
              UploadStatus.failed => theme.colorScheme.error,
              UploadStatus.cancelled => theme.colorScheme.outline,
              _ => theme.colorScheme.primary,
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _subtitle(status, progress),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ..._actions(status),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle(UploadStatus status, UploadProgress progress) {
    if (status == UploadStatus.failed) {
      return task.error?.message ?? 'Upload failed';
    }
    if (status == UploadStatus.completed) {
      return '${_bytes(progress.totalBytes)} · ${task.url ?? 'done'}';
    }
    if (status == UploadStatus.queued) return 'Queued';
    if (task.isWaitingForNetwork) return 'Waiting for network…';

    final String done =
        '${_bytes(progress.uploadedBytes)} / ${_bytes(progress.totalBytes)}';
    final String percent = '${progress.percentage.toStringAsFixed(0)}%';
    if (status != UploadStatus.uploading) return '$done · $percent';

    final String speed = '${_bytes(progress.bytesPerSecond.round())}/s';
    final Duration? eta = progress.estimatedRemaining;
    return '$done · $percent · $speed'
        '${eta == null ? '' : ' · ${_duration(eta)} left'}';
  }

  List<Widget> _actions(UploadStatus status) => switch (status) {
        UploadStatus.uploading ||
        UploadStatus.preparing ||
        UploadStatus.compressing ||
        UploadStatus.queued =>
          <Widget>[
            IconButton(
              tooltip: 'Pause',
              onPressed: task.pause,
              icon: const Icon(Icons.pause),
            ),
            IconButton(
              tooltip: 'Cancel',
              onPressed: task.cancel,
              icon: const Icon(Icons.close),
            ),
          ],
        UploadStatus.paused => <Widget>[
            IconButton(
              tooltip: 'Resume',
              onPressed: task.resume,
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: 'Cancel',
              onPressed: task.cancel,
              icon: const Icon(Icons.close),
            ),
          ],
        UploadStatus.failed => <Widget>[
            IconButton(
              tooltip: 'Retry',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
          ],
        UploadStatus.completed || UploadStatus.cancelled => const <Widget>[],
      };

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _duration(Duration value) {
    final int minutes = value.inMinutes;
    final int seconds = value.inSeconds % 60;
    return minutes > 0 ? '${minutes}m ${seconds}s' : '${seconds}s';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.waiting});

  final UploadStatus status;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (status) {
      UploadStatus.completed => (
          colors.primaryContainer,
          colors.onPrimaryContainer
        ),
      UploadStatus.failed => (colors.errorContainer, colors.onErrorContainer),
      UploadStatus.cancelled => (
          colors.surfaceContainerHighest,
          colors.onSurfaceVariant
        ),
      _ => (colors.secondaryContainer, colors.onSecondaryContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        waiting && status == UploadStatus.paused ? 'offline' : status.name,
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
