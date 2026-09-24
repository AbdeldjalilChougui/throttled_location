import 'location_fix.dart';

/// What the server said about a batch.
class SinkResult {
  /// The server stored the batch. [nextInterval], if given, becomes the
  /// reporting interval (clamped by the policy).
  const SinkResult.accepted({this.nextInterval}) : accepted = true;

  /// The server received the batch but refused it for good (for example a
  /// validation error). The points are dropped, not retried.
  const SinkResult.rejected({this.nextInterval}) : accepted = false;

  /// Whether the batch was stored.
  final bool accepted;

  /// Interval requested by the server, such as a `next_update_seconds`
  /// field, or `null` to keep the current one.
  final Duration? nextInterval;
}

/// Delivers batches of fixes, usually with one HTTP request per batch.
///
/// Throw to signal a transient failure (offline, timeout, 5xx): the batch
/// stays queued and is retried with backoff. Return
/// [SinkResult.rejected] for a permanent refusal.
abstract interface class LocationSink {
  /// Wraps a function as a sink.
  factory LocationSink.fromFunction(
      Future<SinkResult> Function(List<LocationFix> batch) send) = _FnSink;

  /// Sends [batch], oldest fix first.
  Future<SinkResult> send(List<LocationFix> batch);
}

class _FnSink implements LocationSink {
  _FnSink(this._send);

  final Future<SinkResult> Function(List<LocationFix> batch) _send;

  @override
  Future<SinkResult> send(List<LocationFix> batch) => _send(batch);
}

/// Exponential backoff between failed sends: [initial], then doubling
/// ([multiplier]) up to [max].
class RetryBackoff {
  /// Creates a backoff.
  const RetryBackoff({
    this.initial = const Duration(seconds: 2),
    this.max = const Duration(minutes: 1),
    this.multiplier = 2,
  });

  /// Delay after the first failure.
  final Duration initial;

  /// Longest delay.
  final Duration max;

  /// Growth factor per consecutive failure.
  final double multiplier;

  /// Delay after [failures] consecutive failures (1-based).
  Duration delay(int failures) {
    var us = initial.inMicroseconds.toDouble();
    for (var i = 1; i < failures && us < max.inMicroseconds; i++) {
      us *= multiplier;
    }
    final d = Duration(microseconds: us.round());
    return d > max ? max : d;
  }
}
