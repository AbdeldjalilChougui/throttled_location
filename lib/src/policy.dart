/// Reporting interval used at or above a speed.
class SpeedBand {
  /// Uses [interval] when the speed is at least [minSpeedMps].
  const SpeedBand(this.minSpeedMps, this.interval);

  /// Lower speed bound in metres per second, inclusive.
  final double minSpeedMps;

  /// Interval between sends in this band.
  final Duration interval;

  /// Bands tuned for couriers and drivers: 30 s below 2 m/s (walking or
  /// idling), 15 s up to 8 m/s (bike, slow traffic), 10 s up to 20 m/s
  /// (city driving) and 5 s above (highway).
  static const List<SpeedBand> defaults = [
    SpeedBand(0, Duration(seconds: 30)),
    SpeedBand(2, Duration(seconds: 15)),
    SpeedBand(8, Duration(seconds: 10)),
    SpeedBand(20, Duration(seconds: 5)),
  ];
}

/// Rejects GPS jumps that would need an impossible speed.
///
/// The implied speed between the previous valid fix and a new one is
/// `max(0, distance - accuracyA - accuracyB) / Δt`, using the fixes' own
/// timestamps. Above [maxSpeedMps] the new fix is dropped.
class JitterFilter {
  /// Creates a filter.
  const JitterFilter({this.maxSpeedMps = 70, this.resyncAfter = 3});

  /// Highest believable speed in metres per second. The default, 70 m/s,
  /// is 252 km/h.
  final double maxSpeedMps;

  /// After this many consecutive rejected fixes that agree with each
  /// other, the filter accepts the new position as real (for example,
  /// when the earlier fix was the wrong one). `null` never resyncs.
  final int? resyncAfter;
}

/// Detects a parked device. While stationary, only heartbeats are sent.
class StationaryDetector {
  /// Creates a detector.
  const StationaryDetector({
    this.radiusMeters = 30,
    this.after = const Duration(minutes: 2),
  });

  /// The device is stationary while every fix stays within this distance
  /// of an anchor fix. Leaving it re-anchors and sends at once.
  final double radiusMeters;

  /// How long the device must stay within the radius.
  final Duration after;
}

/// When to send a fix. All rules combine; see the README for the order.
class ReportingPolicy {
  /// Creates a policy. The defaults suit delivery and ride-hailing apps.
  /// [minInterval] must not exceed [maxInterval].
  const ReportingPolicy({
    this.minInterval = const Duration(seconds: 5),
    this.maxInterval = const Duration(minutes: 2),
    this.interval = const Duration(seconds: 15),
    this.speedBands = SpeedBand.defaults,
    this.minDistanceMeters = 10,
    this.turnDegrees = 30,
    this.turnMinSpeedMps = 2,
    this.maxAccuracyMeters = 50,
    this.rejectMocked = false,
    this.jitter = const JitterFilter(),
    this.stationary = const StationaryDetector(),
    this.heartbeatInterval = const Duration(minutes: 5),
  });

  /// Hard floor: two sends are never closer than this.
  final Duration minInterval;

  /// Upper clamp for the speed-adaptive and server intervals.
  final Duration maxInterval;

  /// Interval used when [speedBands] is `null`.
  final Duration interval;

  /// Speed-adaptive intervals, or `null` to always use [interval].
  final List<SpeedBand>? speedBands;

  /// An interval send also needs this much movement since the last send.
  final double minDistanceMeters;

  /// Send early when the course changes by at least this many degrees.
  /// `null` disables turn detection.
  final double? turnDegrees;

  /// Below this speed the course is noise and turns are ignored.
  final double turnMinSpeedMps;

  /// Fixes with a worse accuracy radius are dropped. `null` disables.
  final double? maxAccuracyMeters;

  /// Drop fixes flagged as mocked.
  final bool rejectMocked;

  /// Jump filter, or `null` to accept every jump.
  final JitterFilter? jitter;

  /// Parked-device detection, or `null` to disable.
  final StationaryDetector? stationary;

  /// Re-send the latest position when nothing was sent for this long.
  /// `null` disables heartbeats.
  final Duration? heartbeatInterval;

  /// The interval for [speedMps] before clamping: the highest band whose
  /// `minSpeedMps` is at most [speedMps], or [interval].
  Duration intervalForSpeed(double speedMps) {
    final bands = speedBands;
    if (bands == null || bands.isEmpty) return interval;
    SpeedBand? best;
    for (final b in bands) {
      if (b.minSpeedMps <= speedMps &&
          (best == null || b.minSpeedMps > best.minSpeedMps)) {
        best = b;
      }
    }
    return (best ?? bands.first).interval;
  }

  /// Clamps [d] to `[minInterval, maxInterval]`.
  Duration clamp(Duration d) => d < minInterval
      ? minInterval
      : d > maxInterval
          ? maxInterval
          : d;
}
