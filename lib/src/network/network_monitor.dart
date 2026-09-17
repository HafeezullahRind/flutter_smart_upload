import 'dart:async';

/// Tells the orchestrator whether the device currently has connectivity.
///
/// Kept abstract on purpose: this package does not depend on
/// `connectivity_plus`, `internet_connection_checker` or any other specific
/// package. Wire up whichever one your app already uses.
///
/// ```dart
/// class ConnectivityPlusMonitor implements NetworkMonitor {
///   ConnectivityPlusMonitor() {
///     _sub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> r) {
///       _online = !r.contains(ConnectivityResult.none);
///       _controller.add(_online);
///     });
///   }
///   // ...
/// }
/// ```
abstract class NetworkMonitor {
  /// Const constructor so monitors can be const.
  const NetworkMonitor();

  /// Whether the device is online right now.
  Future<bool> isOnline();

  /// Emits `true` when connectivity is (re)gained and `false` when it is lost.
  ///
  /// Must be a broadcast stream — several uploads listen at once.
  Stream<bool> get onConnectivityChanged;

  /// Releases any resources held by the monitor.
  Future<void> dispose() async {}
}

/// The default monitor: assumes the device is always online and lets adapter
/// errors drive retries.
class AlwaysOnlineNetworkMonitor extends NetworkMonitor {
  /// Creates the monitor.
  const AlwaysOnlineNetworkMonitor();

  @override
  Future<bool> isOnline() async => true;

  @override
  Stream<bool> get onConnectivityChanged => const Stream<bool>.empty();
}

/// A monitor driven by an external [Stream] of connectivity states.
///
/// The simplest way to bridge an existing connectivity package:
///
/// ```dart
/// final NetworkMonitor monitor = StreamNetworkMonitor(
///   Connectivity()
///       .onConnectivityChanged
///       .map((List<ConnectivityResult> r) => !r.contains(ConnectivityResult.none)),
/// );
/// ```
class StreamNetworkMonitor extends NetworkMonitor {
  /// Creates a monitor that mirrors [source].
  StreamNetworkMonitor(Stream<bool> source, {bool initiallyOnline = true})
      : _online = initiallyOnline {
    _subscription = source.listen((bool online) {
      if (online == _online) return;
      _online = online;
      if (!_controller.isClosed) _controller.add(online);
    });
  }

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  late final StreamSubscription<bool> _subscription;
  bool _online;

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    await _controller.close();
  }
}

/// A monitor whose state is set manually. Intended for tests and for apps that
/// already track connectivity in their own state management.
class ManualNetworkMonitor extends NetworkMonitor {
  /// Creates a monitor that starts [online].
  ManualNetworkMonitor({bool online = true}) : _online = online;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  bool _online;

  /// Updates connectivity and notifies waiting uploads.
  set online(bool value) {
    if (_online == value) return;
    _online = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  /// The current state.
  bool get online => _online;

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  @override
  Future<void> dispose() async => _controller.close();
}
