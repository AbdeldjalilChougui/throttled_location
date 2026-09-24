import 'location_fix.dart';
import 'reasons.dart';

/// What the backlog does when it is full.
class BacklogOverflow {
  /// Drop the oldest queued points first.
  const BacklogOverflow.dropOldest() : keepEvery = null;

  /// Thin the queue: keep every [keepEvery]-th point (counting from the
  /// oldest) plus the newest one. Points that have survived more thinning
  /// passes are further apart, so old history gets coarser while recent
  /// history stays detailed. Falls back to dropping the oldest points when
  /// thinning is not enough.
  BacklogOverflow.downsample({int this.keepEvery = 2}) {
    if (keepEvery! < 2) {
      throw ArgumentError.value(keepEvery, 'keepEvery', 'must be >= 2');
    }
  }

  /// Thinning step for [BacklogOverflow.downsample]; `null` for
  /// [BacklogOverflow.dropOldest].
  final int? keepEvery;
}

/// Bounds for the offline backlog.
class BacklogPolicy {
  /// Creates bounds. [maxCount] must be positive and [maxAge] longer than
  /// zero.
  BacklogPolicy({
    this.maxCount = 500,
    this.maxAge = const Duration(hours: 1),
    this.overflow = const BacklogOverflow.dropOldest(),
  }) {
    if (maxCount < 1) {
      throw ArgumentError.value(maxCount, 'maxCount', 'must be >= 1');
    }
    if (maxAge <= Duration.zero) {
      throw ArgumentError.value(maxAge, 'maxAge', 'must be positive');
    }
  }

  /// Most points kept while undelivered.
  final int maxCount;

  /// Points whose `timestamp` is older than this are discarded.
  final Duration maxAge;

  /// What happens when [maxCount] is exceeded.
  final BacklogOverflow overflow;
}

/// Bounded FIFO of undelivered fixes. The first [locked] items are in
/// flight and are never dropped by overflow or expiry.
class Backlog {
  /// Creates a backlog, optionally seeded with persisted points, which are
  /// trimmed to [policy].
  Backlog(this.policy, {Iterable<LocationFix> initial = const []}) {
    _items.addAll(initial);
    _enforceCount();
  }

  /// The bounds in force.
  final BacklogPolicy policy;

  final List<LocationFix> _items = [];
  int _locked = 0;

  /// Queued points, oldest first.
  List<LocationFix> get items => List.unmodifiable(_items);

  /// Number of queued points.
  int get length => _items.length;

  /// Whether nothing is queued.
  bool get isEmpty => _items.isEmpty;

  /// Number of points currently in flight.
  int get locked => _locked;

  /// Appends [fix] and enforces the bounds. Returns what was dropped.
  Map<DropReason, int> add(LocationFix fix, DateTime now) {
    if (now.difference(fix.timestamp) > policy.maxAge) {
      return {DropReason.expired: 1};
    }
    _items.add(fix);
    return _enforceCount();
  }

  /// Drops unlocked points older than `maxAge` at [now]. Returns how many
  /// were dropped.
  int expire(DateTime now) {
    final before = _items.length;
    final head = _items.sublist(0, _locked);
    final tail = _items
        .sublist(_locked)
        .where((f) => now.difference(f.timestamp) <= policy.maxAge);
    _items
      ..clear()
      ..addAll(head)
      ..addAll(tail);
    return before - _items.length;
  }

  /// Marks the oldest [max] points as in flight and returns them.
  List<LocationFix> lockBatch(int max) {
    _locked = max < _items.length ? max : _items.length;
    return List.unmodifiable(_items.sublist(0, _locked));
  }

  /// Removes the in-flight points (delivered or rejected).
  void commitLocked() {
    _items.removeRange(0, _locked);
    _locked = 0;
  }

  /// Returns the in-flight points to the queue for a retry.
  void releaseLocked() => _locked = 0;

  Map<DropReason, int> _enforceCount() {
    final max = policy.maxCount;
    if (_items.length <= max) return const {};
    final drops = <DropReason, int>{};
    final k = policy.overflow.keepEvery;
    if (k != null) {
      final before = _items.length;
      final free = _items.sublist(_locked);
      final kept = <LocationFix>[
        for (var j = 0; j < free.length; j++)
          if (j % k == 0 || j == free.length - 1) free[j],
      ];
      _items
        ..removeRange(_locked, _items.length)
        ..addAll(kept);
      final n = before - _items.length;
      if (n > 0) drops[DropReason.downsampled] = n;
    }
    final excess = _items.length - max;
    if (excess > 0) {
      final removable = _items.length - _locked;
      // Always keep at least the newest point when everything else is
      // locked; the bound is then exceeded only by in-flight points.
      final n = excess < removable ? excess : removable - 1;
      if (n > 0) {
        _items.removeRange(_locked, _locked + n);
        drops[DropReason.overflow] = n;
      }
    }
    return drops;
  }
}
