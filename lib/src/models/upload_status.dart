/// The lifecycle state of a single upload.
enum UploadStatus {
  /// Accepted by the queue, waiting for a free concurrency slot.
  queued,

  /// Validating the file, planning chunks, computing checksums.
  preparing,

  /// Running the [Compressor] pipeline.
  compressing,

  /// Transferring bytes to the adapter.
  uploading,

  /// Suspended by the caller (or by loss of connectivity).
  paused,

  /// Finished successfully.
  completed,

  /// Finished with an error.
  failed,

  /// Cancelled by the caller.
  cancelled;

  /// Whether no further state changes will occur.
  bool get isTerminal =>
      this == completed || this == failed || this == cancelled;

  /// Whether the task currently occupies a concurrency slot.
  bool get isActive =>
      this == preparing || this == compressing || this == uploading;

  /// Whether the task can be resumed from its current state.
  bool get isResumable => this == paused || this == failed;
}
