import 'geo.dart';
import 'location_fix.dart';
import 'policy.dart';
import 'reasons.dart';

/// Outcome of [ReportingPolicyEngine.evaluate].
sealed class PolicyDecision {
  const PolicyDecision();
}

/// Send the fix.
final class SendDecision extends PolicyDecision {
  /// Creates a send decision.
  const SendDecision(this.reason);

  /// Which rule fired.
  final SendReason reason;

  @override
  String toString() => 'send(${reason.name})';
}

/// The fix is valid but not worth sending.
final class SkipDecision extends PolicyDecision {
  /// Creates a skip decision.
  const SkipDecision(this.reason);

  /// Which rule held the fix back.
  final SkipReason reason;

  @override
  String toString() => 'skip(${reason.name})';
}

/// The fix is invalid and is discarded.
final class DropDecision extends PolicyDecision {
  /// Creates a drop decision.
  const DropDecision(this.reason);

  /// Which filter rejected the fix.
  final DropReason reason;

  @override
  String toString() => 'drop(${reason.name})';
}

/// Stateful, synchronous evaluation of a [ReportingPolicy].
///
/// Feed every fix to [evaluate] with the current time; it answers send,
/// skip or drop and remembers what was sent. It does no I/O and starts no
/// timers, so it can be reused outside [ThrottledLocationReporter].
///
/// Rules, in order: mock filter, accuracy filter, out-of-order filter,
/// jitter filter; then first fix, [ReportingPolicy.minInterval], stationary
/// exit, stationary hold (heartbeats only), interval with minimum distance,
/// turn, heartbeat.
class ReportingPolicyEngine {
  /// Creates an engine for [policy].
  ReportingPolicyEngine(this.policy);

  /// The rules in force.
  final ReportingPolicy policy;

  LocationFix? _lastValid;
  LocationFix? _lastSent;
  DateTime? _lastSentAt;
  double? _lastSentCourse;
  double? _course;
  double _speed = 0;
  Duration? _serverInterval;

  LocationFix? _anchor;
  DateTime? _anchorSince;
  bool _stationary = false;

  LocationFix? _suspect;
  int _suspectChain = 0;

  /// Latest fix that passed the filters.
  LocationFix? get lastValid => _lastValid;

  /// Latest fix that was decided to be sent.
  LocationFix? get lastSent => _lastSent;

  /// Speed in m/s from the latest valid fix, or derived from the last two.
  double get currentSpeed => _speed;

  /// Whether the stationary detector currently holds.
  bool get isStationary => _stationary;

  /// The clamped server-requested interval, or `null`.
  Duration? get serverInterval => _serverInterval;

  /// The interval in force: server override, else the speed band, clamped.
  Duration get currentInterval =>
      _serverInterval ?? policy.clamp(policy.intervalForSpeed(_speed));

  /// When the next heartbeat is due, or `null` if none can be sent yet.
  DateTime? get nextHeartbeatAt {
    final hb = policy.heartbeatInterval;
    final at = _lastSentAt;
    if (hb == null || at == null) return null;
    return at.add(hb);
  }

  /// Sets the server-requested interval, clamped to
  /// `[minInterval, maxInterval]`. `null` returns to the speed bands.
  void setServerInterval(Duration? interval) =>
      _serverInterval = interval == null ? null : policy.clamp(interval);

  /// Forgets what was sent so the next valid fix is sent as
  /// [SendReason.first]. Filter and stationary state are kept.
  void reset() {
    _lastSent = null;
    _lastSentAt = null;
    _lastSentCourse = null;
  }

  /// If a heartbeat is due at [now], records it and returns the latest
  /// valid fix to send; otherwise `null`.
  LocationFix? heartbeat(DateTime now) {
    final due = nextHeartbeatAt;
    final fix = _lastValid;
    if (due == null || fix == null || now.isBefore(due)) return null;
    _recordSend(fix, now);
    return fix;
  }

