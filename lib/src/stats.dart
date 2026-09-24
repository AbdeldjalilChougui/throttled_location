import 'reasons.dart';

/// Lifecycle of a [ThrottledLocationReporter].
enum ReporterState {
  /// Created, not started.
  idle,

  /// Listening to the source and sending.
  running,

  /// Not listening to the source; queued points are still delivered.
  paused,

  /// Finished. Cannot be restarted.
  stopped,
}

/// A snapshot of reporter counters and state.
class ReporterStats {
  /// Creates a snapshot.
  const ReporterStats({
    this.state = ReporterState.idle,
    this.sent = 0,
    this.queued = 0,
    this.droppedByReason = const {},
    this.skippedByReason = const {},
    this.isOnline = true,
    this.isStationary = false,
    this.interval = Duration.zero,
    this.consecutiveFailures = 0,
  });

  /// Current lifecycle state.
  final ReporterState state;

  /// Fixes the sink accepted.
  final int sent;

  /// Fixes waiting for delivery, including a batch in flight.
  final int queued;

  /// Fixes lost, by reason.
  final Map<DropReason, int> droppedByReason;

  /// Valid fixes the policy chose not to send, by reason.
  final Map<SkipReason, int> skippedByReason;

  /// Whether the connectivity stream last said online.
  final bool isOnline;

  /// Whether the stationary detector holds.
  final bool isStationary;

  /// Reporting interval in force.
  final Duration interval;

  /// Sends that failed in a row; 0 after a success.
  final int consecutiveFailures;

  /// Total fixes lost.
  int get dropped => droppedByReason.values.fold(0, (a, b) => a + b);

  /// Total fixes skipped by the policy.
  int get skipped => skippedByReason.values.fold(0, (a, b) => a + b);

  static bool _mapEq<K>(Map<K, int> a, Map<K, int> b) =>
      a.length == b.length && a.keys.every((k) => a[k] == b[k]);

  @override
  bool operator ==(Object other) =>
      other is ReporterStats &&
      other.state == state &&
      other.sent == sent &&
      other.queued == queued &&
      _mapEq(other.droppedByReason, droppedByReason) &&
      _mapEq(other.skippedByReason, skippedByReason) &&
      other.isOnline == isOnline &&
      other.isStationary == isStationary &&
      other.interval == interval &&
      other.consecutiveFailures == consecutiveFailures;

  @override
  int get hashCode => Object.hash(state, sent, queued, dropped, skipped,
      isOnline, isStationary, interval, consecutiveFailures);

  @override
  String toString() => 'ReporterStats(${state.name}, sent: $sent, '
      'queued: $queued, dropped: $dropped, skipped: $skipped, '
      'online: $isOnline, stationary: $isStationary, '
      'interval: $interval, failures: $consecutiveFailures)';
}