  /// Decides what to do with [fix] at [now].
  PolicyDecision evaluate(LocationFix fix, DateTime now) {
    final drop = _filter(fix);
    if (drop != null) return DropDecision(drop);

    final prev = _lastValid;
    _lastValid = fix;
    _updateMotion(prev, fix);
    final resumed = _updateStationary(fix, now);

    final sentAt = _lastSentAt;
    final sent = _lastSent;
    if (sentAt == null || sent == null) {
      return _send(fix, now, SendReason.first);
    }

    final elapsed = now.difference(sentAt);
    if (elapsed < policy.minInterval) {
      return const SkipDecision(SkipReason.tooSoon);
    }
    if (resumed) return _send(fix, now, SendReason.resumedMoving);

    final hb = policy.heartbeatInterval;
    final heartbeatDue = hb != null && elapsed >= hb;
    if (_stationary) {
      return heartbeatDue
          ? _send(fix, now, SendReason.heartbeat)
          : const SkipDecision(SkipReason.stationary);
    }

    final moved = distanceBetween(sent, fix);
    final intervalDue = elapsed >= currentInterval;
    if (intervalDue && moved >= policy.minDistanceMeters) {
      return _send(fix, now, SendReason.interval);
    }
    if (_isTurn()) return _send(fix, now, SendReason.turn);
    if (heartbeatDue) return _send(fix, now, SendReason.heartbeat);
    return SkipDecision(intervalDue ? SkipReason.notMoved : SkipReason.tooSoon);
  }

  DropReason? _filter(LocationFix fix) {
    if (policy.rejectMocked && fix.isMocked) return DropReason.mocked;
    final maxAcc = policy.maxAccuracyMeters;
    final acc = fix.accuracy;
    if (maxAcc != null && acc != null && acc > maxAcc) {
      return DropReason.inaccurate;
    }
    final prev = _lastValid;
    if (prev == null) return null;
    if (!fix.timestamp.isAfter(prev.timestamp)) return DropReason.outOfOrder;

    final jitter = policy.jitter;
    if (jitter == null) return null;
    if (_plausible(prev, fix, jitter.maxSpeedMps)) {
      _suspect = null;
      _suspectChain = 0;
      return null;
    }
    final suspect = _suspect;
    _suspectChain = suspect != null &&
            fix.timestamp.isAfter(suspect.timestamp) &&
            _plausible(suspect, fix, jitter.maxSpeedMps)
        ? _suspectChain + 1
        : 1;
    _suspect = fix;
    final resync = jitter.resyncAfter;
    if (resync != null && _suspectChain >= resync) {
      _suspect = null;
      _suspectChain = 0;
      _speed = 0;
      _course = null;
      _lastValid = null; // No motion is derived across the relocation.
      return null;
    }
    return DropReason.implausibleJump;
  }

  static bool _plausible(LocationFix a, LocationFix b, double maxSpeed) {
    final dt = b.timestamp.difference(a.timestamp).inMicroseconds / 1e6;
    final slack = (a.accuracy ?? 0) + (b.accuracy ?? 0);
    final d = distanceBetween(a, b) - slack;
    return d <= 0 || d / dt <= maxSpeed;
  }

  void _updateMotion(LocationFix? prev, LocationFix fix) {
    final reported = fix.speed;
    double? derivedCourse;
    if (prev != null) {
      final dt = fix.timestamp.difference(prev.timestamp).inMicroseconds / 1e6;
      final d = distanceBetween(prev, fix);
      if (reported == null || reported < 0) _speed = d / dt;
      if (d >= 1) {
        derivedCourse = bearingDegrees(prev.lat, prev.lon, fix.lat, fix.lon);
      }
    } else if (reported == null || reported < 0) {
      _speed = 0;
    }
    if (reported != null && reported >= 0) _speed = reported;
    final heading = fix.heading;
    _course = heading != null && heading >= 0 ? heading : derivedCourse;
  }

  /// Returns true when the device just left the stationary radius.
  bool _updateStationary(LocationFix fix, DateTime now) {
    final det = policy.stationary;
    if (det == null) return false;
    final anchor = _anchor;
    final since = _anchorSince;
    if (anchor == null || since == null) {
      _anchor = fix;
      _anchorSince = now;
      return false;
    }
    if (distanceBetween(anchor, fix) > det.radiusMeters) {
      final was = _stationary;
      _anchor = fix;
      _anchorSince = now;
      _stationary = false;
      return was;
    }
    if (now.difference(since) >= det.after) _stationary = true;
    return false;
  }

  bool _isTurn() {
    final threshold = policy.turnDegrees;
    final a = _lastSentCourse;
    final b = _course;
    if (threshold == null || a == null || b == null) return false;
    if (_speed < policy.turnMinSpeedMps) return false;
    return headingDelta(a, b) >= threshold;
  }

  SendDecision _send(LocationFix fix, DateTime now, SendReason reason) {
    _recordSend(fix, now);
    return SendDecision(reason);
  }

  void _recordSend(LocationFix fix, DateTime now) {
    _lastSent = fix;
    _lastSentAt = now;
    _lastSentCourse = _course;
  }
}
